import os
import tempfile
import datetime
import json
import pandas as pd
# numpy non è usato direttamente, pandas lo usa sotto. Puoi ometterlo se non lo usi tu.
# import numpy as np 
from google.cloud import storage # documentai e language non sono usati qui
from flask import Request # Già disponibile tramite functions_framework
import functions_framework
import io # io.BytesIO è usato
import PyPDF2
from io import StringIO, BytesIO # StringIO non è usata
from PIL import Image
import base64
import traceback # Per un logging degli errori più dettagliato

# Configurazione Globale
SILVER_BUCKET = "soy-transducer-456512-t0-easyquery-silver" # Assicurati che questo sia il nome corretto
storage_client = storage.Client()

# --- FUNZIONI HELPER ---
def determine_silver_path(file_path, file_extension, content_type=None, metadata=None):
    """
    Determina un percorso gerarchico significativo per il file Silver basato sui metadati.
    """
    path_parts = file_path.split('/')
    # original_filename = path_parts[-1] # Non usato direttamente qui

    data_domain = "general"
    domain_patterns = {
        "finance": ["finance", "financial", "accounting", "invoice", "payment", "transaction"],
        "sales": ["sales", "revenue", "customer", "order", "product"],
        "marketing": ["marketing", "campaign", "advertisement", "promotion"],
        "hr": ["hr", "human-resources", "employee", "personnel", "recruitment"],
        "operations": ["operations", "logistics", "inventory", "supply-chain"],
        "it": ["it", "technology", "system", "software", "hardware", "tech"] # Aggiunto "tech"
    }
    
    lower_path = file_path.lower()
    for domain, patterns in domain_patterns.items():
        if any(pattern in lower_path for pattern in patterns):
            data_domain = domain
            break
    
    file_category = "unknown"
    if file_extension in ["csv", "parquet", "json", "jsonl"]:
        file_category = "structured"
    elif file_extension in ["pdf", "txt", "doc", "docx", "md"]:
        file_category = "document"
    elif file_extension in ["jpg", "jpeg", "png", "gif", "tiff", "bmp", "svg", "webp"]:
        file_category = "image"
    elif file_extension in ["xls", "xlsx", "ods"]:
        file_category = "spreadsheet"
    
    content_context = ""
    if content_type:
        ct_lower = content_type.lower()
        if "application/json" in ct_lower:
            content_context = "json-data"
        elif "text/csv" in ct_lower:
            content_context = "csv-data"
        elif "application/pdf" in ct_lower:
            content_context = "pdf-document"
        elif "image/" in ct_lower:
            content_context = content_type.split('/')[-1].replace('jpeg', 'jpg') + "-image" # es. png-image
        elif "text/plain" in ct_lower:
            content_context = "text-file"

    date_partition = datetime.datetime.utcnow().strftime("%Y/%m/%d")
    
    hierarchy = [
        "silver", # Livello principale
        data_domain,
        file_category,
        content_context if content_context else "generic-data",
        f"date_partition={date_partition}" # Hive-style partitioning
    ]
    
    hierarchy = [part for part in hierarchy if part] 
    return "/".join(hierarchy)

def process_pdf(tmp_filename):
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
                if page_text:
                    text_content += page_text + "\n"
        
        return pd.DataFrame([{
            "content_type_processed": "application/pdf", # Evita conflitto con colonna content_type originale
            "text_content": text_content,
            "page_count": page_count,
            "processed_ok": True # Evita conflitto con 'processed'
        }])
    except Exception as e:
        print(f"Errore durante l'elaborazione del PDF '{tmp_filename}': {e}")
        traceback.print_exc()
        return pd.DataFrame([{"error_processing_pdf": str(e), "processed_ok": False}])

def process_image(tmp_filename, file_ext_original):
    """Elabora un'immagine estraendo metadati di base e immagine in base64."""
    try:
        img = Image.open(tmp_filename)
        metadata = {
            "width": img.width,
            "height": img.height,
            "format": img.format, # Formato originale dell'immagine come letto da Pillow
            "mode": img.mode,
        }
        
        buffered = BytesIO()
        # Salva in un formato web-friendly comune per base64 se il formato originale non è standard
        # o per coerenza. PNG è lossless e ben supportato.
        save_format = img.format if img.format and img.format.upper() in ['PNG', 'JPEG', 'GIF'] else 'PNG'
        img.save(buffered, format=save_format)
        img_str_b64 = base64.b64encode(buffered.getvalue()).decode('utf-8')
        
        return pd.DataFrame([{
            "content_type_processed": f"image/{save_format.lower()}", # Tipo dell'immagine salvata
            "image_width": metadata["width"],
            "image_height": metadata["height"],
            "image_format_original": metadata["format"], # Formato del file originale
            "image_mode": metadata["mode"],
            "image_data_b64": img_str_b64,
            "processed_ok": True
        }])
    except Exception as e:
        print(f"Errore durante l'elaborazione dell'immagine '{tmp_filename}': {e}")
        traceback.print_exc()
        return pd.DataFrame([{"error_processing_image": str(e), "processed_ok": False}])

# --- FUNZIONE PRINCIPALE CLOUD FUNCTION ---
@functions_framework.http
def bronze_to_silver(request: Request):
    """
    Funzione HTTP per convertire file dal bucket bronze al bucket silver.
    """
    # Gestione della richiesta preflight CORS (OPTIONS)
    if request.method == 'OPTIONS':
        headers = {
            'Access-Control-Allow-Origin': '*',  # Sii più specifico in produzione! Es: 'https://tuo-dominio-app.com'
            'Access-Control-Allow-Methods': 'POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type',
            'Access-Control-Max-Age': '3600'
        }
        return ('', 204, headers)

    # Header CORS per le risposte effettive
    response_cors_headers = {
        'Access-Control-Allow-Origin': '*' # Sii più specifico in produzione!
    }

    tmp_in_path = None
    tmp_out_path = None

    try:
        if not request.is_json:
            return ({"status": "error", "error": "Invalid content type, expected application/json"}, 415, response_cors_headers)

        data = request.get_json(silent=True)
        if data is None:
             return ({"status": "error", "error": "Malformed JSON or empty request body"}, 400, response_cors_headers)

        if "path" not in data:
            return ({"status": "error", "error": "Missing 'path' in request JSON"}, 400, response_cors_headers)

        full_path = data["path"]
        force_processing = data.get("force_processing", False)
        custom_prefix = data.get("custom_prefix", None)
        
        if not isinstance(full_path, str) or '/' not in full_path:
             return ({"status": "error", "error": "Invalid 'path' format. Expected string 'bucket_name/path/to/file'"}, 400, response_cors_headers)

        bucket_name, *blob_parts = full_path.split("/", 1)
        if not blob_parts or not blob_parts[0]: # blob_parts[0] è blob_name
            return ({"status": "error", "error": "Invalid path format. File path part is missing after bucket name."}, 400, response_cors_headers)
        blob_name = blob_parts[0]
        
        file_name_original = os.path.basename(blob_name)
        file_extension_original = os.path.splitext(file_name_original)[1].lower().lstrip('.')
        
        bronze_bucket_obj = storage_client.bucket(bucket_name)
        bronze_blob = bronze_bucket_obj.blob(blob_name)

        if not bronze_blob.exists():
            return ({"status": "error", "error": f"File not found in bronze: gs://{bucket_name}/{blob_name}"}, 404, response_cors_headers)

        # Ricarica i metadati del blob per avere content_type e size aggiornati
        bronze_blob.reload() 
        blob_content_type = bronze_blob.content_type or "application/octet-stream"
        blob_size = bronze_blob.size

        if custom_prefix is None:
            silver_prefix_base = determine_silver_path(
                file_path=blob_name, # Usa blob_name che è il path relativo al bucket
                file_extension=file_extension_original,
                content_type=blob_content_type
            )
        else:
            silver_prefix_base = custom_prefix
        
        base_filename_no_ext = os.path.splitext(file_name_original)[0]
        # Il nome del file in Silver sarà sempre .parquet
        silver_file_name = f"{base_filename_no_ext}.parquet"
        silver_full_path = f"{silver_prefix_base}/{silver_file_name}"

        if not force_processing:
            silver_blob_check = storage_client.bucket(SILVER_BUCKET).blob(silver_full_path)
            if silver_blob_check.exists():
                return ({"status": "success", 
                         "message": f"File already processed and exists at: gs://{SILVER_BUCKET}/{silver_full_path}", 
                         "silver_path": f"gs://{SILVER_BUCKET}/{silver_full_path}"}, 
                        200, response_cors_headers)

        # Scarica oggetto bronze in un file temporaneo con nome
        with tempfile.NamedTemporaryFile(delete=False, suffix=f".{file_extension_original}" if file_extension_original else "") as tmp_in:
            tmp_in_path = tmp_in.name
        bronze_blob.download_to_filename(tmp_in_path)
        print(f"Downloaded gs://{bucket_name}/{blob_name} to {tmp_in_path}")
        
        # Elabora in base al tipo di file
        processing_df = None
        if file_extension_original in ["csv", "tsv"]:
            delimiter = ',' if file_extension_original == "csv" else '\t'
            processing_df = pd.read_csv(tmp_in_path, delimiter=delimiter)
        elif file_extension_original == "json": # JSON array di oggetti
            try:
                processing_df = pd.read_json(tmp_in_path, orient='records')
            except ValueError: # Prova come JSONL se fallisce
                 try:
                    processing_df = pd.read_json(tmp_in_path, lines=True)
                 except ValueError as e_json:
                    return ({"status":"error", "error": f"Failed to parse JSON: {e_json}"}, 400, response_cors_headers)
        elif file_extension_original == "jsonl": # JSON Lines
             processing_df = pd.read_json(tmp_in_path, lines=True)
        elif file_extension_original == "parquet":
            processing_df = pd.read_parquet(tmp_in_path)
        elif file_extension_original == "xlsx" or file_extension_original == "xls":
            processing_df = pd.read_excel(tmp_in_path, engine=None) # Lascia che pandas scelga l'engine
        elif file_extension_original == "pdf":
            processing_df = process_pdf(tmp_in_path)
        elif file_extension_original in ["jpg", "jpeg", "png", "gif", "tiff", "bmp", "webp", "svg"]:
            processing_df = process_image(tmp_in_path, file_extension_original)
        else:
            # Per tipi non supportati, crea DataFrame con metadati di base del file originale
            # e un flag per indicare che non è stato processato in dettaglio
            processing_df = pd.DataFrame([{
                "original_content_type": blob_content_type,
                "original_file_size_bytes": blob_size,
                "original_file_name": file_name_original,
                "deep_processed": False, # Flag per indicare che non c'è stata elaborazione profonda
                "processing_note": "Unsupported file type for deep processing, basic metadata stored."
            }])
        
        # Verifica che processing_df sia un DataFrame
        if not isinstance(processing_df, pd.DataFrame):
            return ({"status": "error", "error": "Processing did not return a DataFrame."}, 500, response_cors_headers)

        # Aggiungi metadati standard al DataFrame risultante
        processing_df["silver_ingestion_ts"] = datetime.datetime.utcnow()
        processing_df["bronze_source_file_uri"] = f"gs://{bucket_name}/{blob_name}"
        # file_extension_original è già una colonna se il file non è stato processato in profondità
        if "original_file_extension" not in processing_df.columns:
             processing_df["original_file_extension"] = file_extension_original
        
        # Estrae data_domain e file_category dal silver_prefix_base
        # silver_prefix_base = "silver/data_domain/file_category/content_context/date_partition=YYYY/MM/DD"
        prefix_parts = silver_prefix_base.split('/')
        processing_df["silver_data_domain"] = prefix_parts[1] if len(prefix_parts) > 1 else "general"
        processing_df["silver_file_category"] = prefix_parts[2] if len(prefix_parts) > 2 else "unknown"


        # Scrivi Parquet nel bucket silver usando il percorso gerarchico
        with tempfile.NamedTemporaryFile(delete=False, suffix=".parquet") as tmp_out:
            tmp_out_path = tmp_out.name
        processing_df.to_parquet(tmp_out_path, index=False, engine='pyarrow') # Specifica engine
        print(f"DataFrame converted to Parquet at {tmp_out_path}")

        silver_blob_upload = storage_client.bucket(SILVER_BUCKET).blob(silver_full_path)
        silver_blob_upload.upload_from_filename(tmp_out_path)
        print(f"Uploaded Parquet to gs://{SILVER_BUCKET}/{silver_full_path}")

        # Aggiorna manifest nelle relative cartelle gerarchiche
        # Il manifest è al livello del content_context, un livello sopra date_partition
        manifest_directory_path = "/".join(silver_prefix_base.split('/')[:-1]) 
        manifest_full_path = f"{manifest_directory_path}/_manifest.json"
        
        meta_blob = storage_client.bucket(SILVER_BUCKET).blob(manifest_full_path)
        manifest_data = []
        if meta_blob.exists():
            try:
                manifest_content = meta_blob.download_as_text()
                manifest_data = json.loads(manifest_content)
                if not isinstance(manifest_data, list): # Se il manifest è corrotto, inizia da capo
                    manifest_data = []
            except json.JSONDecodeError:
                print(f"Warning: Manifest file at {manifest_full_path} is corrupted. Starting new manifest.")
                manifest_data = []
            except Exception as e_manifest_download:
                print(f"Warning: Could not download or parse manifest at {manifest_full_path}: {e_manifest_download}. Starting new manifest.")
                manifest_data = []
        
        # Rimuovi vecchia entry se esiste per lo stesso silver_full_path (per rielaborazioni)
        manifest_data = [entry for entry in manifest_data if entry.get("silver_file_uri") != f"gs://{SILVER_BUCKET}/{silver_full_path}"]

        manifest_data.append({
            "silver_file_uri": f"gs://{SILVER_BUCKET}/{silver_full_path}", 
            "bronze_source_uri": f"gs://{bucket_name}/{blob_name}",
            "record_count": len(processing_df),
            "silver_processed_at": datetime.datetime.utcnow().isoformat() + "Z",
            "original_content_type": blob_content_type,
            "original_file_size_bytes": blob_size,
            "silver_df_schema": {col: str(dtype) for col, dtype in processing_df.dtypes.items()},
            "silver_path_prefix_base": silver_prefix_base # Il path senza il nome file
        })
        
        meta_blob.upload_from_string(json.dumps(manifest_data, indent=2), content_type="application/json")
        print(f"Manifest updated at gs://{SILVER_BUCKET}/{manifest_full_path}")

        # Opzionalmente, cancella l'oggetto originale dal bucket bronze
        delete_message = f"Original file gs://{bucket_name}/{blob_name} kept in bronze."
        if data.get("delete_original", False) is True: # Controllo esplicito per True
            bronze_blob.delete()
            delete_message = f"Original file gs://{bucket_name}/{blob_name} deleted from bronze."
            print(delete_message)

        response_payload = {
            "status": "success",
            "message": f"Processed gs://{bucket_name}/{blob_name} and loaded to silver: gs://{SILVER_BUCKET}/{silver_full_path}. {delete_message}",
            "silver_file_uri": f"gs://{SILVER_BUCKET}/{silver_full_path}",
            "record_count": len(processing_df),
            "silver_df_columns": list(processing_df.columns),
            "silver_path_prefix_base": silver_prefix_base
        }
        return (response_payload, 200, response_cors_headers)

    except Exception as e:
        error_message = str(e)
        print(f"Unhandled error in bronze_to_silver for input path '{data.get('path', 'N/A')}': {error_message}")
        traceback.print_exc() 
        return ({"status": "error", "error": error_message, "details": traceback.format_exc()}, 500, response_cors_headers)
    
    finally:
        # Pulizia file temporanei in modo sicuro
        for temp_path in [tmp_in_path, tmp_out_path]:
            if temp_path and os.path.exists(temp_path):
                try:
                    os.unlink(temp_path)
                    print(f"Successfully unlinked temporary file: {temp_path}")
                except Exception as e_unlink:
                    print(f"Error unlinking temporary file {temp_path}: {e_unlink}")