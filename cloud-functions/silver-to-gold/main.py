import os, tempfile, datetime, json, hashlib
import pandas as pd
import numpy as np
from google.cloud import storage, bigquery
from flask import Request
import functions_framework
from typing import List, Dict, Any, Optional

SILVER_BUCKET = "soy-transducer-456512-t0-easyquery-silver"
GOLD_BUCKET = "soy-transducer-456512-t0-easyquery-gold"  # Assicurati che esista
# Rimuoviamo il prefisso fisso
# SILVER_PREFIX = "auto_ingested/demo_table"
# GOLD_PREFIX = "optimized"

storage_client = storage.Client()
bq_client = bigquery.Client()


def determine_gold_path(optimization_info, input_files=None, date=None):
    """
    Determina un percorso gerarchico per i dati Gold basato sull'ottimizzazione.
    
    Args:
        optimization_info: Informazioni sull'ottimizzazione (tipo, parametri, ecc.)
        input_files: Lista dei file Silver di input
        date: Data per la partizione
    
    Returns:
        path: Percorso gerarchico per i dati Gold
    """
    date = date or datetime.datetime.utcnow()
    
    # Estrai tipo di ottimizzazione
    opt_type = optimization_info.get("optimization_type", "unknown")
    
    # Determina il dominio dei dati basato sui file di input
    data_domain = "cross-domain"  # Default se ci sono file da domini diversi
    
    if input_files:
        # Cerca di determinare il dominio dai percorsi dei file silver
        domains = set()
        for file_path in input_files:
            parts = file_path.split('/')
            if len(parts) > 1 and parts[0] == "silver":
                domains.add(parts[1])
        
        # Se tutti i file sono dello stesso dominio, usa quello
        if len(domains) == 1:
            data_domain = domains.pop()
    
    # Determina il livello di aggregazione o operazione
    agg_level = "default"
    if opt_type == "aggregate":
        agg_level = "aggregated"
        # Verifica se c'è un'aggregazione temporale
        group_by = optimization_info.get("params", {}).get("group_by", [])
        time_fields = [f for f in group_by if any(time_part in f.lower() for time_part in ["date", "year", "month", "day", "time"])]
        
        if time_fields:
            for field in time_fields:
                if "year" in field.lower():
                    agg_level = "yearly"
                elif "month" in field.lower():
                    agg_level = "monthly"
                elif "day" in field.lower() or "date" in field.lower():
                    agg_level = "daily"
                elif "hour" in field.lower():
                    agg_level = "hourly"
    elif opt_type == "join":
        agg_level = "joined"
    elif opt_type == "filter":
        agg_level = "filtered"
    elif opt_type == "denormalize":
        agg_level = "denormalized"
    
    # Identifica il prodotto di dati in base all'output_name
    data_product = optimization_info.get("output_name", "generic_data")
    
    # Hash univoco per l'operazione
    operation_hash = optimization_info.get("hash", create_hash(optimization_info))
    
    # Data della partizione
    date_partition = date.strftime("%Y/%m/%d")
    
    # Costruisci la gerarchia
    hierarchy = [
        "gold",                 # Livello
        data_domain,            # Dominio (finance, sales, hr, ecc.)
        opt_type,               # Tipo di ottimizzazione (aggregate, join, filter, ecc.)
        agg_level,              # Livello di aggregazione o dettaglio
        data_product,           # Nome del prodotto di dati
        f"date={date_partition}" # Partizione temporale
    ]
    
    # Costruisci e restituisci il percorso
    base_path = "/".join(hierarchy)
    return f"{base_path}/data_{operation_hash}.parquet"


def create_hash(data: Dict[str, Any]) -> str:
    """Crea un hash univoco per l'operazione di ottimizzazione."""
    hash_input = json.dumps(data, sort_keys=True)
    return hashlib.sha256(hash_input.encode()).hexdigest()[:12]

def create_partitioned_table(df: pd.DataFrame, table_name: str) -> str:
    """Crea una tabella BigQuery partitionata."""
    dataset_ref = bq_client.dataset("gold_optimized")
    table_ref = dataset_ref.table(table_name)
    
    # Converti date in formato compatibile con BigQuery
    for col in df.select_dtypes(include=['datetime64']).columns:
        df[col] = df[col].dt.strftime('%Y-%m-%d %H:%M:%S')
    
    # Crea schema BigQuery dai tipi di dati del DataFrame
    schema = []
    for col_name, dtype in df.dtypes.items():
        if pd.api.types.is_integer_dtype(dtype):
            bq_type = "INTEGER"
        elif pd.api.types.is_float_dtype(dtype):
            bq_type = "FLOAT"
        elif pd.api.types.is_bool_dtype(dtype):
            bq_type = "BOOLEAN"
        elif pd.api.types.is_datetime64_dtype(dtype):
            bq_type = "TIMESTAMP"
        else:
            bq_type = "STRING"
        
        schema.append(bigquery.SchemaField(col_name, bq_type))
    
    # Crea la tabella con partizione per data
    table = bigquery.Table(table_ref, schema=schema)
    
    # Imposta partizione per data di creazione
    table.time_partitioning = bigquery.TimePartitioning(
        type_=bigquery.TimePartitioningType.DAY,
        field="creation_date"  # Assicurati che questa colonna esista
    )
    
    table = bq_client.create_table(table, exists_ok=True)
    
    # Carica dati nella tabella
    job_config = bigquery.LoadJobConfig(
        schema=schema,
        write_disposition="WRITE_TRUNCATE"  # Sovrascrivi se esiste
    )
    
    # Convertire il DataFrame in un file JSON per il caricamento
    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".json")
    df.to_json(tmp.name, orient="records", lines=True)
    
    with open(tmp.name, "rb") as source_file:
        job = bq_client.load_table_from_file(
            source_file, table_ref, job_config=job_config
        )
    
    job.result()  # Attendi completamento
    os.unlink(tmp.name)  # Pulisci file temporaneo
    
    return f"{dataset_ref.dataset_id}.{table_name}"

@functions_framework.http
def silver_to_gold(request: Request):
    """
    Funzione HTTP per ottimizzare dati dal livello Silver al livello Gold.
    Supporta varie operazioni di ottimizzazione come:
    - Aggregazioni
    - Joins
    - Filtraggio
    - Re-partitioning
    
    Prende un JSON con:
    - files: elenco dei file Silver da ottimizzare
    - optimization_type: tipo di ottimizzazione (aggregate, join, filter, etc.)
    - optimization_params: parametri specifici per l'ottimizzazione
    - output_name: nome per i dati ottimizzati
    - description: descrizione dell'ottimizzazione
    """
    try:
        data = request.get_json()
        if not data:
            return ({"status": "error", "error": "Missing request JSON"}, 400)
            
        silver_files = data.get("files", [])
        if not silver_files:
            return ({"status": "error", "error": "No input files specified"}, 400)
            
        optimization_type = data.get("optimization_type")
        if not optimization_type:
            return ({"status": "error", "error": "No optimization type specified"}, 400)
            
        params = data.get("optimization_params", {})
        output_name = data.get("output_name", f"optimized_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}")
        description = data.get("description", "Ottimizzazione automatica")
        
        # Hash per evitare duplicazioni
        optimization_hash = create_hash({
            "files": silver_files,
            "type": optimization_type,
            "params": params
        })
        
        # 1. Carica i dati Silver
        dataframes = []
        file_schemas = []
        
        for file_path in silver_files:
            if file_path.startswith("gs://"):
                # Rimuovi prefisso gs://
                file_path = file_path[5:]
                bucket_name, blob_name = file_path.split("/", 1)
            else:
                bucket_name = SILVER_BUCKET
                blob_name = file_path
                
            blob = storage_client.bucket(bucket_name).blob(blob_name)
            tmp = tempfile.NamedTemporaryFile(delete=False)
            blob.download_to_filename(tmp.name)
            
            df = pd.read_parquet(tmp.name)
            dataframes.append(df)
            file_schemas.append(list(df.columns))
            os.unlink(tmp.name)
        
        # 2. Esegui l'ottimizzazione in base al tipo
        if optimization_type == "aggregate":
            # Aggregazione
            group_by_cols = params.get("group_by", [])
            agg_functions = params.get("aggregations", {})
            
            if not group_by_cols or not agg_functions:
                return ({"status": "error", "error": "Missing groupby or aggregation parameters"}, 400)
                
            result_df = dataframes[0].groupby(group_by_cols).agg(agg_functions).reset_index()
            
        elif optimization_type == "join":
            # Join tra dataframes
            if len(dataframes) < 2:
                return ({"status": "error", "error": "Join requires at least 2 dataframes"}, 400)
                
            join_columns = params.get("join_columns", [])
            join_type = params.get("join_type", "inner")
            
            if not join_columns:
                return ({"status": "error", "error": "Missing join columns"}, 400)
                
            result_df = dataframes[0]
            for i, df in enumerate(dataframes[1:], 1):
                # Se join_columns è una lista di tuple, usa la posizione i-1
                # altrimenti usa lo stesso join_column per tutti
                if isinstance(join_columns[0], list) or isinstance(join_columns[0], tuple):
                    left_on, right_on = join_columns[i-1]
                else:
                    left_on = right_on = join_columns
                    
                result_df = result_df.merge(df, left_on=left_on, right_on=right_on, how=join_type)
                
        elif optimization_type == "filter":
            # Filtraggio
            filter_conditions = params.get("conditions", [])
            if not filter_conditions:
                return ({"status": "error", "error": "Missing filter conditions"}, 400)
                
            result_df = dataframes[0]
            # Applica i filtri sequenzialmente
            for condition in filter_conditions:
                column = condition.get("column")
                operator = condition.get("operator", "==")
                value = condition.get("value")
                
                if not column or value is None:
                    continue
                    
                # Applica il filtro
                if operator == "==":
                    result_df = result_df[result_df[column] == value]
                elif operator == "!=":
                    result_df = result_df[result_df[column] != value]
                elif operator == ">":
                    result_df = result_df[result_df[column] > value]
                elif operator == ">=":
                    result_df = result_df[result_df[column] >= value]
                elif operator == "<":
                    result_df = result_df[result_df[column] < value]
                elif operator == "<=":
                    result_df = result_df[result_df[column] <= value]
                elif operator == "in":
                    result_df = result_df[result_df[column].isin(value)]
                elif operator == "contains":
                    result_df = result_df[result_df[column].str.contains(value, na=False)]
                    
        elif optimization_type == "denormalize":
            # Denormalizzazione - unisce più tabelle per ottimizzare query
            if len(dataframes) < 2:
                return ({"status": "error", "error": "Denormalize requires at least 2 dataframes"}, 400)
                
            result_df = dataframes[0]
            join_maps = params.get("join_maps", [])
            
            for i, df in enumerate(dataframes[1:], 1):
                if i-1 < len(join_maps):
                    join_map = join_maps[i-1]
                    left_on = join_map.get("left_on")
                    right_on = join_map.get("right_on")
                    how = join_map.get("how", "left")
                    
                    result_df = result_df.merge(df, left_on=left_on, right_on=right_on, how=how)
        else:
            return ({"status": "error", "error": f"Unsupported optimization type: {optimization_type}"}, 400)
            
        # 3. Aggiungi metadati all'ottimizzazione
        result_df["optimization_id"] = optimization_hash
        result_df["optimization_type"] = optimization_type
        result_df["optimization_ts"] = datetime.datetime.now()
        result_df["creation_date"] = datetime.datetime.now().date()
        
        # 4. Determina il percorso gerarchico per i dati Gold
        optimization_info = {
            "optimization_type": optimization_type,
            "params": params,
            "output_name": output_name,
            "hash": optimization_hash
        }
        gold_path = determine_gold_path(optimization_info, silver_files)
        
        # 5. Salva risultato in formato ottimizzato (Parquet)
        tmp_out = tempfile.NamedTemporaryFile(delete=False)
        result_df.to_parquet(tmp_out.name, index=False)
        
        gold_blob = storage_client.bucket(GOLD_BUCKET).blob(gold_path)
        gold_blob.upload_from_filename(tmp_out.name)
        
        # 6. Crea una tabella BigQuery ottimizzata se richiesto
        bq_table_id = None
        if data.get("create_bq_table", False):
            bq_table_name = f"{output_name}_{optimization_hash}"
            bq_table_id = create_partitioned_table(result_df, bq_table_name)
        
        # 7. Aggiorna manifest delle ottimizzazioni - usa la struttura gerarchica
        # Estrai il percorso base senza il file
        base_path = os.path.dirname(gold_path)
        meta_blob = storage_client.bucket(GOLD_BUCKET).blob(f"{base_path}/manifest.json")
        try:
            manifest = json.loads(meta_blob.download_as_text())
        except Exception:
            manifest = []
            
        manifest_entry = {
            "id": optimization_hash,
            "type": optimization_type,
            "files": silver_files,
            "output_path": gold_path,
            "params": params,
            "description": description,
            "created_at": datetime.datetime.now().isoformat(),
            "row_count": len(result_df),
            "columns": list(result_df.columns),
            "bigquery_table": bq_table_id,
            "hierarchy": base_path
        }
        
        manifest.append(manifest_entry)
        meta_blob.upload_from_string(json.dumps(manifest), content_type="application/json")
        
        # Aggiorna anche il manifest globale per tutte le ottimizzazioni
        global_meta_blob = storage_client.bucket(GOLD_BUCKET).blob("gold/global_manifest.json")
        try:
            global_manifest = json.loads(global_meta_blob.download_as_text())
        except Exception:
            global_manifest = []
            
        global_manifest.append(manifest_entry)
        global_meta_blob.upload_from_string(json.dumps(global_manifest), content_type="application/json")
        
        # Pulizia
        os.unlink(tmp_out.name)
        
        return ({
            "status": "success",
            "message": "Optimization complete",
            "output_path": gold_path,
            "optimization_id": optimization_hash,
            "row_count": len(result_df),
            "columns": list(result_df.columns),
            "bigquery_table": bq_table_id,
            "hierarchy": base_path
        }, 200)
            
    except Exception as e:
        return ({"status": "error", "error": str(e)}, 500)