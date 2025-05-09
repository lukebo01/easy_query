import functions_framework
from google.cloud import bigquery
import datetime
import os
import re

# Configurazione (meglio se da variabili d'ambiente della funzione)
PROJECT_ID = os.environ.get("GCP_PROJECT") # Automaticamente impostato da Cloud Functions
BIGQUERY_DATASET_ID = "metadata_store" # Sostituisci se diverso
BIGQUERY_TABLE_ID = "bronze_file_metadata" # Sostituisci se diverso
BIGQUERY_TABLE_FULL_ID = f"{PROJECT_ID}.{BIGQUERY_DATASET_ID}.{BIGQUERY_TABLE_ID}"

bq_client = bigquery.Client()

def _get_file_extension(file_name):
    parts = file_name.split('.')
    if len(parts) > 1:
        return parts[-1].lower()
    return "" # Nessuna estensione

@functions_framework.cloud_event
def gcs_metadata_extractor(cloud_event):
    """
    Triggered by a change to a Cloud Storage bucket.
    Extracts metadata and stores it in BigQuery.
    """
    data = cloud_event.data
    bucket_name = data["bucket"]
    file_path_full = data["name"] # Include il percorso completo nel bucket

    print(f"Processing file: {file_path_full} from bucket: {bucket_name}")

    # Evita di processare le cartelle stesse se create come oggetti vuoti
    if file_path_full.endswith('/'):
        print(f"Skipping folder object: {file_path_full}")
        return

    file_name_only = os.path.basename(file_path_full)
    file_extension = _get_file_extension(file_name_only)
    gcs_uri = f"gs://{bucket_name}/{file_path_full}"

    # Costruisci il record per BigQuery
    # Usiamo MERGE per l'idempotenza: se il file viene ri-uploadato o l'evento scatta più volte
    # si aggiorna il record esistente invece di crearne uno nuovo.
    
    # Alcuni campi potrebbero non essere sempre presenti nell'evento, usa .get()
    # e gestisci i valori predefiniti se necessario
    
    row_to_insert = {
        "file_gcs_uri": gcs_uri,
        "bucket_name": bucket_name,
        "file_path": file_path_full,
        "file_name": file_name_only,
        "file_extension": file_extension,
        "content_type": data.get("contentType", ""),
        "file_size_bytes": int(data.get("size", 0)),
        "gcs_generation_id": str(data.get("generation", "")), # 'generation' è un int, converti a stringa
        "gcs_metageneration_id": str(data.get("metageneration", "")), # 'metageneration' è un int, converti
        "gcs_crc32c_hash": data.get("crc32c", ""),
        "gcs_md5_hash": data.get("md5Hash", ""),
        "event_time": data.get("timeCreated"), # o data.get("updated") a seconda della logica desiderata
        "metadata_ingestion_time": datetime.datetime.utcnow().isoformat(),
        "processing_status": "AVAILABLE_IN_BRONZE", # Stato iniziale
        "last_processed_by": "gcs_metadata_extractor_function", # Nome di questa funzione
        "last_processing_notes": "Metadata ingested from GCS event.",
        # "source_system": "UNKNOWN", # Imposta se puoi derivarlo dal path o da metadati GCS custom
        # "data_domain": "GENERAL", # Imposta se puoi derivarlo
        # "tags": []
    }

    # Utilizzo di MERGE per l'idempotenza
    # Nota: per usare MERGE, la tabella deve esistere.
    # La colonna 'file_gcs_uri' è la nostra chiave per il MERGE.
    
    # Costruisci la query MERGE
    # Le colonne devono corrispondere esattamente a quelle della tabella BQ
    # e i valori devono essere correttamente formattati (es. stringhe tra apici, timestamp)
    
    # Dobbiamo gestire i tipi corretti per la query SQL MERGE.
    # Per i TIMESTAMP, BigQuery si aspetta 'YYYY-MM-DD HH:MM:SS.SSSSSS+00:00'
    # Python datetime.isoformat() è vicino, ma BigQuery MERGE tramite query testuale
    # potrebbe essere pignolo. È più sicuro usare i placeholder con `query_parameters`
    # se possibile, ma qui costruiamo una stringa. L'API `insert_rows_json` è spesso più semplice.
    
    # Alternativa più semplice e spesso preferita: insert_rows_json
    # Questo non gestisce l'idempotenza a livello di DB come MERGE,
    # ma se il tuo `file_gcs_uri` è la chiave primaria, una seconda esecuzione
    # potrebbe fallire (se la chiave primaria ha un vincolo unique) o
    # potresti dover gestire la duplicazione con query successive.
    # Per un semplice catalogo di metadati, e se gli eventi sono generalmente unici,
    # `insert_rows_json` può essere sufficiente e più semplice.
    # Se l'idempotenza è critica, MERGE è più robusto.
    # Per semplicità qui usiamo insert_rows_json e assumiamo che il trigger GCS sia affidabile.
    # Per una reale idempotenza con GCS, si potrebbe avere una logica più complessa
    # o affidarsi al versioning GCS per capire se è davvero un "nuovo" file.

    # Semplifichiamo con insert_rows_json. Per un vero upsert, MERGE è meglio ma più complesso da scrivere qui.
    errors = bq_client.insert_rows_json(BIGQUERY_TABLE_FULL_ID, [row_to_insert])
    if errors == []:
        print(f"Metadata for {gcs_uri} successfully inserted into BigQuery.")
    else:
        print(f"Errors occurred while inserting metadata for {gcs_uri}: {errors}")
        # Potresti voler sollevare un'eccezione qui o gestire l'errore in modo più specifico
        # raise Exception(f"BigQuery insert errors: {errors}")

    # Se vuoi usare MERGE, la query sarebbe qualcosa del genere:
    # merge_query = f"""
    # MERGE `{BIGQUERY_TABLE_FULL_ID}` T
    # USING (SELECT
    #     '{row_to_insert['file_gcs_uri']}' as file_gcs_uri,
    #     '{row_to_insert['bucket_name']}' as bucket_name,
    #     '{row_to_insert['file_path']}' as file_path,
    #     '{row_to_insert['file_name']}' as file_name,
    #     '{row_to_insert['file_extension']}' as file_extension,
    #     '{row_to_insert['content_type']}' as content_type,
    #     {row_to_insert['file_size_bytes']} as file_size_bytes,
    #     '{row_to_insert['gcs_generation_id']}' as gcs_generation_id,
    #     '{row_to_insert['gcs_metageneration_id']}' as gcs_metageneration_id,
    #     '{row_to_insert['gcs_crc32c_hash']}' as gcs_crc32c_hash,
    #     '{row_to_insert['gcs_md5_hash']}' as gcs_md5_hash,
    #     TIMESTAMP('{row_to_insert['event_time']}') as event_time,
    #     TIMESTAMP('{row_to_insert['metadata_ingestion_time']}') as metadata_ingestion_time,
    #     '{row_to_insert['processing_status']}' as processing_status,
    #     '{row_to_insert['last_processed_by']}' as last_processed_by,
    #     '{row_to_insert['last_processing_notes']}' as last_processing_notes
    # ) S
    # ON T.file_gcs_uri = S.file_gcs_uri
    # WHEN MATCHED THEN
    #   UPDATE SET
    #     bucket_name = S.bucket_name,
    #     file_path = S.file_path,
    #     file_name = S.file_name,
    #     file_extension = S.file_extension,
    #     content_type = S.content_type,
    #     file_size_bytes = S.file_size_bytes,
    #     gcs_generation_id = S.gcs_generation_id,
    #     gcs_metageneration_id = S.gcs_metageneration_id,
    #     gcs_crc32c_hash = S.gcs_crc32c_hash,
    #     gcs_md5_hash = S.gcs_md5_hash,
    #     event_time = S.event_time,
    #     metadata_ingestion_time = S.metadata_ingestion_time,
    #     processing_status = S.processing_status, -- O una logica per non sovrascrivere se già in processing
    #     last_processed_by = S.last_processed_by,
    #     last_processing_notes = S.last_processing_notes
    # WHEN NOT MATCHED THEN
    #   INSERT (file_gcs_uri, bucket_name, file_path, file_name, file_extension, content_type, file_size_bytes, gcs_generation_id, gcs_metageneration_id, gcs_crc32c_hash, gcs_md5_hash, event_time, metadata_ingestion_time, processing_status, last_processed_by, last_processing_notes)
    #   VALUES(file_gcs_uri, bucket_name, file_path, file_name, file_extension, content_type, file_size_bytes, gcs_generation_id, gcs_metageneration_id, gcs_crc32c_hash, gcs_md5_hash, event_time, metadata_ingestion_time, processing_status, last_processed_by, last_processing_notes)
    # """
    # try:
    #     query_job = bq_client.query(merge_query)
    #     query_job.result()  # Attendi il completamento della query
    #     print(f"Metadata for {gcs_uri} successfully merged into BigQuery.")
    # except Exception as e:
    #     print(f"Error merging data for {gcs_uri}: {e}")
    #     raise