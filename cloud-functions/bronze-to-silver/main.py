import os
import tempfile
import datetime
import json
import pandas as pd
from google.cloud import storage
from google.cloud import dataplex_v1
import functions_framework
from flask import Request, jsonify # Per il type hint di request
import io # Per BytesIO
import PyPDF2 # Per i PDF
from PIL import Image # Per le immagini
import base64 # Per la codifica base64 delle immagini
import traceback # Per un logging degli errori più dettagliato
from typing import List, Dict, Any, Optional
import time
import uuid

# --- CONFIGURAZIONE GLOBALE ---
# Bucket GCS dove risiedono i dati Silver.
# Non confondere con i prefissi radice per dati e manifest al suo interno.
SILVER_BUCKET_NAME = "silver-layer-bucket"

# Prefissi radice all'interno del SILVER_BUCKET_NAME per separare file di dati e manifest
SILVER_DATA_FILES_ROOT_PREFIX = "silver_data_files"  # Es: gs://silver-layer-bucket/silver_data_files/...
SILVER_MANIFESTS_ROOT_PREFIX = "silver_manifests" # Es: gs://silver-layer-bucket/silver_manifests/...

# Configurazione Dataplex
DATAPLEX_LOCATION = "europe-central2"  # Regione Dataplex, es. "europe-central2"

storage_client = storage.Client()
# Inizializzazione client Dataplex
dataplex_client = None

# --- FUNZIONI PER DATAPLEX ---

def trigger_dataplex_discovery(project_id: str):
    """Cloud Function HTTP trigger to create a Dataplex entity and launch a scan."""
    try:
        region = "europe-central2"
        lake = "easyquery-lake"
        zone = "silver-zone"
        
        gcs_path = f"gs://{SILVER_BUCKET_NAME}/{SILVER_DATA_FILES_ROOT_PREFIX}/{zone}/"
        
        entity_id = gcs_path.rstrip('/').split('/')[-1].replace('=', '_').replace('-', '_')
        entity_id = f"ent_{entity_id}_{uuid.uuid4().hex[:6]}"
        parent_entity_path = f"projects/{project_id}/locations/{region}/lakes/{lake}/zones/{zone}"
        entity_name_full = f"{parent_entity_path}/entities/{entity_id}"

        # Create Dataplex Entity
        metadata_client = dataplex_v1.MetadataServiceClient()
        entity = dataplex_v1.Entity(
            id=entity_id,
            display_name=f"Entity for {entity_id}",
            description="Entita generata via Cloud Function per Parquet",
            data_path=gcs_path,
            type_="FILESET",
            format_=dataplex_v1.StorageFormat(
                format_=dataplex_v1.StorageFormat.Format.PARQUET
            ),
            schema=dataplex_v1.Schema(user_managed=False)
        )

        metadata_client.create_entity(parent=parent_entity_path, entity=entity)

        # Launch Data Profile Scan
        scan_client = dataplex_v1.DataScanServiceClient()
        scan_id = f"scan_{entity_id}"
        scan_parent = f"projects/{project_id}/locations/{region}"

        data_scan = dataplex_v1.DataScan(
            display_name=f"Scan for {entity_id}",
            data=dataplex_v1.DataScan.Data(
                entity=entity_name_full
            ),
            data_profile=dataplex_v1.DataProfileSpec()
        )

        operation = scan_client.create_data_scan(
            parent=scan_parent,
            data_scan_id=scan_id,
            data_scan=data_scan
        )

        result = operation.result()

        return jsonify({
            "status": "success",
            "entity_id": entity_id,
            "scan_name": result.name
        })

    except Exception as e:
        return jsonify({"error": str(e)}), 500

# --- FUNZIONI HELPER ESISTENTI ---
def determine_silver_path_components(file_path_in_bronze: str, file_extension: str, content_type: Optional[str] = None) -> List[str]:
    """
    Determina i componenti del percorso gerarchico (dominio, categoria, contesto, partizione data)
    SENZA includere la radice "silver_data_files" o "silver_manifests".
    'file_path_in_bronze' è il nome del blob nel bucket bronze (es. "/data/raw/ditto/file.txt").
    """
    data_domain = "general"
    domain_patterns = {
        "finance": ["finance", "financial", "accounting", "invoice", "payment", "transaction"],
        "sales": ["sales", "revenue", "customer", "order", "product"],
        "marketing": ["marketing", "campaign", "advertisement", "promotion"],
        "hr": ["hr", "human_resources", "employee", "personnel", "recruitment"], # Corretto human-resources
        "operations": ["operations", "logistics", "inventory", "supply_chain"], # Corretto supply-chain
        "it": ["it", "technology", "system", "software", "hardware", "tech", "dev"] # Aggiunto dev
    }

    lower_file_path_in_bronze = file_path_in_bronze.lower()
    for domain, patterns in domain_patterns.items():
        if any(pattern in lower_file_path_in_bronze for pattern in patterns):
            data_domain = domain
            break

    file_category = "unknown"
    if file_extension in ["csv", "parquet", "json", "jsonl", "avro", "orc"]: file_category = "structured"
    elif file_extension in ["pdf", "txt", "doc", "docx", "md", "rtf", "html"]: file_category = "document"
    elif file_extension in ["jpg", "jpeg", "png", "gif", "tiff", "bmp", "svg", "webp", "heic"]: file_category = "image"
    elif file_extension in ["xls", "xlsx", "ods", "numbers"]: file_category = "spreadsheet"

    content_context = "generic" # Default più esplicito
    if content_type:
        ct_lower = content_type.lower()
        if "application/json" in ct_lower: content_context = "json_data" # Underscore per coerenza GCS
        elif "text/csv" in ct_lower: content_context = "csv_data"
        elif "application/pdf" in ct_lower: content_context = "pdf_document"
        elif "image/" in ct_lower: content_context = ct_lower.split('/')[-1].replace('jpeg', 'jpg') + "_image"
        elif "text/plain" in ct_lower: content_context = "text_file"
        elif "excel" in ct_lower or "spreadsheetml" in ct_lower: content_context = "excel_spreadsheet"

    # Formato data modificato per evitare il formato di partizionamento Hive "key=value"
    date_partition_str = datetime.datetime.utcnow().strftime("date_%Y_%m_%d") # Formato non-Hive

    path_components = [
        data_domain,
        file_category,
        content_context,
        date_partition_str
    ]
    return [part for part in path_components if part] # Rimuove eventuali None o stringhe vuote

def process_pdf(tmp_filename: str) -> pd.DataFrame:
    """Elabora un file PDF estraendo testo e metadata."""
    text_content = ""
    page_count = 0
    try:
        with open(tmp_filename, 'rb') as f:
            pdf_reader = PyPDF2.PdfReader(f)
            page_count = len(pdf_reader.pages)
            for page_num in range(page_count):
                page = pdf_reader.pages[page_num]
                page_text = page.extract_text()
                if page_text: # Aggiungi solo se c'è testo estratto
                    text_content += page_text.strip() + "\n\n" # Aggiungi newline doppio per separare pagine

        return pd.DataFrame([{
            "content_type_processed": "application/pdf",
            "extracted_text": text_content.strip(), # Rimuovi spazi extra alla fine
            "pdf_page_count": page_count,
            "deep_processed_ok": True # Boolean
        }])
    except Exception as e:
        print(f"Error processing PDF '{tmp_filename}': {e}")
        traceback.print_exc()
        return pd.DataFrame([{"error_processing_pdf": str(e), "deep_processed_ok": False}]) # Boolean

def process_image(tmp_filename: str, file_ext_original: str) -> pd.DataFrame:
    """Elabora un'immagine estraendo metadati di base e immagine in base64."""
    try:
        img = Image.open(tmp_filename)
        img_metadata = {
            "width": img.width,
            "height": img.height,
            "format_original": img.format,
            "mode": img.mode,
        }

        buffered = io.BytesIO() # Usare io.BytesIO
        # Salva in un formato web-friendly come PNG per base64
        save_format_for_b64 = 'PNG' if img.format != 'PNG' else img.format # Mantieni PNG se è già PNG
        if img.mode == 'P': # Converti palette in RGBA per evitare problemi con alcuni formati come GIF in PNG
            img = img.convert('RGBA')
        elif img.mode == 'CMYK': # Converti CMYK in RGB
             img = img.convert('RGB')

        img.save(buffered, format=save_format_for_b64)
        img_str_b64 = base64.b64encode(buffered.getvalue()).decode('utf-8')

        return pd.DataFrame([{
            "content_type_processed": f"image/{save_format_for_b64.lower()}",
            "image_width": img_metadata["width"], # Int
            "image_height": img_metadata["height"], # Int
            "image_format_original": img_metadata["format_original"],
            "image_mode": img_metadata["mode"],
            "image_data_b64": img_str_b64, # Stringa Base64
            "deep_processed_ok": True # Boolean
        }])
    except Exception as e:
        print(f"Error processing image '{tmp_filename}': {e}")
        traceback.print_exc()
        return pd.DataFrame([{"error_processing_image": str(e), "deep_processed_ok": False}]) # Boolean

# --- FUNZIONE PRINCIPALE CLOUD FUNCTION ---
@functions_framework.http
def bronze_to_silver(request: Request):
    """
    Funzione HTTP per convertire file dal bucket bronze al bucket silver.
    Salva i dati Parquet in una struttura di cartelle e i manifest JSON in una struttura parallela.
    Poi avvia una scansione Dataplex per aggiornare automaticamente il catalogo.
    """
    # Gestione della richiesta preflight CORS (OPTIONS)
    if request.method == 'OPTIONS':
        headers = {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type, Authorization',
            'Access-Control-Max-Age': '3600'
        }
        return ('', 204, headers)

    response_cors_headers = {'Access-Control-Allow-Origin': '*'}
    tmp_in_path, tmp_out_path = None, None
    data_payload = {} # Per avere 'path' disponibile nel blocco finally

    try:
        print(f"bronze-to-silver: Request received. Method: {request.method}")

        if not request.is_json:
            return ({"status": "error", "error": "Invalid content type, expected application/json"}, 415, response_cors_headers)

        data_payload = request.get_json(silent=True)
        if data_payload is None:
             return ({"status": "error", "error": "Malformed JSON or empty request body"}, 400, response_cors_headers)
        if "path" not in data_payload:
            return ({"status": "error", "error": "Missing 'path' in request JSON"}, 400, response_cors_headers)

        full_path_from_caller = data_payload["path"]
        force_processing = data_payload.get("force_processing", False)
        custom_data_prefix_override = data_payload.get("custom_prefix", None)

        if not isinstance(full_path_from_caller, str) or '/' not in full_path_from_caller:
             return ({"status": "error", "error": "Invalid 'path' format. Expected string 'bucket_name/path/to/file'"}, 400, response_cors_headers)

        bronze_bucket_name, *blob_parts = full_path_from_caller.split("/", 1)
        if not blob_parts or not blob_parts[0]:
            return ({"status": "error", "error": "Invalid path format. File path part is missing after bucket name."}, 400, response_cors_headers)

        object_path_from_caller_no_leading_slash = blob_parts[0].lstrip('/')
        blob_name_in_gcs = f"/{object_path_from_caller_no_leading_slash}" # Path GCS inizia con /

        print(f"Original path from caller: '{full_path_from_caller}'")
        print(f"Derived bronze_bucket_name: '{bronze_bucket_name}'")
        print(f"Blob name used for GCS operations: '{blob_name_in_gcs}'")

        file_name_original_ext = os.path.basename(blob_name_in_gcs)
        file_extension_original = os.path.splitext(file_name_original_ext)[1].lower().lstrip('.')

        bronze_bucket = storage_client.bucket(bronze_bucket_name)
        bronze_blob = bronze_bucket.blob(blob_name_in_gcs)

        print(f"Checking existence of bronze file: gs://{bronze_bucket_name}{blob_name_in_gcs}")
        if not bronze_blob.exists():
            return ({"status": "error", "error": f"File not found in bronze: gs://{bronze_bucket_name}{blob_name_in_gcs}"}, 404, response_cors_headers)
        print(f"Bronze file gs://{bronze_bucket_name}{blob_name_in_gcs} confirmed to exist.")

        bronze_blob.reload()
        original_blob_content_type = bronze_blob.content_type or "application/octet-stream"
        original_blob_size = bronze_blob.size

        # Creazione file temporaneo e download del contenuto
        with tempfile.NamedTemporaryFile(delete=False, suffix=f".{file_extension_original}") as tmp_in:
            tmp_in_path = tmp_in.name
            print(f"Downloading bronze file to temporary path: {tmp_in_path}")
            
        # Download del file da GCS al percorso temporaneo
        bronze_blob.download_to_filename(tmp_in_path)
        print(f"Downloaded bronze file: gs://{bronze_bucket_name}{blob_name_in_gcs} to {tmp_in_path}")
        
        # Verifica che il file temporaneo esista
        if not os.path.exists(tmp_in_path) or not os.path.getsize(tmp_in_path) > 0:
            error_msg = f"Failed to download file or file is empty: {tmp_in_path}"
            print(error_msg)
            return ({"status": "error", "error": error_msg}, 500, response_cors_headers)

        path_suffix_components = determine_silver_path_components(
            blob_name_in_gcs,
            file_extension_original,
            original_blob_content_type
        )
        path_suffix_str = "/".join(path_suffix_components)

        silver_data_files_base_path = f"{SILVER_DATA_FILES_ROOT_PREFIX}/{path_suffix_str}"
        silver_manifests_base_path = f"{SILVER_MANIFESTS_ROOT_PREFIX}/{path_suffix_str}"

        if custom_data_prefix_override:
            silver_data_files_base_path = custom_data_prefix_override.rstrip('/')
            print(f"Using custom data prefix: {silver_data_files_base_path}")


        # Dopo aver caricato il file dal bronze bucket e prima di elaborarlo,
        # determiniamo il nome della tabella BigQuery che verrà creata
        base_filename_no_ext = os.path.splitext(file_name_original_ext)[0]
        # Sanitize per BigQuery (solo lettere, numeri e underscore)
        safe_table_id = ''.join(c if c.isalnum() else '_' for c in base_filename_no_ext)
        if not safe_table_id[0].isalpha():
            safe_table_id = 'tbl_' + safe_table_id
            
        # Elaborazione del file in base al tipo
        df_processed = None
        if file_extension_original == "txt":
            with open(tmp_in_path, 'r', encoding='utf-8', errors='replace') as f_txt:
                df_processed = pd.DataFrame([{"extracted_text": f_txt.read(), "deep_processed_ok": True}]) # Boolean
        elif file_extension_original in ["csv", "tsv"]:
            delimiter = ',' if file_extension_original == "csv" else '\t'
            df_processed = pd.read_csv(tmp_in_path, delimiter=delimiter)
            df_processed["deep_processed_ok"] = True # Aggiungi per coerenza
        elif file_extension_original == "json":
            try:
                df_processed = pd.read_json(tmp_in_path, orient='records')
            except ValueError:
                try:
                    df_processed = pd.read_json(tmp_in_path, lines=True)
                except ValueError as e_json:
                    return ({"status":"error", "error": f"Failed to parse JSON: {e_json}"}, 400, response_cors_headers)
            df_processed["deep_processed_ok"] = True # Aggiungi per coerenza
        elif file_extension_original == "jsonl":
            df_processed = pd.read_json(tmp_in_path, lines=True)
            df_processed["deep_processed_ok"] = True # Aggiungi per coerenza
        elif file_extension_original == "parquet":
            df_processed = pd.read_parquet(tmp_in_path)
            df_processed["deep_processed_ok"] = True # Aggiungi per coerenza
        elif file_extension_original in ["xlsx", "xls"]:
            df_processed = pd.read_excel(tmp_in_path, engine=None) # read_excel può leggere più fogli, qui prendiamo il primo di default
            df_processed["deep_processed_ok"] = True # Aggiungi per coerenza
        elif file_extension_original == "pdf":
            df_processed = process_pdf(tmp_in_path) # process_pdf aggiunge già deep_processed_ok
        elif file_extension_original in ["jpg", "jpeg", "png", "gif", "tiff", "bmp", "webp", "svg"]:
            df_processed = process_image(tmp_in_path, file_extension_original) # process_image aggiunge già deep_processed_ok
        else:
            df_processed = pd.DataFrame([{
                "original_content_type": original_blob_content_type,
                "original_file_size_bytes": original_blob_size, # Int
                "original_file_name": file_name_original_ext,
                "deep_processed_ok": False, # Boolean
                "processing_note": f"Unsupported file type '{file_extension_original}' for deep processing."
            }])

        if not isinstance(df_processed, pd.DataFrame):
            return ({"status": "error", "error": "Internal error: Processing did not yield a DataFrame."}, 500, response_cors_headers)

        # Aggiungi metadati standard
        df_processed["silver_ingestion_ts"] = datetime.datetime.utcnow() # Datetime
        df_processed["bronze_source_uri"] = f"gs://{bronze_bucket_name}{blob_name_in_gcs}"
        if "original_file_extension" not in df_processed.columns:
             df_processed["original_file_extension"] = file_extension_original

        df_processed["silver_data_domain"] = path_suffix_components[0] if len(path_suffix_components) > 0 else "general"
        df_processed["silver_file_category"] = path_suffix_components[1] if len(path_suffix_components) > 1 else "unknown"

        # Assicurati che 'deep_processed_ok' esista e sia booleano
        if 'deep_processed_ok' not in df_processed.columns:
            df_processed['deep_processed_ok'] = False # Default a False se non impostato
        else:
            # Converti esplicitamente in bool, gestendo stringhe 'True'/'False' se necessario
            if df_processed['deep_processed_ok'].dtype == 'object':
                df_processed['deep_processed_ok'] = df_processed['deep_processed_ok'].astype(str).str.lower().map({'true': True, 'false': False}).fillna(False)
            df_processed['deep_processed_ok'] = df_processed['deep_processed_ok'].astype(bool)


        # Quando abbiamo ottenuto il DataFrame processato, separiamo i metadati dai dati
        if df_processed is not None and not df_processed.empty:
            # Identifica le colonne di metadati da spostare nel manifest
            metadata_columns = [
                "silver_ingestion_ts", "bronze_source_uri", "original_file_extension",
                "silver_data_domain", "silver_file_category", "deep_processed_ok"
                # Aggiungi qui altre colonne di metadati che non dovrebbero essere nel Parquet
            ]
            
            # Estrai i metadati prima di rimuoverli dal DataFrame
            metadata_values = {}
            for col in metadata_columns:
                if col in df_processed.columns:
                    # Prendi il primo valore non nullo, o None se tutti nulli o colonna non presente
                    values = df_processed[col].dropna()
                    if not values.empty:
                        metadata_value = values.iloc[0]
                        # Converti datetime in formato ISO per JSON
                        if isinstance(metadata_value, pd.Timestamp):
                            metadata_value = metadata_value.isoformat()
                        metadata_values[col] = metadata_value
            
            # Crea una copia del DataFrame per il manifest che include solo i metadati
            df_metadata = pd.DataFrame([metadata_values])
            
            # Rimuovi le colonne di metadati dal DataFrame da salvare come Parquet
            metadata_cols_to_remove = [col for col in metadata_columns if col in df_processed.columns]
            df_data_only = df_processed.drop(columns=metadata_cols_to_remove, errors='ignore')
            
            # Gestione delle colonne problematiche prima di salvare in Parquet
            # Elenco delle colonne che potrebbero contenere tipi misti
            potential_mixed_type_columns = ["year_founded", "established_date", "registration_id", "reference_code"]
            
            for col in df_data_only.columns:
                # Gestione specifica per colonne con potenziali tipi misti
                if col in potential_mixed_type_columns or df_data_only[col].dtype == 'object':
                    # Per colonne di tipo object, controlliamo se ci sono tipi misti
                    try:
                        # Se la colonna contiene tutti valori numerici, converte in float
                        df_data_only[col] = pd.to_numeric(df_data_only[col], errors='coerce')
                        # Se ci sono valori NaN dopo conversione (originariamente non numerici), converte tutta la colonna in string
                        if df_data_only[col].isna().any():
                            # Salva lo stato originale della colonna per non perdere valori non numerici
                            original_values = df_processed[col].copy()
                            # Ripristina i valori originali e converte tutto in stringa
                            df_data_only[col] = original_values.astype(str)
                    except Exception as e_col:
                        print(f"Conversione della colonna '{col}' a formato omogeneo fallita: {e_col}. Conversione in stringa.")
                        # In caso di errore, converti in stringa
                        df_data_only[col] = df_data_only[col].astype(str)
            
            # Sostituisci tutti i valori nan/None con stringhe vuote per le colonne di tipo object
            for col in df_data_only.select_dtypes(include=['object']):
                df_data_only[col] = df_data_only[col].fillna('')
            
            print(f"Tipi di dati nel DataFrame prima del salvataggio Parquet: {df_data_only.dtypes}")
            
            # Salva il file Parquet (solo dati, no metadati)
            with tempfile.NamedTemporaryFile(delete=False, suffix=".parquet") as tmp_out:
                tmp_out_path = tmp_out.name
            
            # Uso di una gestione degli errori per il salvataggio
            try:
                df_data_only.to_parquet(tmp_out_path, index=False, engine='pyarrow')
            except Exception as e_parquet:
                print(f"Errore nel salvataggio Parquet, tentativo con conversione estrema: {e_parquet}")
                # Ultima risorsa: converti tutte le colonne in stringa
                for col in df_data_only.columns:
                    if df_data_only[col].dtype != 'int64' and df_data_only[col].dtype != 'float64' and df_data_only[col].dtype != 'bool':
                        df_data_only[col] = df_data_only[col].astype(str)
                df_data_only.to_parquet(tmp_out_path, index=False, engine='pyarrow')
            
            silver_parquet_filename = f"{base_filename_no_ext}.parquet"
            silver_parquet_full_gcs_path = f"{silver_data_files_base_path}/{silver_parquet_filename}"
            silver_manifest_full_gcs_path = f"{silver_manifests_base_path}/_partition_manifest.json"
            
            # Carica il file Parquet su GCS
            silver_blob_data_upload = storage_client.bucket(SILVER_BUCKET_NAME).blob(silver_parquet_full_gcs_path)
            silver_blob_data_upload.upload_from_filename(tmp_out_path)
            print(f"Uploaded Parquet to gs://{SILVER_BUCKET_NAME}/{silver_parquet_full_gcs_path}")
            
            # Aggiorna il manifest con i metadati
            manifest_blob = storage_client.bucket(SILVER_BUCKET_NAME).blob(silver_manifest_full_gcs_path)
            current_manifest_entries = []
            if manifest_blob.exists():
                try:
                    manifest_content = manifest_blob.download_as_text()
                    loaded_manifest = json.loads(manifest_content)
                    if isinstance(loaded_manifest, list):
                        current_manifest_entries = loaded_manifest
                    else:
                        print(f"Warning: Manifest {silver_manifest_full_gcs_path} was not a list. Reinitializing.")
                except Exception as e_m_load:
                    print(f"Warning: Could not load/parse manifest {silver_manifest_full_gcs_path}: {e_m_load}. Reinitializing.")
            
            uri_parquet_in_silver = f"gs://{SILVER_BUCKET_NAME}/{silver_parquet_full_gcs_path}"
            current_manifest_entries = [e for e in current_manifest_entries if e.get("silver_file_uri") != uri_parquet_in_silver]
            
            # Converti i tipi NumPy prima della serializzazione JSON
            def json_serializable(obj):
                """Converti tipi NumPy e altri non serializzabili in tipi Python standard"""
                if hasattr(obj, 'item'):  # NumPy scalars hanno il metodo item()
                    return obj.item()  # Converte np.bool_, np.int64, ecc. in tipi Python equivalenti
                elif isinstance(obj, (pd.Series, pd.DataFrame)):
                    return obj.to_dict()
                elif isinstance(obj, pd.Timestamp):
                    return obj.isoformat()
                elif hasattr(obj, 'tolist'):  # Per array NumPy
                    return obj.tolist()
                return obj
            
            # Schema DataFrame con conversione valori NumPy
            safe_schema = {}
            for col, dtype in df_data_only.dtypes.items():
                safe_schema[col] = str(dtype)
            
            # Aggiungi tutti i metadati nel manifest
            manifest_entry = {
                "silver_file_uri": uri_parquet_in_silver,
                "bronze_source_uri": f"gs://{bronze_bucket_name}{blob_name_in_gcs}",
                "record_count": int(len(df_data_only)),  # Conversione esplicita per sicurezza
                "silver_processed_at": datetime.datetime.utcnow().isoformat() + "Z",
                "original_content_type": original_blob_content_type,
                "original_file_size_bytes": int(original_blob_size),  # Conversione esplicita
                "silver_df_schema": safe_schema,
                "silver_data_path_base": silver_data_files_base_path,
                "metadata": json.loads(json.dumps(metadata_values, default=json_serializable))  # Conversione sicura
            }
            
            current_manifest_entries.append(manifest_entry)
            manifest_json = json.dumps(current_manifest_entries, default=json_serializable, indent=2)
            manifest_blob.upload_from_string(manifest_json, content_type="application/json")
            print(f"Manifest updated at gs://{SILVER_BUCKET_NAME}/{silver_manifest_full_gcs_path}")

            # --- AVVIO SCANSIONE DATAPLEX ---
            dataplex_success = False
            dataplex_info = "Scansione Dataplex non eseguita"
            
            # Identifica il project_id corrente
            project_id = os.environ.get("GCP_PROJECT") or os.environ.get("GOOGLE_CLOUD_PROJECT")
            if not project_id:
                print("ATTENZIONE: Impossibile determinare il project_id dagli env vars.")
                project_id = "soy-transducer-456512-t0"  # Fallback project ID, da personalizzare
            
            try:
                # Avvia la scansione Dataplex per aggiornare automaticamente il catalogo
                dataplex_success, dataplex_info = trigger_dataplex_discovery(
                    project_id=project_id
                )
                
                if dataplex_success:
                    print(f"Scansione Dataplex avviata con successo. Dataplex aggiornerà automaticamente le tabelle BigQuery.")
                else:
                    print(f"Avviso: Scansione Dataplex non riuscita: {dataplex_info}")
            
            except Exception as e_dataplex:
                dataplex_success = False
                dataplex_info = f"Errore durante la scansione Dataplex: {str(e_dataplex)}"
                traceback.print_exc()
            
            # Prepara le colonne per la risposta
            processed_columns_with_types = []
            for col_name, dtype in df_data_only.dtypes.items():
                dtype_str = str(dtype)
                simple_type = "STRING"  # Fallback generico
                if "bool" in dtype_str:
                    simple_type = "BOOLEAN"
                elif "int" in dtype_str:
                    simple_type = "INT64"
                elif "float" in dtype_str:
                    simple_type = "FLOAT64"
                elif "datetime" in dtype_str or "timestamp" in dtype_str:
                    simple_type = "TIMESTAMP"
                elif "object" in dtype_str:
                    simple_type = "STRING"
                processed_columns_with_types.append({"name": col_name, "type": simple_type})
            
            # Calcola il nome della tabella BigQuery che Dataplex creerà, basato sul percorso delle cartelle
            # Modificato per non utilizzare più il formato di partizionamento Hive
            dataplex_table_name_parts = []
            
            # Aggiungi il prefisso root (silver_data_files)
            dataplex_table_name_parts.append(SILVER_DATA_FILES_ROOT_PREFIX)
            
            # Aggiungi i componenti del percorso
            dataplex_table_name_parts.extend(path_suffix_components)
            
            # Unisci i componenti con underscore per ottenere il nome della tabella
            dataplex_table_id = "_".join(dataplex_table_name_parts)
            
            # Sanitizzazione aggiuntiva per assicurarsi che sia un nome tabella BigQuery valido
            dataplex_table_id = ''.join(c if c.isalnum() or c == '_' else '_' for c in dataplex_table_id)
            if not dataplex_table_id[0].isalpha() and dataplex_table_id[0] != '_':
                dataplex_table_id = 'tbl_' + dataplex_table_id
            
            # Il nome completo della tabella BigQuery che Dataplex creerà
            expected_bq_table_ref = f"{project_id}.silver_zone.{dataplex_table_id}"
            
            # Debug log
            print(f"Tabella BigQuery prevista che Dataplex creerà: {expected_bq_table_ref}")
            print(f"   - Componenti del percorso: {path_suffix_components}")
            print(f"   - Parti del nome tabella: {dataplex_table_name_parts}")
            
            # Aggiungiamo una colonna di data al DataFrame per poter filtrare in modo standard in BigQuery
            if 'date_partition' not in df_data_only.columns:
                # Aggiungi una colonna di data in formato stringa YYYY/MM/DD
                current_date = datetime.datetime.utcnow().strftime("%Y/%m/%d")
                df_data_only['date_partition'] = current_date

            # Risposta aggiornata con informazioni su Dataplex
            response_data = {
                "status": "success",
                "message": f"Processed gs://{bronze_bucket_name}{blob_name_in_gcs} to Silver: {uri_parquet_in_silver}. Dataplex discovery triggered.",
                "silver_path": f"gs://{SILVER_BUCKET_NAME}/{silver_parquet_full_gcs_path}",
                "columns": processed_columns_with_types,
                "record_count": len(df_data_only),
                "silver_path_prefix_base": silver_data_files_base_path,
                "bigquery_table": expected_bq_table_ref,  # Rinominato da expected_bigquery_table a bigquery_table
                "dataplex_status": "success" if dataplex_success else "error",
                "dataplex_info": dataplex_info,
                "note": "BigQuery table will be created automatically by Dataplex discovery process"
            }
            return (response_data, 200, response_cors_headers)
        
        else:
            # Gestione del caso in cui il DataFrame è None o vuoto
            return ({"status": "error", "error": "Elaborazione del file non riuscita o ha prodotto un set di dati vuoto."}, 400, response_cors_headers)

    except Exception as e:
        error_msg = str(e)
        print(f"Unhandled error in bronze_to_silver for input path '{data_payload.get('path', 'N/A')}': {error_msg}")
        traceback.print_exc()
        return ({"status": "error", "error": error_msg, "details": traceback.format_exc()}, 500, response_cors_headers)

    finally:
        for temp_p in [tmp_in_path, tmp_out_path]:
            if temp_p and os.path.exists(temp_p):
                try: os.unlink(temp_p); print(f"Cleaned up temp file: {temp_p}")
                except Exception as e_unlink: print(f"Error unlinking temp file {temp_p}: {e_unlink}")