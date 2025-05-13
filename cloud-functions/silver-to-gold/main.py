import os
import tempfile
import datetime
import json
import hashlib
import pandas as pd
from google.cloud import storage, bigquery
import functions_framework
from flask import Request # Per il type hint
from typing import List, Dict, Any, Optional
import traceback

# --- CONFIGURAZIONE GLOBALE ---
# Questi nomi di bucket e dataset DEVONO ESISTERE nel tuo progetto GCP.
SILVER_BUCKET_NAME_CFG = "silver-layer-bucket"
GOLD_BUCKET_NAME_CFG = "gold-layer-bucket"
GOLD_BQ_DATASET_CFG = "gold_layer_dataset"

storage_client_instance: Optional[storage.Client] = None
bq_client_instance: Optional[bigquery.Client] = None
cfg_project_id_initialized: Optional[str] = None


# --- FUNZIONI HELPER ---
def _initialize_clients(current_project_id: str):
    global storage_client_instance, bq_client_instance, cfg_project_id_initialized
    if cfg_project_id_initialized != current_project_id or storage_client_instance is None or bq_client_instance is None:
        print(f"silver-to-gold: Initializing GCS and BigQuery clients for project: {current_project_id}")
        try:
            storage_client_instance = storage.Client(project=current_project_id)
            bq_client_instance = bigquery.Client(project=current_project_id)
            cfg_project_id_initialized = current_project_id
            print(f"silver-to-gold: Clients initialized successfully for project {current_project_id}.")
        except Exception as e_init:
            print(f"FATAL: Failed to initialize clients for project {current_project_id}: {e_init}")
            traceback.print_exc()
            raise ConnectionError(f"Failed to initialize Google Cloud clients: {e_init}")


def determine_gold_path(optimization_info: Dict[str, Any],
                        silver_bucket_name_for_paths: str,
                        input_files: Optional[List[str]] = None,
                        date_obj: Optional[datetime.datetime] = None) -> str:
    date_obj = date_obj or datetime.datetime.utcnow()
    opt_type = optimization_info.get("optimization_type", "unknown_opt_type").replace(" ", "_").lower()

    data_domain = "cross_domain"
    if input_files:
        domains = set()
        for file_uri in input_files:
            path_to_parse = file_uri
            gs_prefix_silver = f"gs://{silver_bucket_name_for_paths}/"
            if path_to_parse.startswith(gs_prefix_silver):
                path_to_parse = path_to_parse[len(gs_prefix_silver):]
            parts = path_to_parse.split('/')
            if len(parts) > 1 and parts[0] == "silver_data_files":
                if len(parts) > 2:
                    domains.add(parts[1])
        if len(domains) == 1:
            data_domain = domains.pop()
        elif len(domains) > 1:
            data_domain = "multi_domain"

    agg_level = "detail_level"
    if opt_type == "aggregate":
        agg_level = "aggregated_data"
        group_by = optimization_info.get("params", {}).get("group_by", [])
        if isinstance(group_by, list):
            time_fields = [f for f in group_by if isinstance(f, str) and any(tp in f.lower() for tp in ["date", "year", "month", "day", "time"])]
            if time_fields:
                if any("year" in f.lower() for f in time_fields): agg_level = "yearly_aggregate"
                elif any("month" in f.lower() for f in time_fields): agg_level = "monthly_aggregate"
                elif any(d in f.lower() for d in ["day", "date"] for f in time_fields): agg_level = "daily_aggregate"
                elif any("hour" in f.lower() for f in time_fields): agg_level = "hourly_aggregate"
    elif opt_type == "join": agg_level = "joined_data"
    elif opt_type == "filter": agg_level = "filtered_data"
    elif opt_type == "denormalize": agg_level = "denormalized_data"

    data_product_name = optimization_info.get("output_name", "generic_gold_product").replace(" ", "_").lower()
    op_hash = create_operation_hash(optimization_info)
    date_partition_str = date_obj.strftime("%Y/%m/%d")

    hierarchy = [
        "gold_files",
        data_domain,
        opt_type,
        agg_level,
        data_product_name,
        f"date_partition={date_partition_str}"
    ]
    base_path = "/".join(filter(None, hierarchy))
    gold_filename = f"{data_product_name}_{op_hash[:8]}.parquet"
    return f"{base_path}/{gold_filename}"


def create_operation_hash(data: Dict[str, Any]) -> str:
    relevant_data_for_hash = {
        "input_files": sorted(data.get("files", [])),
        "optimization_type": data.get("optimization_type"),
        "params_structure": {k: type(v).__name__ for k,v in data.get("params", {}).items()},
        "output_name_base": data.get("output_name"),
        "timestamp_for_hash": data.get("timestamp_for_hash", datetime.datetime.utcnow().isoformat()) # Aggiunto per maggiore unicità
    }
    hash_input = json.dumps(relevant_data_for_hash, sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(hash_input.encode('utf-8')).hexdigest()[:16]


def create_gold_bq_table(df: pd.DataFrame, bq_table_name: str, project_id: str, dataset_id: str) -> str:
    global bq_client_instance
    if bq_client_instance is None:
        print("FATAL in create_gold_bq_table: BigQuery client not initialized.")
        raise ConnectionError("BigQuery client not initialized.")

    table_full_id = f"{project_id}.{dataset_id}.{bq_table_name}"
    print(f"Attempting to create/overwrite BigQuery native table: {table_full_id}")

    df_for_bq = df.copy()
    bq_schema_fields = [] # Rinominato per chiarezza, questo è per bigquery.SchemaField

    for col_name in df_for_bq.columns:
        dtype = df_for_bq[col_name].dtype
        bq_type_str = "STRING" # Default

        if pd.api.types.is_bool_dtype(dtype):
            bq_type_str = "BOOLEAN"
        elif pd.api.types.is_integer_dtype(dtype):
            bq_type_str = "INT64"
        elif pd.api.types.is_float_dtype(dtype):
            bq_type_str = "FLOAT64"
        elif pd.api.types.is_datetime64_any_dtype(dtype):
            bq_type_str = "TIMESTAMP"
            if not df_for_bq[col_name].empty and df_for_bq[col_name].dt.tz is not None:
                df_for_bq[col_name] = df_for_bq[col_name].dt.tz_convert('UTC')
        elif pd.api.types.is_object_dtype(dtype):
             # Potrebbe essere stringa, lista (ARRAY), dict (STRUCT/JSON)
             # Per semplicità, se non è datetime, default a STRING.
             # Una logica più avanzata potrebbe provare a inferire ARRAY/STRUCT o convertire a JSON string.
             # Se la colonna è `creation_date` e object, la convertiamo prima
            if col_name == "creation_date": # Gestione specifica se rimane object
                try:
                    df_for_bq[col_name] = pd.to_datetime(df_for_bq[col_name], errors='coerce')
                    if pd.api.types.is_datetime64_any_dtype(df_for_bq[col_name].dtype):
                        bq_type_str = "TIMESTAMP" # o "DATE"
                        if not df_for_bq[col_name].empty and df_for_bq[col_name].dt.tz is not None:
                             df_for_bq[col_name] = df_for_bq[col_name].dt.tz_convert('UTC')
                    else: # Se la conversione fallisce, rimane STRING
                        bq_type_str = "STRING"
                except Exception:
                     bq_type_str = "STRING" # Fallback
            else:
                bq_type_str = "STRING" # Altri object a STRING

        print(f"  Column: {col_name}, Original Dtype: {dtype}, Mapped BQ Type: {bq_type_str}")
        bq_schema_fields.append(bigquery.SchemaField(col_name, bq_type_str, mode="NULLABLE"))

    job_config = bigquery.LoadJobConfig(
        schema=bq_schema_fields,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        create_disposition=bigquery.CreateDisposition.CREATE_IF_NEEDED,
    )
    try:
        print(f"Loading DataFrame to BigQuery table {table_full_id}...")
        job = bq_client_instance.load_table_from_dataframe(df_for_bq, table_full_id, job_config=job_config)
        job.result(timeout=240) # Aumentato timeout
        print(f"Successfully loaded data to BigQuery table: {table_full_id}. Rows: {job.output_rows}")
        return table_full_id
    except Exception as e_bq_load:
        print(f"CRITICAL Error loading DataFrame to BigQuery table {table_full_id}: {e_bq_load}")
        traceback.print_exc()
        # Potrebbe essere utile loggare df_for_bq.info() qui per debug
        print("DataFrame info before BQ load failure:")
        df_for_bq.info(verbose=True, show_counts=True)
        raise


# --- FUNZIONE PRINCIPALE CLOUD FUNCTION ---
@functions_framework.http
def silver_to_gold(request: Request):
    if request.method == 'OPTIONS':
        headers = {'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type, Authorization', 'Access-Control-Max-Age': '3600'}
        return ('', 204, headers)
    response_cors_headers = {'Access-Control-Allow-Origin': '*'}

    tmp_silver_files_paths: List[str] = []
    tmp_gold_out_path: Optional[str] = None
    data_payload: Dict[str, Any] = {}

    try:
        project_id_from_env_gcp = os.environ.get("GCP_PROJECT")
        project_id_from_env_google = os.environ.get("GOOGLE_CLOUD_PROJECT")
        current_project_id = project_id_from_env_gcp or project_id_from_env_google

        print(f"silver-to-gold: Env GCP_PROJECT: {project_id_from_env_gcp}")
        print(f"silver-to-gold: Env GOOGLE_CLOUD_PROJECT: {project_id_from_env_google}")
        print(f"silver-to-gold: Using project_id: {current_project_id}")

        if not current_project_id:
            print("CRITICAL ERROR: Project ID could not be determined from env vars.")
            return ({"status": "error", "error": "Project ID env var not configured."}, 500, response_cors_headers)

        _initialize_clients(current_project_id)

        if not request.is_json:
            return ({"status": "error", "error": "Invalid content type, expected application/json"}, 415, response_cors_headers)
        data_payload = request.get_json(silent=True)
        if data_payload is None: return ({"status": "error", "error": "Malformed JSON or empty request body"}, 400, response_cors_headers)

        silver_files_uris: List[str] = data_payload.get("files", [])
        if not silver_files_uris or not isinstance(silver_files_uris, list):
            return ({"status": "error", "error": "'files' param must be a non-empty list of GCS URIs."}, 400, response_cors_headers)

        optimization_type: Optional[str] = data_payload.get("optimization_type")
        if not optimization_type or not isinstance(optimization_type, str):
            return ({"status": "error", "error": "'optimization_type' param must be a non-empty string."}, 400, response_cors_headers)

        params: Dict[str, Any] = data_payload.get("optimization_params", {})
        if not isinstance(params, dict):
            return ({"status": "error", "error": "'optimization_params' must be a dictionary."}, 400, response_cors_headers)

        output_name_base: str = data_payload.get("output_name", f"opt_data_{datetime.datetime.utcnow().strftime('%Y%m%d%H%M%S')}")
        description: str = data_payload.get("description", f"Automatic Gold optimization: {optimization_type}")

        gold_bucket_gcs = storage_client_instance.bucket(GOLD_BUCKET_NAME_CFG)
        if not gold_bucket_gcs.exists():
            error_msg = f"Destination Gold bucket '{GOLD_BUCKET_NAME_CFG}' does not exist. Please create it."
            print(f"CRITICAL ERROR: {error_msg}")
            return ({"status": "error", "error": error_msg}, 500, response_cors_headers)

        dataframes_silver: List[pd.DataFrame] = []
        actual_silver_uris_for_manifest: List[str] = []

        for file_uri in silver_files_uris:
            if not isinstance(file_uri, str) or not file_uri.startswith("gs://"):
                print(f"Warning: Invalid or non-GCS file URI found in 'files' list: '{file_uri}'. Skipping.")
                continue

            path_to_process = file_uri[5:]
            try:
                current_silver_bucket_name, blob_name_silver = path_to_process.split("/", 1)
            except ValueError:
                return ({"status": "error", "error": f"Invalid GCS URI format for Silver file: {file_uri}. Expected gs://bucket/object_path"}, 400, response_cors_headers)

            if not blob_name_silver:
                return ({"status": "error", "error": f"Object path part is missing in Silver file URI: {file_uri}"}, 400, response_cors_headers)

            actual_silver_uris_for_manifest.append(f"gs://{current_silver_bucket_name}/{blob_name_silver}")
            print(f"Processing Silver file: gs://{current_silver_bucket_name}/{blob_name_silver}")

            silver_blob = storage_client_instance.bucket(current_silver_bucket_name).blob(blob_name_silver)
            if not silver_blob.exists():
                 return ({"status": "error", "error": f"Silver file not found: gs://{current_silver_bucket_name}/{blob_name_silver}"}, 404, response_cors_headers)

            with tempfile.NamedTemporaryFile(delete=False, suffix=".parquet") as tmp_s:
                tmp_silver_files_paths.append(tmp_s.name)
            silver_blob.download_to_filename(tmp_silver_files_paths[-1])
            dataframes_silver.append(pd.read_parquet(tmp_silver_files_paths[-1]))

        if not dataframes_silver:
             return ({"status": "error", "error": "No valid Silver data could be loaded from provided URIs."}, 400, response_cors_headers)

        result_df: Optional[pd.DataFrame] = None
        # --- ESECUZIONE OTTIMIZZAZIONE ---
        if optimization_type == "aggregate":
            group_by_cols = params.get("group_by", [])
            agg_functions = params.get("aggregations", {})
            if not group_by_cols or not agg_functions:
                return ({"status": "error", "error": "Missing 'group_by' or 'aggregations' for aggregate optimization."}, 400, response_cors_headers)
            print(f"Performing aggregation with groupby: {group_by_cols}, aggregations: {agg_functions}")
            df_to_agg = dataframes_silver[0].copy()
            result_df = df_to_agg.groupby(group_by_cols, as_index=False).agg(agg_functions)

        elif optimization_type == "join":
            if len(dataframes_silver) < 2:
                return ({"status": "error", "error": "Join optimization requires at least 2 input DataFrames."}, 400, response_cors_headers)
            left_df = dataframes_silver[0].copy()
            join_instructions = params.get("join_instructions", [])
            if join_instructions:
                if join_instructions and isinstance(join_instructions, list) and len(join_instructions) > 0:
                    first_join = join_instructions[0]
                    right_df_index = first_join.get("right_df_index", 1)
                    if right_df_index < len(dataframes_silver):
                         left_df = pd.merge(left_df, dataframes_silver[right_df_index].copy(),
                                           left_on=first_join.get("left_on"),
                                           right_on=first_join.get("right_on"),
                                           how=first_join.get("how", "inner"),
                                           suffixes=('_left', '_right'))
                    else:
                         return ({"status": "error", "error": "Invalid right_df_index in join_instructions."}, 400, response_cors_headers)
            else:
                join_on_cols = params.get("on")
                join_how = params.get("how", "inner")
                if not join_on_cols: return ({"status": "error", "error": "Missing 'on' parameter for simple join."}, 400, response_cors_headers)
                print(f"Performing sequential join on: {join_on_cols}, how: {join_how}")
                for i in range(1, len(dataframes_silver)):
                    left_df = pd.merge(left_df, dataframes_silver[i].copy(), on=join_on_cols, how=join_how, suffixes=(f'_df0', f'_df{i}'))
            result_df = left_df

        elif optimization_type == "filter":
            df_to_filter = dataframes_silver[0].copy() # Filtro si applica al primo DF se non specificato diversamente
            filter_conditions = params.get("conditions", [])
            if not filter_conditions: return ({"status": "error", "error": "Missing 'conditions' for filter."}, 400, response_cors_headers)
            print(f"Applying filter conditions: {filter_conditions} to DataFrame with shape {df_to_filter.shape}")
            active_df = df_to_filter
            for cond in filter_conditions:
                col, op, val = cond.get("column"), cond.get("operator"), cond.get("value")
                if not col or op is None: print(f"Skipping incomplete filter: {cond}"); continue
                if col not in active_df.columns: print(f"Column '{col}' not in DataFrame. Skipping filter."); continue
                print(f"Applying: {col} {op} {val}")
                try:
                    if op == "==": active_df = active_df[active_df[col] == val]
                    elif op == "!=": active_df = active_df[active_df[col] != val]
                    elif op == ">": active_df = active_df[active_df[col] > val]
                    elif op == ">=": active_df = active_df[active_df[col] >= val]
                    elif op == "<": active_df = active_df[active_df[col] < val]
                    elif op == "<=": active_df = active_df[active_df[col] <= val]
                    elif op == "in": active_df = active_df[active_df[col].isin(val if isinstance(val, list) else [val])]
                    elif op == "notin": active_df = active_df[~active_df[col].isin(val if isinstance(val, list) else [val])]
                    elif op == "contains": active_df = active_df[active_df[col].astype(str).str.contains(str(val), case=False, na=False)]
                    elif op == "startswith": active_df = active_df[active_df[col].astype(str).str.startswith(str(val), na=False)]
                    elif op == "endswith": active_df = active_df[active_df[col].astype(str).str.endswith(str(val), na=False)]
                    elif op == "isnull": active_df = active_df[active_df[col].isnull()]
                    elif op == "isnotnull": active_df = active_df[active_df[col].notnull()]
                    else: print(f"Unsupported filter op '{op}'. Skipping.")
                except Exception as e_f: print(f"Error on filter {cond}: {e_f}"); traceback.print_exc()
                print(f"Shape after filter: {active_df.shape}")
            result_df = active_df

        else:
            return ({"status": "error", "error": f"Unsupported optimization_type: {optimization_type}"}, 400, response_cors_headers)

        if result_df is None or result_df.empty:
            print(f"Warning: Optimization '{optimization_type}' resulted in an empty DataFrame.")
            # *** INIZIO MODIFICA PER gold_df_columns ANCHE PER DF VUOTO ***
            # Determina le colonne e i tipi anche se il DF è vuoto, se possibile (basandosi sul primo DF silver per esempio)
            gold_df_columns_with_types_empty = []
            if dataframes_silver: # Se abbiamo almeno un DF silver caricato
                temp_ref_df_for_schema = dataframes_silver[0] # Usa il primo come riferimento per lo schema
                if optimization_type == "aggregate": # Le colonne aggregate potrebbero avere nomi diversi
                    # Prova a dedurre i nomi delle colonne risultato dall'agg_functions
                    for new_col_name in params.get("aggregations", {}).keys():
                        # Per il tipo, è più difficile senza dati, default a STRING o prova a inferire se possibile
                        # Per ora, usiamo STRING come fallback sicuro se il df è vuoto.
                        gold_df_columns_with_types_empty.append({"name": new_col_name, "type": "STRING"})
                    for group_col in params.get("group_by", []): # Aggiungi colonne di raggruppamento
                        if group_col in temp_ref_df_for_schema.columns:
                             original_dtype = temp_ref_df_for_schema[group_col].dtype
                             bq_type_str_empty = "STRING"
                             if pd.api.types.is_bool_dtype(original_dtype): bq_type_str_empty = "BOOLEAN"
                             elif pd.api.types.is_integer_dtype(original_dtype): bq_type_str_empty = "INT64"
                             elif pd.api.types.is_float_dtype(original_dtype): bq_type_str_empty = "FLOAT64"
                             elif pd.api.types.is_datetime64_any_dtype(original_dtype): bq_type_str_empty = "TIMESTAMP"
                             gold_df_columns_with_types_empty.append({"name": group_col, "type": bq_type_str_empty})
                        else: # Se la colonna di raggruppamento non è nel df originale (improbabile ma possibile)
                            gold_df_columns_with_types_empty.append({"name": group_col, "type": "STRING"})

                else: # Per join, filter, ecc., le colonne sono un sotto/superinsieme di quelle originali
                    for col_name, dtype in temp_ref_df_for_schema.dtypes.items():
                        dtype_str = str(dtype)
                        simple_type = "STRING"
                        if "bool" in dtype_str: simple_type = "BOOLEAN"
                        elif "int" in dtype_str: simple_type = "INT64"
                        elif "float" in dtype_str: simple_type = "FLOAT64"
                        elif "datetime" in dtype_str: simple_type = "TIMESTAMP"
                        gold_df_columns_with_types_empty.append({"name": col_name, "type": simple_type})

            return ({"status": "success",
                     "message": "Optimization resulted in empty data (0 rows).",
                     "record_count": 0,
                     "gold_df_columns": gold_df_columns_with_types_empty, # Invia schema anche se vuoto
                     "gold_output_gcs_uri": None,
                     "gold_bigquery_table": None}, 200, response_cors_headers)
            # *** FINE MODIFICA ***

        current_utc_time = datetime.datetime.utcnow()
        # Aggiungi timestamp_for_hash per unicità dell'hash anche se altri parametri sono identici
        opt_info_for_paths_and_hash = {
            "files": actual_silver_uris_for_manifest, "optimization_type": optimization_type,
            "params": params, "output_name": output_name_base,
            "timestamp_for_hash": current_utc_time.isoformat()
        }
        op_id_hash = create_operation_hash(opt_info_for_paths_and_hash)

        result_df["gold_optimization_id"] = op_id_hash
        result_df["gold_optimization_type"] = optimization_type
        result_df["gold_optimization_timestamp"] = pd.to_datetime(current_utc_time)
        
        # Gestione esplicita di 'creation_date' se presente
        if "creation_date" in result_df.columns:
            # Se non è già un datetime, prova a convertirlo. Coerce gli errori a NaT.
            if not pd.api.types.is_datetime64_any_dtype(result_df["creation_date"].dtype):
                print(f"Column 'creation_date' is {result_df['creation_date'].dtype}, converting to datetime.")
                result_df["creation_date"] = pd.to_datetime(result_df["creation_date"], errors='coerce')
        else: # Se non esiste, aggiungila.
            print("Adding 'creation_date' column to Gold DataFrame.")
            result_df["creation_date"] = pd.to_datetime(current_utc_time.date()) # Usa solo la data come pd.Timestamp

        gold_object_full_gcs_path = determine_gold_path(opt_info_for_paths_and_hash, SILVER_BUCKET_NAME_CFG,
                                                        actual_silver_uris_for_manifest, date_obj=current_utc_time)
        gold_object_base_gcs_path = os.path.dirname(gold_object_full_gcs_path)

        with tempfile.NamedTemporaryFile(delete=False, suffix=".parquet") as tmp_g_out:
            tmp_gold_out_path = tmp_g_out.name
        result_df.to_parquet(tmp_gold_out_path, index=False, engine='pyarrow')

        gold_blob_on_gcs = storage_client_instance.bucket(GOLD_BUCKET_NAME_CFG).blob(gold_object_full_gcs_path)
        gold_blob_on_gcs.upload_from_filename(tmp_gold_out_path)
        print(f"Uploaded Gold Parquet to gs://{GOLD_BUCKET_NAME_CFG}/{gold_object_full_gcs_path}")

        bq_table_full_id_for_gold = None
        if data_payload.get("create_bq_table", False) is True:
            bq_table_name_for_gold_opt = f"{output_name_base}_{op_id_hash[:8]}"
            # Sanitize table name for BigQuery
            bq_table_name_for_gold_opt = ''.join(c if c.isalnum() or c == '_' else '_' for c in bq_table_name_for_gold_opt)
            if not bq_table_name_for_gold_opt[0].isalpha() and not bq_table_name_for_gold_opt[0] == '_': # Deve iniziare con lettera o underscore
                bq_table_name_for_gold_opt = f"_{bq_table_name_for_gold_opt}"
            if len(bq_table_name_for_gold_opt) > 1024: # Limite lunghezza nome tabella BQ
                bq_table_name_for_gold_opt = bq_table_name_for_gold_opt[:1024]

            bq_table_full_id_for_gold = create_gold_bq_table(result_df, bq_table_name_for_gold_opt, current_project_id, dataset_id=GOLD_BQ_DATASET_CFG)

        manifest_gold_full_gcs_path = f"{gold_object_base_gcs_path}/_optimization_manifest.json"
        meta_blob_gold_on_gcs = storage_client_instance.bucket(GOLD_BUCKET_NAME_CFG).blob(manifest_gold_full_gcs_path)
        manifest_gold_entries_list = []
        if meta_blob_gold_on_gcs.exists():
            try:
                loaded_m = json.loads(meta_blob_gold_on_gcs.download_as_text())
                if isinstance(loaded_m, list): manifest_gold_entries_list = loaded_m
            except Exception as e_m_load_gold: print(f"Warning: Failed to load/parse Gold manifest {manifest_gold_full_gcs_path}: {e_m_load_gold}")

        manifest_gold_entries_list = [e for e in manifest_gold_entries_list if e.get("optimization_id") != op_id_hash]
        new_manifest_entry = {
            "optimization_id": op_id_hash, "optimization_type": optimization_type, "description": description,
            "silver_sources_uris": actual_silver_uris_for_manifest,
            "gold_output_gcs_uri": f"gs://{GOLD_BUCKET_NAME_CFG}/{gold_object_full_gcs_path}",
            "optimization_params_used": params, "gold_created_at": current_utc_time.isoformat() + "Z",
            "record_count": len(result_df),
            "gold_df_schema": {col: str(dtype) for col, dtype in result_df.dtypes.items()}, # Schema Pandas per il manifest
            "gold_bigquery_table_full_id": bq_table_full_id_for_gold,
            "gold_gcs_path_prefix_base": gold_object_base_gcs_path
        }
        manifest_gold_entries_list.append(new_manifest_entry)
        meta_blob_gold_on_gcs.upload_from_string(json.dumps(manifest_gold_entries_list, indent=2), content_type="application/json")
        print(f"Gold manifest updated at gs://{GOLD_BUCKET_NAME_CFG}/{manifest_gold_full_gcs_path}")

        # *** INIZIO MODIFICA PER gold_df_columns NELLA RISPOSTA ***
        gold_df_columns_with_types = []
        for col_name, dtype in result_df.dtypes.items():
            dtype_str = str(dtype)
            simple_type = "STRING" # Fallback
            if "bool" in dtype_str: simple_type = "BOOLEAN"
            elif "int" in dtype_str: simple_type = "INT64" # o INTEGER
            elif "float" in dtype_str: simple_type = "FLOAT64" # o FLOAT
            elif "datetime" in dtype_str or "timestamp" in dtype_str: simple_type = "TIMESTAMP"
            elif "object" in dtype_str: simple_type = "STRING" # Per sicurezza, o più logica se necessario
            gold_df_columns_with_types.append({"name": col_name, "type": simple_type})
        # *** FINE MODIFICA ***

        response_final_data = {
            "status": "success", "message": "Gold optimization completed successfully.",
            "optimization_id": op_id_hash,
            "gold_output_gcs_uri": f"gs://{GOLD_BUCKET_NAME_CFG}/{gold_object_full_gcs_path}",
            "record_count": len(result_df),
            "gold_df_columns": gold_df_columns_with_types, # Modificato per inviare tipi BQ
            "gold_bigquery_table": bq_table_full_id_for_gold
        }
        return (response_final_data, 200, response_cors_headers)

    except Exception as e_main:
        error_msg_main = str(e_main)
        print(f"CRITICAL UNHANDLED ERROR in silver_to_gold for input '{data_payload.get('files', 'N/A')}': {error_msg_main}")
        traceback.print_exc()
        return ({"status": "error", "error": error_msg_main, "details": traceback.format_exc()}, 500, response_cors_headers)

    finally:
        for temp_file_path in tmp_silver_files_paths:
            if temp_file_path and os.path.exists(temp_file_path):
                try: os.unlink(temp_file_path); print(f"Cleaned temp silver file: {temp_file_path}")
                except Exception as e_unlink: print(f"Error unlinking temp silver file {temp_file_path}: {e_unlink}")
        if tmp_gold_out_path and os.path.exists(tmp_gold_out_path):
            try: os.unlink(tmp_gold_out_path); print(f"Cleaned temp gold file: {tmp_gold_out_path}")
            except Exception as e_unlink: print(f"Error unlinking temp gold file {tmp_gold_out_path}: {e_unlink}")