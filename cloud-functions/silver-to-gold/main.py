import os
import tempfile
import datetime
import json
import hashlib
import pandas as pd
from google.cloud import storage, bigquery
import functions_framework
from flask import Request # Per il type hint
from typing import List, Dict, Any, Optional # Optional è usato nei type hints
import traceback

# --- CONFIGURAZIONE GLOBALE ---
# Questi nomi di bucket devono esistere!
SILVER_BUCKET_NAME_CFG = "silver-layer-bucket" 
GOLD_BUCKET_NAME_CFG = "gold-layer-bucket" # <<< ASSICURATI CHE QUESTO ESISTA E SIA IL NOME CORRETTO!
GOLD_BQ_DATASET_CFG = "gold_layer_dataset" # <<< ASSICURATI CHE QUESTO DATASET ESISTA!

# I client verranno inizializzati nella funzione principale con il project_id corretto
storage_client_instance: Optional[storage.Client] = None
bq_client_instance: Optional[bigquery.Client] = None
cfg_project_id: Optional[str] = None


# --- FUNZIONI HELPER ---
def _initialize_clients(current_project_id: str):
    """Inizializza o verifica i client globali con il project_id corretto."""
    global storage_client_instance, bq_client_instance, cfg_project_id
    
    if cfg_project_id != current_project_id or storage_client_instance is None or bq_client_instance is None:
        print(f"Initializing clients for project: {current_project_id}")
        storage_client_instance = storage.Client(project=current_project_id)
        bq_client_instance = bigquery.Client(project=current_project_id)
        cfg_project_id = current_project_id
    # else:
    #     print(f"Clients already initialized for project: {cfg_project_id}")


def determine_gold_path(optimization_info: Dict[str, Any], 
                        silver_bucket_name_for_paths: str, # Passa il nome del bucket silver
                        input_files: Optional[List[str]] = None, 
                        date_obj: Optional[datetime.datetime] = None) -> str:
    date_obj = date_obj or datetime.datetime.utcnow()
    opt_type = optimization_info.get("optimization_type", "unknown_opt")
    data_domain = "cross_domain"
    if input_files:
        domains = set()
        for file_uri in input_files:
            path_to_parse = file_uri
            gs_prefix = f"gs://{silver_bucket_name_for_paths}/"
            if path_to_parse.startswith(gs_prefix):
                path_to_parse = path_to_parse[len(gs_prefix):]
            
            parts = path_to_parse.split('/')
            # Assumendo che il path sia: SILVER_DATA_FILES_ROOT_PREFIX/data_domain/category/context/date_partition=...
            # Quindi parts[0] è SILVER_DATA_FILES_ROOT_PREFIX, parts[1] è data_domain
            if len(parts) > 1: 
                domains.add(parts[1]) # Indice 1 dopo aver rimosso il root prefix e il bucket
        if len(domains) == 1: data_domain = domains.pop()

    agg_level = "detail"
    if opt_type == "aggregate":
        agg_level = "aggregated"
        group_by = optimization_info.get("params", {}).get("group_by", [])
        time_fields = [f for f in group_by if isinstance(f, str) and any(tp in f.lower() for tp in ["date", "year", "month", "day", "time"])]
        if time_fields:
            if any("year" in f.lower() for f in time_fields): agg_level = "yearly_agg"
            elif any("month" in f.lower() for f in time_fields): agg_level = "monthly_agg"
            elif any(d in f.lower() for d in ["day", "date"] for f in time_fields): agg_level = "daily_agg"
            elif any("hour" in f.lower() for f in time_fields): agg_level = "hourly_agg"
    elif opt_type == "join": agg_level = "joined_view"
    elif opt_type == "filter": agg_level = "filtered_subset"
    elif opt_type == "denormalize": agg_level = "denormalized_table"
    
    data_product_name = optimization_info.get("output_name", "generic_product").replace(" ", "_").lower()
    op_hash = optimization_info.get("hash", create_operation_hash(optimization_info))
    date_partition_str = date_obj.strftime("%Y/%m/%d")
    
    hierarchy = ["gold", data_domain, opt_type, agg_level, data_product_name, f"date_partition={date_partition_str}"]
    base_path = "/".join(filter(None, hierarchy))
    gold_filename = f"{data_product_name}_{op_hash}.parquet"
    return f"{base_path}/{gold_filename}"

def create_operation_hash(data: Dict[str, Any]) -> str:
    relevant_data = {
        "files": sorted(data.get("files", [])), 
        "optimization_type": data.get("optimization_type"),
        "params": data.get("params", {}),
        "output_name": data.get("output_name") # Includi output_name per distinguere ottimizzazioni simili su output diversi
    }
    hash_input = json.dumps(relevant_data, sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(hash_input.encode('utf-8')).hexdigest()[:16]

def create_gold_bq_table(df: pd.DataFrame, bq_table_name: str, project_id: str, dataset_id: str) -> str:
    """Crea o sovrascrive una tabella BigQuery nativa."""
    global bq_client_instance # Usa il client inizializzato
    if bq_client_instance is None:
        raise ConnectionError("BigQuery client not initialized. Call _initialize_clients first.")

    table_full_id = f"{project_id}.{dataset_id}.{bq_table_name}"
    print(f"Attempting to create/overwrite BigQuery table: {table_full_id}")
    bq_schema = []
    for col_name, dtype in df.dtypes.items():
        if pd.api.types.is_integer_dtype(dtype): bq_type = "INT64"
        elif pd.api.types.is_float_dtype(dtype): bq_type = "FLOAT64"
        elif pd.api.types.is_bool_dtype(dtype): bq_type = "BOOL"
        elif pd.api.types.is_datetime64_any_dtype(dtype): bq_type = "TIMESTAMP"
        else: bq_type = "STRING"
        bq_schema.append(bigquery.SchemaField(col_name, bq_type, mode="NULLABLE"))
    
    job_config = bigquery.LoadJobConfig(
        schema=bq_schema,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        create_disposition=bigquery.CreateDisposition.CREATE_IF_NEEDED,
    )
    try:
        job = bq_client_instance.load_table_from_dataframe(df, table_full_id, job_config=job_config)
        job.result() 
        print(f"Successfully loaded data to BigQuery table: {table_full_id}. Rows: {job.output_rows}")
        return table_full_id
    except Exception as e_bq_load:
        print(f"Error loading DataFrame to BigQuery table {table_full_id}: {e_bq_load}")
        traceback.print_exc(); raise

# --- FUNZIONE PRINCIPALE CLOUD FUNCTION ---
@functions_framework.http
def silver_to_gold(request: Request):
    if request.method == 'OPTIONS':
        headers = {'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type, Authorization', 'Access-Control-Max-Age': '3600'}
        return ('', 204, headers)
    response_cors_headers = {'Access-Control-Allow-Origin': '*'}
    
    tmp_silver_files_paths = []
    tmp_gold_out_path = None
    data_payload = {}

    # --- GESTIONE PROJECT ID ---
    project_id_from_env_gcp = os.environ.get("GCP_PROJECT") # Quello che imposti tu
    
    current_project_id = project_id_from_env_gcp

    print(f"silver-to-gold: GCP_PROJECT env: {project_id_from_env_gcp}")
    print(f"silver-to-gold: Using project_id: {current_project_id}")

    if not current_project_id:
        print("CRITICAL ERROR: Project ID could not be determined from environment variables.")
        return ({"status": "error", "error": "Project ID environment variable not configured for the function."}, 500, response_cors_headers)
    
    _initialize_clients(current_project_id) # Inizializza i client con il project_id corretto
    # Ora usa storage_client_instance e bq_client_instance

    try:
        if not request.is_json:
            return ({"status": "error", "error": "Invalid content type"}, 415, response_cors_headers)
        data_payload = request.get_json(silent=True)
        if data_payload is None: return ({"status": "error", "error": "Malformed JSON"}, 400, response_cors_headers)
            
        silver_files_uris = data_payload.get("files", [])
        if not silver_files_uris or not isinstance(silver_files_uris, list):
            return ({"status": "error", "error": "'files' must be a non-empty list"}, 400, response_cors_headers)
        optimization_type = data_payload.get("optimization_type")
        if not optimization_type or not isinstance(optimization_type, str):
            return ({"status": "error", "error": "'optimization_type' must be a non-empty string"}, 400, response_cors_headers)
        params = data_payload.get("optimization_params", {})
        if not isinstance(params, dict):
            return ({"status": "error", "error": "'optimization_params' must be a dict"}, 400, response_cors_headers)
        output_name_base = data_payload.get("output_name", f"opt_data_{datetime.datetime.utcnow().strftime('%Y%m%d%H%M')}")
        description = data_payload.get("description", f"Auto Gold opt: {optimization_type}")
        
        gold_bucket_gcs = storage_client_instance.bucket(GOLD_BUCKET_NAME_CFG)
        if not gold_bucket_gcs.exists():
            error_msg = f"Destination Gold bucket '{GOLD_BUCKET_NAME_CFG}' not found. Please create it."
            print(f"Error: {error_msg}")
            return ({"status": "error", "error": error_msg}, 500, response_cors_headers)

        dataframes_silver = []
        actual_silver_uris_for_manifest = []
        for file_uri in silver_files_uris:
            if not isinstance(file_uri, str): continue
            path_proc = file_uri; current_silver_bucket = SILVER_BUCKET_NAME_CFG
            if path_proc.startswith("gs://"):
                path_proc = path_proc[5:]
                try: current_silver_bucket, blob_name_silver = path_proc.split("/", 1)
                except ValueError: return ({"status": "error", "error": f"Invalid GCS URI: {file_uri}"}, 400, response_cors_headers)
            else: blob_name_silver = path_proc.lstrip("/")
            
            actual_silver_uris_for_manifest.append(f"gs://{current_silver_bucket}/{blob_name_silver}")
            print(f"Processing Silver file: gs://{current_silver_bucket}/{blob_name_silver}")
            silver_blob = storage_client_instance.bucket(current_silver_bucket).blob(blob_name_silver)
            if not silver_blob.exists(): return ({"status": "error", "error": f"Silver file not found: gs://{current_silver_bucket}/{blob_name_silver}"}, 404, response_cors_headers)
            
            with tempfile.NamedTemporaryFile(delete=False, suffix=".parquet") as tmp_s:
                tmp_silver_files_paths.append(tmp_s.name)
            silver_blob.download_to_filename(tmp_silver_files_paths[-1])
            dataframes_silver.append(pd.read_parquet(tmp_silver_files_paths[-1]))
        
        if not dataframes_silver: return ({"status": "error", "error": "No valid Silver data loaded."}, 400, response_cors_headers)

        result_df = None # DataFrame ottimizzato
        # --- ESECUZIONE OTTIMIZZAZIONE ---
        if optimization_type == "aggregate":
            # ... (la tua logica di aggregazione come prima) ...
            group_by_cols = params.get("group_by", [])
            agg_functions = params.get("aggregations", {})
            if not group_by_cols or not agg_functions: return ({"status": "error", "error": "Missing params for aggregate"}, 400, response_cors_headers)
            result_df = dataframes_silver[0].groupby(group_by_cols).agg(agg_functions).reset_index()
        elif optimization_type == "join":
            if len(dataframes_silver) < 2:
                return ({"status": "error", "error": "Join optimization requires at least 2 input DataFrames/files."}, 400, response_cors_headers)
            
            # La logica di join deve essere più robusta e basata sui parametri forniti da Gemini
            # Esempio semplificato, assumendo che params contenga 'left_on', 'right_on', 'how' per ogni join
            # Per ora, uniamo sequenzialmente, il che potrebbe non essere sempre corretto per join complessi.
            
            left_df = dataframes_silver[0]
            join_instructions = params.get("join_instructions", []) # Gemini dovrebbe fornire queste
                                                                    # Es: [{"left_df_index": 0, "right_df_index": 1, "left_on": "colA", "right_on": "colB", "how": "inner"}]

            if not join_instructions and len(dataframes_silver) > 1: # Fallback se non ci sono istruzioni specifiche
                 join_on = params.get("on") # Vecchia logica di fallback
                 how = params.get("how", "inner")
                 print(f"Performing sequential join with on: {join_on}, how: {how}")
                 for right_df in dataframes_silver[1:]:
                    left_df = pd.merge(left_df, right_df, on=join_on, how=how, suffixes=('_left', '_right')) # Aggiungi suffixes per evitare conflitti di nome colonna
                 result_df = left_df
            elif join_instructions:
                 # TODO: Implementa una logica di join più flessibile basata su join_instructions
                 # Questa parte richiede una progettazione attenta di come Gemini fornisce le istruzioni di join
                 print(f"Performing join based on detailed instructions (TODO: implement): {join_instructions}")
                 # Per ora, replichiamo la vecchia logica se join_instructions è presente ma non la usiamo
                 join_on = params.get("on") 
                 how = params.get("how", "inner")
                 for right_df in dataframes_silver[1:]:
                    left_df = pd.merge(left_df, right_df, on=join_on, how=how, suffixes=('_left', '_right'))
                 result_df = left_df
            else: # len(dataframes_silver) == 1, nessun join necessario
                 result_df = left_df

        # --- NUOVA LOGICA PER IL FILTRO ---
        elif optimization_type == "filter":
            if not dataframes_silver:
                return ({"status": "error", "error": "No dataframes to filter"}, 400, response_cors_headers)
            
            # Assumiamo che il filtro si applichi al primo dataframe, 
            # o che i dati siano già stati uniti se il filtro segue un join.
            # Se l'ottimizzazione è SOLO un filtro, si applicherà a dataframes_silver[0].
            # Se l'ottimizzazione è un JOIN seguito da un FILTRO, dovrai strutturare i parametri in modo diverso.
            # Per ora, assumiamo un filtro semplice su dataframes_silver[0].
            df_to_filter = dataframes_silver[0].copy()

            filter_conditions_from_params = params.get("conditions", []) 
            # Gemini dovrebbe fornire queste condizioni, ad esempio:
            # [{"column": "silver_data_domain", "operator": "==", "value": "ditto"},
            #  {"column": "original_file_extension", "operator": "!=", "value": "pdf"}]

            if not filter_conditions_from_params:
                return ({"status": "error", "error": "Missing 'conditions' for filter optimization."}, 400, response_cors_headers)

            print(f"Applying filter conditions: {filter_conditions_from_params}")
            
            active_df = df_to_filter
            for condition in filter_conditions_from_params:
                col = condition.get("column")
                op = condition.get("operator")
                val = condition.get("value")

                if not col or op is None: # val può essere None per operatori come 'isnull'
                    print(f"Warning: Incomplete filter condition skipped: {condition}")
                    continue
                
                print(f"Applying: Column '{col}' {op} '{val}'")
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
                    else:
                        print(f"Warning: Unsupported filter operator '{op}' for column '{col}'. Skipping condition.")
                        continue
                    print(f"DataFrame shape after condition: {active_df.shape}")
                except Exception as e_filter_cond:
                    print(f"Error applying filter condition {condition}: {e_filter_cond}")
                    # Potresti decidere di continuare con gli altri filtri o fallire
            result_df = active_df
        # --- FINE NUOVA LOGICA PER IL FILTRO ---
            
        else: # Se nessun tipo di ottimizzazione corrisponde
            return ({"status": "error", "error": f"Unsupported optimization_type: {optimization_type}"}, 400, response_cors_headers)

        if result_df is None or result_df.empty: # Controllo dopo tutte le ottimizzazioni
            return ({"status": "error", "error": "Optimization resulted in an empty DataFrame or was not processed."}, 400, response_cors_headers)
            
        current_utc_time = datetime.datetime.utcnow()
        opt_info_for_hash_and_path = {
            "files": actual_silver_uris_for_manifest, 
            "optimization_type": optimization_type,
            "params": params, "output_name": output_name_base
        }
        op_id_hash = create_operation_hash(opt_info_for_hash_and_path)
        result_df["gold_op_id"] = op_id_hash
        result_df["gold_op_type"] = optimization_type
        result_df["gold_op_ts"] = current_utc_time
        if "creation_date" not in result_df.columns: result_df["creation_date"] = current_utc_time.date()
        
        gold_object_full_path = determine_gold_path(opt_info_for_hash_and_path, SILVER_BUCKET_NAME_CFG, actual_silver_uris_for_manifest, date_obj=current_utc_time)
        gold_object_base_path = os.path.dirname(gold_object_full_path)
        
        with tempfile.NamedTemporaryFile(delete=False, suffix=".parquet") as tmp_g_out:
            tmp_gold_out_path = tmp_g_out.name
        result_df.to_parquet(tmp_gold_out_path, index=False, engine='pyarrow')
        
        gold_blob_gcs = storage_client_instance.bucket(GOLD_BUCKET_NAME_CFG).blob(gold_object_full_path)
        gold_blob_gcs.upload_from_filename(tmp_gold_out_path)
        print(f"Uploaded Gold Parquet to gs://{GOLD_BUCKET_NAME_CFG}/{gold_object_full_path}")
        
        bq_table_full_id_gold = None
        if data_payload.get("create_bq_table", False) is True:
            bq_table_name_for_gold = f"{output_name_base}_{op_id_hash[:8]}"
            bq_table_full_id_gold = create_gold_bq_table(result_df, bq_table_name_for_gold, current_project_id, dataset_id=GOLD_BQ_DATASET_CFG)
        
        manifest_gold_gcs_path = f"{gold_object_base_path}/_optimization_manifest.json"
        meta_blob_gold_gcs = storage_client_instance.bucket(GOLD_BUCKET_NAME_CFG).blob(manifest_gold_gcs_path)
        manifest_gold_entries = []
        if meta_blob_gold_gcs.exists():
            try:
                loaded_manifest = json.loads(meta_blob_gold_gcs.download_as_text())
                if isinstance(loaded_manifest, list): manifest_gold_entries = loaded_manifest
            except Exception: pass # Inizia nuovo se corrotto/non lista
            
        manifest_gold_entries = [e for e in manifest_gold_entries if e.get("optimization_id") != op_id_hash]
        manifest_entry = {
            "optimization_id": op_id_hash, "optimization_type": optimization_type, "description": description,
            "silver_sources": actual_silver_uris_for_manifest,
            "gold_output_gcs_uri": f"gs://{GOLD_BUCKET_NAME_CFG}/{gold_object_full_path}",
            "optimization_params": params, "gold_created_at": current_utc_time.isoformat() + "Z",
            "record_count": len(result_df), 
            "gold_df_schema": {col: str(dtype) for col, dtype in result_df.dtypes.items()},
            "gold_bigquery_table": bq_table_full_id_gold,
            "gold_path_prefix_base": gold_object_base_path
        }
        manifest_gold_entries.append(manifest_entry)
        meta_blob_gold_gcs.upload_from_string(json.dumps(manifest_gold_entries, indent=2), content_type="application/json")
        print(f"Gold manifest updated at gs://{GOLD_BUCKET_NAME_CFG}/{manifest_gold_gcs_path}")
        
        response_data = {
            "status": "success", "message": "Gold optimization completed.",
            "optimization_id": op_id_hash,
            "gold_output_gcs_uri": f"gs://{GOLD_BUCKET_NAME_CFG}/{gold_object_full_path}",
            "record_count": len(result_df), "gold_df_columns": list(result_df.columns),
            "gold_bigquery_table": bq_table_full_id_gold
        }
        return (response_data, 200, response_cors_headers)
            
    except Exception as e:
        error_msg = str(e)
        print(f"Unhandled error in silver_to_gold for input files '{data_payload.get('files', 'N/A')}': {error_msg}")
        traceback.print_exc() 
        return ({"status": "error", "error": error_msg, "details": traceback.format_exc()}, 500, response_cors_headers)
    
    finally:
        for temp_p in tmp_silver_files_paths:
            if temp_p and os.path.exists(temp_p):
                try: os.unlink(temp_p)
                except Exception as e_unlink_s: print(f"Error unlinking temp silver file {temp_p}: {e_unlink_s}")
        if tmp_gold_out_path and os.path.exists(tmp_gold_out_path):
            try: os.unlink(tmp_gold_out_path)
            except Exception as e_unlink_g: print(f"Error unlinking temp gold file {tmp_gold_out_path}: {e_unlink_g}")