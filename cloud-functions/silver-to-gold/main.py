import os
import datetime
import json
import pandas as pd
from google.cloud import bigquery
import functions_framework
from flask import Request
import traceback
from typing import Dict, Any, Optional

# --- CONFIGURAZIONE GLOBALE ---
# Questo dataset DEVE ESISTERE nel progetto GCP.
GOLD_BQ_DATASET_CFG = "gold_layer_dataset"

bq_client_instance: Optional[bigquery.Client] = None
cfg_project_id_initialized: Optional[str] = None

# --- FUNZIONI HELPER ---
def _initialize_bigquery_client(current_project_id: str):
    global bq_client_instance, cfg_project_id_initialized
    if cfg_project_id_initialized != current_project_id or bq_client_instance is None:
        print(f"silver-to-gold: Initializing BigQuery client for project: {current_project_id}")
        try:
            bq_client_instance = bigquery.Client(project=current_project_id)
            cfg_project_id_initialized = current_project_id
            print(f"silver-to-gold: BigQuery client initialized successfully for project {current_project_id}.")
        except Exception as e_init:
            print(f"FATAL: Failed to initialize BigQuery client for project {current_project_id}: {e_init}")
            traceback.print_exc()
            raise ConnectionError(f"Failed to initialize BigQuery client: {e_init}")

def execute_query_and_save_as_table(query: str, table_name: str, project_id: str, dataset_id: str) -> Dict[str, Any]:
    """
    Esegue una query SQL in BigQuery e salva i risultati in una nuova tabella.

    Args:
        query: Query SQL da eseguire
        table_name: Nome della tabella da creare
        project_id: ID del progetto GCP
        dataset_id: ID del dataset BigQuery dove salvare la tabella

    Returns:
        Dict[str, Any]: Dizionario con informazioni sul risultato dell'operazione
    """
    global bq_client_instance
    if bq_client_instance is None:
        raise ConnectionError("BigQuery client not initialized.")

    # Sanitizza il nome della tabella per BigQuery
    table_name = ''.join(c if c.isalnum() or c == '_' else '_' for c in table_name)
    if not table_name[0].isalpha() and not table_name[0] == '_':
        table_name = f"_{table_name}"
    if len(table_name) > 1024:
        table_name = table_name[:1024]

    table_id = f"{project_id}.{dataset_id}.{table_name}"
    print(f"Executing query and saving results to table: {table_id}")

    try:
        # Configura il job di query per salvare i risultati in una tabella
        job_config = bigquery.QueryJobConfig(
            destination=table_id,
            write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,  # Sovrascrive se esiste
            allow_large_results=True,
        )
        
        # Esegui la query
        query_job = bq_client_instance.query(
            query,
            job_config=job_config,
        )
        
        # Attendi il completamento del job
        result = query_job.result()
        
        # Ottieni informazioni sulla tabella creata
        table = bq_client_instance.get_table(table_id)
        
        return {
            "status": "success",
            "gold_bigquery_table": table_id,
            "record_count": table.num_rows,
            "creation_time": table.created.isoformat(),
            "query_bytes_processed": query_job.total_bytes_processed,
            "query_slot_milliseconds": query_job.slot_millis
        }
    except Exception as e:
        print(f"Error executing query and saving to table: {e}")
        traceback.print_exc()
        raise Exception(f"Failed to execute query and save to table: {e}")

# --- FUNZIONE PRINCIPALE CLOUD FUNCTION ---
@functions_framework.http
def silver_to_gold(request: Request):
    """
    Cloud Function che accetta una query SQL e un nome di tabella,
    esegue la query e salva i risultati in una nuova tabella BigQuery.
    
    Richiesta:
    {
        "query": "SELECT * FROM `project.dataset.table` WHERE condition",
        "output_name": "nome_tabella_gold"
    }
    """
    if request.method == 'OPTIONS':
        headers = {'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type, Authorization', 'Access-Control-Max-Age': '3600'}
        return ('', 204, headers)
    response_cors_headers = {'Access-Control-Allow-Origin': '*'}

    try:
        # Determina l'ID progetto
        project_id_from_env_gcp = os.environ.get("GCP_PROJECT")
        project_id_from_env_google = os.environ.get("GOOGLE_CLOUD_PROJECT")
        current_project_id = project_id_from_env_gcp or project_id_from_env_google

        print(f"silver-to-gold: Using project_id: {current_project_id}")

        if not current_project_id:
            print("CRITICAL ERROR: Project ID could not be determined from env vars.")
            return ({"status": "error", "error": "Project ID env var not configured."}, 500, response_cors_headers)

        # Inizializza il client BigQuery
        _initialize_bigquery_client(current_project_id)

        # Valida il payload della richiesta
        if not request.is_json:
            return ({"status": "error", "error": "Invalid content type, expected application/json"}, 415, response_cors_headers)
        
        data_payload = request.get_json(silent=True)
        if data_payload is None:
            return ({"status": "error", "error": "Malformed JSON or empty request body"}, 400, response_cors_headers)
        
        # Estrai parametri richiesti
        query = data_payload.get("query")
        output_name = data_payload.get("output_name")
        description = data_payload.get("description", "User-saved query result")
        
        # Convalida parametri
        if not query or not isinstance(query, str):
            return ({"status": "error", "error": "'query' parameter must be a non-empty string"}, 400, response_cors_headers)
        
        if not output_name or not isinstance(output_name, str):
            return ({"status": "error", "error": "'output_name' parameter must be a non-empty string"}, 400, response_cors_headers)
        
        # Esegui la query e salva i risultati
        try:
            result = execute_query_and_save_as_table(query, output_name, current_project_id, GOLD_BQ_DATASET_CFG)
            
            # Aggiungi campi aggiuntivi alla risposta
            result["message"] = f"Query results saved successfully to table {result['gold_bigquery_table']}"
            result["optimization_type"] = "query_result"
            result["description"] = description
            result["timestamp"] = datetime.datetime.utcnow().isoformat()
            
            return (result, 200, response_cors_headers)
            
        except Exception as e_query:
            error_msg = str(e_query)
            print(f"Error executing query or saving results: {error_msg}")
            return ({"status": "error", "error": f"Failed to execute query: {error_msg}"}, 500, response_cors_headers)

    except Exception as e_main:
        error_msg = str(e_main)
        print(f"CRITICAL UNHANDLED ERROR in silver_to_gold: {error_msg}")
        traceback.print_exc()
        return ({"status": "error", "error": error_msg, "details": traceback.format_exc()}, 500, response_cors_headers)