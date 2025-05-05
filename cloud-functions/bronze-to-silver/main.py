import os, tempfile, datetime, json
import pandas as pd
from google.cloud import storage
from flask import Request
import functions_framework

SILVER_BUCKET = "soy-transducer-456512-t0-easyquery-silver"
SILVER_PREFIX = "auto_ingested/demo_table"

storage_client = storage.Client()

@functions_framework.http
def bronze_to_silver(request: Request):
    """
    Funzione HTTP.
    Riceve JSON con chiave 'path': "bucket/path/to/file.ext"
    Legge il file dal bucket bronze, lo converte in Parquet, lo scrive nel bucket silver
    e rimuove il file originale dal bucket bronze.
    """

    try:
        data = request.get_json()
        if not data or "path" not in data:
            return ("Missing 'path' in request JSON", 400)

        full_path = data["path"]
        bucket_name, *blob_parts = full_path.split("/", 1)
        if not blob_parts:
            return ("Invalid path format. Expected 'bucket/path/to/file'", 400)
        blob_name = blob_parts[0]

        # Filtra formati non gestiti
        if not blob_name.lower().endswith((".csv", ".parquet", ".json")):
            return (f"Formato non supportato: {blob_name}", 400)

        # 1. Scarica oggetto bronze
        bronze_blob = storage_client.bucket(bucket_name).blob(blob_name)
        tmp_in = tempfile.NamedTemporaryFile()
        bronze_blob.download_to_filename(tmp_in.name)

        # 2. Carica in DataFrame
        if blob_name.lower().endswith(".csv"):
            df = pd.read_csv(tmp_in.name)
        elif blob_name.lower().endswith(".json"):
            df = pd.read_json(tmp_in.name, lines=True)
        else:
            df = pd.read_parquet(tmp_in.name)

        df["ingestion_ts"] = datetime.datetime.utcnow()

        # 3. Scrivi Parquet in bucket silver (partizione yyyy/mm/dd)
        partition = datetime.datetime.utcnow().strftime("%Y/%m/%d")
        silver_path = f"{SILVER_PREFIX}/data/date={partition}/{os.path.basename(blob_name)}.parquet"

        tmp_out = tempfile.NamedTemporaryFile()
        df.to_parquet(tmp_out.name, index=False)

        silver_blob = storage_client.bucket(SILVER_BUCKET).blob(silver_path)
        silver_blob.upload_from_filename(tmp_out.name)

        # 4. Aggiorna manifest Iceberg minimale
        meta_blob = storage_client.bucket(SILVER_BUCKET).blob(f"{SILVER_PREFIX}/metadata/files.json")
        try:
            manifest = json.loads(meta_blob.download_as_text())
        except Exception:
            manifest = []
        manifest.append({"file": silver_path, "rows": len(df)})
        meta_blob.upload_from_string(json.dumps(manifest), content_type="application/json")

        # 5. Cancella l’oggetto originale dal bucket bronze
        bronze_blob.delete()

        return (f"Elaborato e caricato in silver: {silver_path}", 200)

    except Exception as e:
        return (f"Errore: {str(e)}", 500)
