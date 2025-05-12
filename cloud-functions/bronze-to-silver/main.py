import os
import tempfile
import datetime
import json
import pandas as pd
from google.cloud import storage
import functions_framework
from flask import Request # Per il type hint di request
import io # Per BytesIO
import PyPDF2 # Per i PDF
from PIL import Image # Per le immagini
import base64 # Per la codifica base64 delle immagini
import traceback # Per un logging degli errori più dettagliato
from typing import List, Dict, Any, Optional

# --- CONFIGURAZIONE GLOBALE ---
# Bucket GCS dove risiedono i dati Silver. 
# Non confondere con i prefissi radice per dati e manifest al suo interno.
SILVER_BUCKET_NAME = "silver-layer-bucket" 

# Prefissi radice all'interno del SILVER_BUCKET_NAME per separare file di dati e manifest
SILVER_DATA_FILES_ROOT_PREFIX = "silver_data_files"  # Es: gs://silver-layer-bucket/silver_data_files/...
SILVER_MANIFESTS_ROOT_PREFIX = "silver_manifests" # Es: gs://silver-layer-bucket/silver_manifests/...

storage_client = storage.Client()

# --- FUNZIONI HELPER ---
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

    date_partition_str = datetime.datetime.utcnow().strftime("%Y/%m/%d") # YYYY/MM/DD
    
    path_components = [
        data_domain,
        file_category,
        content_context,
        f"date_partition={date_partition_str}" # Stile partizione Hive
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
            "deep_processed_ok": True
        }])
    except Exception as e:
        print(f"Error processing PDF '{tmp_filename}': {e}")
        traceback.print_exc()
        return pd.DataFrame([{"error_processing_pdf": str(e), "deep_processed_ok": False}])

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
            "image_width": img_metadata["width"],
            "image_height": img_metadata["height"],
            "image_format_original": img_metadata["format_original"],
            "image_mode": img_metadata["mode"],
            "image_data_b64": img_str_b64, # Stringa Base64
            "deep_processed_ok": True
        }])
    except Exception as e:
        print(f"Error processing image '{tmp_filename}': {e}")
        traceback.print_exc()
        return pd.DataFrame([{"error_processing_image": str(e), "deep_processed_ok": False}])

# --- FUNZIONE PRINCIPALE CLOUD FUNCTION ---
@functions_framework.http
def bronze_to_silver(request: Request):
    """
    Funzione HTTP per convertire file dal bucket bronze al bucket silver.
    Salva i dati Parquet in una struttura di cartelle e i manifest JSON in una struttura parallela.
    """
    # Gestione della richiesta preflight CORS (OPTIONS)
    if request.method == 'OPTIONS':
        headers = {
            'Access-Control-Allow-Origin': '*', 
            'Access-Control-Allow-Methods': 'POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type, Authorization', # Aggiungi Authorization se usi token
            'Access-Control-Max-Age': '3600'
        }
        return ('', 204, headers)

    response_cors_headers = {'Access-Control-Allow-Origin': '*'}
    tmp_in_path, tmp_out_path = None, None
    data_payload = {} # Per avere 'path' disponibile nel blocco finally

    try:
        print(f"bronze-to-silver: Request received. Method: {request.method}")
        # print(f"Headers: {request.headers}") # Logga gli header solo se necessario per debug CORS approfondito

        if not request.is_json:
            return ({"status": "error", "error": "Invalid content type, expected application/json"}, 415, response_cors_headers)
        
        data_payload = request.get_json(silent=True)
        if data_payload is None: 
             return ({"status": "error", "error": "Malformed JSON or empty request body"}, 400, response_cors_headers)
        if "path" not in data_payload: 
            return ({"status": "error", "error": "Missing 'path' in request JSON"}, 400, response_cors_headers)

        full_path_from_caller = data_payload["path"]
        force_processing = data_payload.get("force_processing", False)
        custom_data_prefix_override = data_payload.get("custom_prefix", None) # Rinominato per chiarezza
        
        if not isinstance(full_path_from_caller, str) or '/' not in full_path_from_caller:
             return ({"status": "error", "error": "Invalid 'path' format. Expected string 'bucket_name/path/to/file'"}, 400, response_cors_headers)

        bronze_bucket_name, *blob_parts = full_path_from_caller.split("/", 1)
        if not blob_parts or not blob_parts[0]:
            return ({"status": "error", "error": "Invalid path format. File path part is missing after bucket name."}, 400, response_cors_headers)
        
        # Questo è il path dell'oggetto come inviato da Dart (es. "data/raw/ditto/file.txt")
        object_path_from_caller_no_leading_slash = blob_parts[0].lstrip('/')
        
        # Ricostruisci il nome del blob come è in GCS (con lo / iniziale)
        blob_name_in_gcs = f"/{object_path_from_caller_no_leading_slash}"

        print(f"Original path from caller: '{full_path_from_caller}'")
        print(f"Derived bronze_bucket_name: '{bronze_bucket_name}'")
        print(f"Blob name used for GCS operations: '{blob_name_in_gcs}'")

        file_name_original_ext = os.path.basename(blob_name_in_gcs) # Es: "file.txt"
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

        # Determina i suffissi di path basati sui metadati
        path_suffix_components = determine_silver_path_components(
            blob_name_in_gcs, # Passa il nome del blob (con / iniziale) per l'analisi del dominio
            file_extension_original, 
            original_blob_content_type
        )
        path_suffix_str = "/".join(path_suffix_components)

        # Costruisci i path base per dati e manifest
        silver_data_files_base_path = f"{SILVER_DATA_FILES_ROOT_PREFIX}/{path_suffix_str}"
        silver_manifests_base_path = f"{SILVER_MANIFESTS_ROOT_PREFIX}/{path_suffix_str}"
        
        # Override del path dei dati se custom_prefix è fornito
        if custom_data_prefix_override:
            silver_data_files_base_path = custom_data_prefix_override.rstrip('/')
            # Se custom_prefix è usato, il manifest potrebbe andare in una posizione standard o derivata
            # Per ora, manteniamo la logica del manifest basata sui path component derivati,
            # a meno che non si voglia una logica più complessa per custom_prefix e manifest.
            print(f"Using custom data prefix: {silver_data_files_base_path}")


        base_filename_no_ext = os.path.splitext(file_name_original_ext)[0]
        silver_parquet_filename = f"{base_filename_no_ext}.parquet"
        
        silver_parquet_full_gcs_path = f"{silver_data_files_base_path}/{silver_parquet_filename}"
        silver_manifest_full_gcs_path = f"{silver_manifests_base_path}/_partition_manifest.json"

        if not force_processing:
            silver_blob_check = storage_client.bucket(SILVER_BUCKET_NAME).blob(silver_parquet_full_gcs_path)
            if silver_blob_check.exists():
                print(f"File {silver_parquet_full_gcs_path} already processed. Attempting to read its schema.")
                cols_from_existing = []
                try:
                    # Per leggere da GCS direttamente con Pandas, potresti aver bisogno di gcsfs
                    # Assicurati che 'gcsfs' sia nel tuo requirements.txt
                    # Oppure scarica temporaneamente come hai fatto prima
                    with tempfile.NamedTemporaryFile(delete=False, suffix=".parquet") as tmp_exist:
                        silver_blob_check.download_to_filename(tmp_exist.name)
                        # Leggi solo lo schema non caricando tutti i dati usando columns=[] o nrows=0
                        # Tuttavia, per ottenere i nomi delle colonne, basta pd.read_parquet(path).columns
                        parquet_file = pd.read_parquet(tmp_exist.name) # Carica una piccola parte o solo metadati se possibile
                        cols_from_existing = parquet_file.columns.tolist()
                        os.unlink(tmp_exist.name)
                    print(f"Schema read from existing Parquet: {cols_from_existing}")
                except Exception as e_schema:
                    print(f"Warning: Could not read schema from existing Parquet gs://{SILVER_BUCKET_NAME}/{silver_parquet_full_gcs_path}: {e_schema}")
                
                return ({"status": "success", 
                        "message": f"File already processed: gs://{SILVER_BUCKET_NAME}/{silver_parquet_full_gcs_path}", 
                        "silver_path": f"gs://{SILVER_BUCKET_NAME}/{silver_parquet_full_gcs_path}",
                        "columns": cols_from_existing, # Restituisci le colonne
                        "silver_path_prefix_base": silver_data_files_base_path 
                        }, 200, response_cors_headers)

        with tempfile.NamedTemporaryFile(delete=False, suffix=f".{file_extension_original}" if file_extension_original else "") as tmp_in:
            tmp_in_path = tmp_in.name
        bronze_blob.download_to_filename(tmp_in_path)
        print(f"Downloaded gs://{bronze_bucket_name}{blob_name_in_gcs} to {tmp_in_path}")
        
        df_processed = None # DataFrame risultante dal processamento
        # ... (TUTTA la tua logica if/elif per pd.read_csv, read_json, process_pdf, process_image, ecc. VA QUI) ...
        # Assicurati che assegni il risultato a df_processed
        # Esempio per TXT (adatta con la tua logica completa):
        if file_extension_original == "txt":
            with open(tmp_in_path, 'r', encoding='utf-8', errors='replace') as f_txt:
                df_processed = pd.DataFrame([{"extracted_text": f_txt.read(), "deep_processed_ok": True}])
        elif file_extension_original in ["csv", "tsv"]:
            delimiter = ',' if file_extension_original == "csv" else '\t'
            df_processed = pd.read_csv(tmp_in_path, delimiter=delimiter)
        elif file_extension_original == "json":
            try: df_processed = pd.read_json(tmp_in_path, orient='records')
            except ValueError: 
                try: df_processed = pd.read_json(tmp_in_path, lines=True)
                except ValueError as e_json: return ({"status":"error", "error": f"Failed to parse JSON: {e_json}"}, 400, response_cors_headers)
        elif file_extension_original == "jsonl": df_processed = pd.read_json(tmp_in_path, lines=True)
        elif file_extension_original == "parquet": df_processed = pd.read_parquet(tmp_in_path)
        elif file_extension_original in ["xlsx", "xls"]: df_processed = pd.read_excel(tmp_in_path, engine=None)
        elif file_extension_original == "pdf": df_processed = process_pdf(tmp_in_path)
        elif file_extension_original in ["jpg", "jpeg", "png", "gif", "tiff", "bmp", "webp", "svg"]:
            df_processed = process_image(tmp_in_path, file_extension_original)
        else: # Fallback per tipi non supportati
            df_processed = pd.DataFrame([{
                "original_content_type": original_blob_content_type,
                "original_file_size_bytes": original_blob_size,
                "original_file_name": file_name_original_ext, # Nome file originale con estensione
                "deep_processed_ok": False,
                "processing_note": f"Unsupported file type '{file_extension_original}' for deep processing."
            }])

        if not isinstance(df_processed, pd.DataFrame):
            return ({"status": "error", "error": "Internal error: Processing did not yield a DataFrame."}, 500, response_cors_headers)

        # Aggiungi metadati standard
        df_processed["silver_ingestion_ts"] = datetime.datetime.utcnow()
        df_processed["bronze_source_uri"] = f"gs://{bronze_bucket_name}{blob_name_in_gcs}"
        if "original_file_extension" not in df_processed.columns: # Aggiungi se non già presente da un processamento specifico
             df_processed["original_file_extension"] = file_extension_original
        
        # Estrai data_domain e file_category dal path suffix (che non include la radice)
        df_processed["silver_data_domain"] = path_suffix_components[0] if len(path_suffix_components) > 0 else "general"
        df_processed["silver_file_category"] = path_suffix_components[1] if len(path_suffix_components) > 1 else "unknown"
        
        with tempfile.NamedTemporaryFile(delete=False, suffix=".parquet") as tmp_out:
            tmp_out_path = tmp_out.name
        df_processed.to_parquet(tmp_out_path, index=False, engine='pyarrow')
        
        silver_blob_data_upload = storage_client.bucket(SILVER_BUCKET_NAME).blob(silver_parquet_full_gcs_path)
        silver_blob_data_upload.upload_from_filename(tmp_out_path)
        print(f"Uploaded Parquet to gs://{SILVER_BUCKET_NAME}/{silver_parquet_full_gcs_path}")

        # Aggiorna manifest
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
        
        current_manifest_entries.append({
            "silver_file_uri": uri_parquet_in_silver, 
            "bronze_source_uri": f"gs://{bronze_bucket_name}{blob_name_in_gcs}",
            "record_count": len(df_processed),
            "silver_processed_at": datetime.datetime.utcnow().isoformat() + "Z",
            "original_content_type": original_blob_content_type,
            "original_file_size_bytes": original_blob_size,
            "silver_df_schema": {col: str(dtype) for col, dtype in df_processed.dtypes.items()},
            "silver_data_path_base": silver_data_files_base_path # Path della cartella dati per questa partizione
        })
        manifest_blob.upload_from_string(json.dumps(current_manifest_entries, indent=2), content_type="application/json")
        print(f"Manifest updated at gs://{SILVER_BUCKET_NAME}/{silver_manifest_full_gcs_path}")

        delete_msg = f"Original gs://{bronze_bucket_name}{blob_name_in_gcs} kept."
        if data_payload.get("delete_original", False) is True:
            bronze_blob.delete()
            delete_msg = f"Original gs://{bronze_bucket_name}{blob_name_in_gcs} deleted."
            print(delete_msg)

        response_data = {
            "status": "success",
            "message": f"Processed gs://{bronze_bucket_name}{blob_name_in_gcs} to Silver: {uri_parquet_in_silver}. {delete_msg}",
            "silver_path": uri_parquet_in_silver,
            "columns": list(df_processed.columns),
            "record_count": len(df_processed),
            "silver_path_prefix_base": silver_data_files_base_path
        }
        return (response_data, 200, response_cors_headers)

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