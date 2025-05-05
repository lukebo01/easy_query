import os, os.path, tempfile, datetime, json
import pandas as pd
from google.cloud import storage
from cloudevents.http import CloudEvent          # <-- novità
import functions_framework                       # SDK per Gen‑2


SILVER_BUCKET = "soy-transducer-456512-t0-easyquery-silver"
SILVER_PREFIX = "auto_ingested/demo_table"

storage_client = storage.Client()

# ↓ Decoratore corretto per funzioni Gen‑2 (CloudEvents)
@functions_framework.cloud_event
def bronze_to_silver(event: CloudEvent) -> None:
    """
    Trigger: OBJECT_FINALIZE sul bucket bronze.
    Converte CSV/JSON/Parquet in Parquet e li salva nel bucket silver
    (layout Iceberg semplificato).
    """
    data = event.data                              # payload JSON dall’evento
    bucket_name = data["bucket"]
    name        = data["name"]

    # Filtra formati non gestiti
    if not name.lower().endswith((".csv", ".parquet", ".json")):
        print(f"Skip formato non gestito: {name}")
        return

    # 1. Scarica oggetto bronze
    bronze_blob = storage_client.bucket(bucket_name).blob(name)
    tmp_in      = tempfile.NamedTemporaryFile()
    bronze_blob.download_to_filename(tmp_in.name)

    # 2. Carica in DataFrame
    if name.lower().endswith(".csv"):
        df = pd.read_csv(tmp_in.name)
    elif name.lower().endswith(".json"):
        df = pd.read_json(tmp_in.name, lines=True)
    else:
        df = pd.read_parquet(tmp_in.name)

    df["ingestion_ts"] = datetime.datetime.utcnow()

    # 3. Scrivi Parquet in bucket silver (partizione yyyy/mm/dd)
    partition = datetime.datetime.utcnow().strftime("%Y/%m/%d")
    silver_path = (
        f"{SILVER_PREFIX}/data/date={partition}/{os.path.basename(name)}.parquet"
    )

    tmp_out = tempfile.NamedTemporaryFile()
    df.to_parquet(tmp_out.name, index=False)

    silver_blob = storage_client.bucket(SILVER_BUCKET).blob(silver_path)
    silver_blob.upload_from_filename(tmp_out.name)
    print(f"Caricato in silver: {silver_path}")

    # 4. Aggiorna manifest Iceberg minimale
    meta_blob = storage_client.bucket(SILVER_BUCKET).blob(
        f"{SILVER_PREFIX}/metadata/files.json"
    )
    try:
        manifest = json.loads(meta_blob.download_as_text())
    except Exception:
        manifest = []
    manifest.append({"file": silver_path, "rows": len(df)})
    meta_blob.upload_from_string(
        json.dumps(manifest), content_type="application/json"
    )
