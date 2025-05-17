import os
import tempfile
import datetime
import json
import pandas as pd
from google.cloud import storage
from google.cloud import dataplex_v1
import functions_framework
from flask import Request, jsonify # Per il type hint di request,
import io # Per BytesIO
import PyPDF2 # Per i PDF
from PIL import Image # Per le immagini
import base64 # Per la codifica base64 delle immagini
import traceback # Per un logging degli errori più dettagliato
from typing import List, Dict, Any, Optional
import time
import uuid
import time # Già presente, ma non usato esplicitamente per l'attesa della scan
import re # Per estrarre l'entity_id dal messaggio di successo
from google.cloud import dataplex_v1
import google.api_core.exceptions
from google.protobuf import field_mask_pb2
# Aggiungiamo l'import di BigQuery
from google.cloud import bigquery



# --- CONFIGURAZIONE GLOBALE ---
# Bucket GCS dove risiedono i dati Silver.
# Non confondere con i prefissi radice per dati e manifest al suo interno.
SILVER_BUCKET_NAME = "silver-layer-bucket"

# Prefissi radice all'interno del SILVER_BUCKET_NAME per separare file di dati e manifest
SILVER_DATA_FILES_ROOT_PREFIX = "files"  # Es: gs://silver-layer-bucket/files/...
SILVER_MANIFESTS_ROOT_PREFIX = "manifests" # Es: gs://silver-layer-bucket/manifests/...

# Configurazione Dataplex
DATAPLEX_LOCATION = "europe-central2"  # Regione Dataplex, es. "europe-central2"

storage_client = storage.Client()
# Inizializzazione client Dataplex
dataplex_client = None

# --- FUNZIONE PER DATAPLEX ---
def trigger_dataplex_discovery(project_id: str, triggering_parquet_file_gcs_path: Optional[str] = None):
    """
    Tenta di forzare una discovery run per un asset specifico aggiornando
    la sua discovery_spec.schedule con un cron valido alternato.

    Args:
        project_id: L'ID del progetto GCP.
        triggering_parquet_file_gcs_path: (Opzionale, non usato in questa implementazione)
                                          Il percorso del file che ha scatenato l'operazione.
    Returns:
        Tuple[bool, str]: (successo, messaggio)
    """
    location = "europe-central2"  # Tua configurazione
    lake_id = "easyquery-lake"    # Tua configurazione
    zone_id = "silver-zone"       # Tua configurazione
    asset_id = "silver-layer"     # Tua configurazione

    print(f"[DATAPLEX DEBUG] Inizio trigger_dataplex_discovery (asset update) per asset: {asset_id}")
    client = dataplex_v1.DataplexServiceClient()
    asset_name = client.asset_path(project_id, location, lake_id, zone_id, asset_id)

    try:
        asset = client.get_asset(name=asset_name)
        current_schedule_str = asset.discovery_spec.schedule
        print(f"[DATAPLEX DEBUG] Current discovery schedule for asset '{asset_name}': '{current_schedule_str}'")

        # Definisci due stringhe cron VALIDE e leggermente diverse.
        # Esempio: esegui al minuto 0 di ogni ora.
        cron_schedule1 = "0 * * * *"
        # Esempio: esegui al minuto 5 di ogni ora (per essere sicuri che sia un cambiamento).
        cron_schedule2 = "5 * * * *"
        # Potresti anche usare cron più specifici se sai quando vuoi che venga eseguita,
        # ad esempio, per un'esecuzione "immediata" potresti provare a calcolare il prossimo minuto.
        # Per semplicità, alterniamo tra due schedulazioni orarie leggermente diverse.

        if current_schedule_str == cron_schedule1:
            new_schedule_str = cron_schedule2
        else:
            # Imposta a cron_schedule1 se l'attuale è diverso o vuoto
            new_schedule_str = cron_schedule1
        
        print(f"[DATAPLEX DEBUG] Attempting to set new discovery schedule to: '{new_schedule_str}' for asset '{asset_name}'")

        # Prepara l'oggetto Asset per l'aggiornamento.
        # È buona pratica creare un nuovo oggetto asset per l'aggiornamento
        # o modificare solo i campi necessari dell'asset recuperato.
        asset_update_payload = dataplex_v1.Asset()
        asset_update_payload.name = asset_name # Il nome è necessario per identificare l'asset
        asset_update_payload.discovery_spec.schedule = new_schedule_str
        
        # Costruisci l'update_mask corretto
        update_mask = field_mask_pb2.FieldMask(paths=["discovery_spec.schedule"])

        operation = client.update_asset(
            asset=asset_update_payload, # Passa l'oggetto con le modifiche
            update_mask=update_mask
        )
        print(f"[DATAPLEX DEBUG] UpdateAsset operation started: {operation.operation.name}. Waiting for completion...")
        
        # Attendi il completamento dell'operazione (potrebbe lanciare un'eccezione TimeoutError)
        operation.result(timeout=120)
        
        success_msg = (f"Discovery schedule for asset '{asset_name}' successfully updated to '{new_schedule_str}'. "
                       "Dataplex will trigger discovery based on this new schedule.")
        print(f"[DATAPLEX SUCCESS] {success_msg}")
        
        # Polling loop per monitorare il completamento della discovery
        max_wait_sec = 600  # 10 minuti
        interval = 30       # ogni 10 secondi
        waited = 0

        print(f"[DATAPLEX DEBUG] Starting polling for discovery completion...")
        while waited < max_wait_sec:
            try:
                asset = client.get_asset(name=asset_name)
                status = asset.discovery_status
                
                # Check if we have the fields we're looking for
                if hasattr(status, 'state'):
                    # Use the state directly if available
                    state = status.state.name
                    message = getattr(status, 'message', '')
                    last_run_time = getattr(status, 'update_time', None)
                    
                    print(f"[{waited}s] Discovery status: {state} - {message}")
                    
                    if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
                        discovery_result = {
                            "state": state,
                            "message": message,
                            "last_run_time": last_run_time.isoformat() if last_run_time else None
                        }
                        print(f"[DATAPLEX DEBUG] Discovery completed with state: {state}")
                        return True, {"message": success_msg, "discovery_result": discovery_result}
                elif hasattr(status, 'stats'):
                    # If we have stats, the discovery is likely running or completed
                    print(f"[{waited}s] Discovery status: Running - Discovery has stats")
                    
                    # Just print available fields for debugging
                    for field in dir(status):
                        if not field.startswith('_') and not callable(getattr(status, field)):
                            print(f"  - {field}: {getattr(status, field)}")
                else:
                    # We don't have enough information about the status
                    print(f"[{waited}s] Discovery status: Unknown - Limited information available")
                    print(f"Available fields: {dir(status)}")
                
            except Exception as e:
                print(f"[DATAPLEX WARNING] Error checking discovery status: {e}")
                traceback.print_exc()
            
            time.sleep(interval)
            waited += interval

        # Timeout but consider it a success since the schedule was updated
        timeout_msg = "Discovery scheduled but monitoring timed out after 10 minutes"
        print(f"[DATAPLEX INFO] {timeout_msg}")
        return True, {"message": timeout_msg, "state": "SCHEDULED"}

    except google.api_core.exceptions.InvalidArgument as e:
        error_msg = f"InvalidArgument error updating asset '{asset_name}': {e}. This likely means the cron format ('{new_schedule_str}') is still not accepted or there's another issue with the request."
        print(f"[DATAPLEX ERROR] {error_msg}")
        traceback.print_exc()
        return False, error_msg
    except google.api_core.exceptions.FailedPrecondition as e:
        error_msg = f"FailedPrecondition error updating asset '{asset_name}': {e}. This might indicate the asset is in a state that prevents updates (e.g., being deleted, or an ongoing operation)."
        print(f"[DATAPLEX ERROR] {error_msg}")
        traceback.print_exc()
        return False, error_msg
    except google.api_core.exceptions.PermissionDenied as e:
        error_msg = f"PermissionDenied error updating asset '{asset_name}': {e}. Ensure the Cloud Function's service account has 'dataplex.assets.update' permission on the asset."
        print(f"[DATAPLEX ERROR] {error_msg}")
        traceback.print_exc()
        return False, error_msg
    except google.api_core.exceptions.ResourceExhausted as e:
        # Gestione specifica per errori di quota (429)
        error_msg = f"Quota exceeded error while updating asset '{asset_name}': {e}. This is a rate limiting issue."
        print(f"[DATAPLEX QUOTA ERROR] {error_msg}")
        print(f"[DATAPLEX QUOTA INFO] The discovery will be attempted later automatically according to the schedule.")
        traceback.print_exc()
        # Ritorniamo un messaggio più informativo per l'utente
        return False, {
            "error_type": "quota_exceeded",
            "message": "Dataplex API quota exceeded. Table creation will proceed when the quota resets.",
            "details": str(e)
        }
    except TimeoutError:
        error_msg = f"Timeout waiting for UpdateAsset operation on '{asset_name}' to complete. The update might still be in progress or may have failed."
        print(f"[DATAPLEX WARNING] {error_msg}")
        # In caso di timeout, potresti voler considerare l'operazione come "potenzialmente riuscita" ma incerta.
        # Per ora, la marco come fallita ai fini della risposta della funzione.
        return False, error_msg
    except Exception as e:
        error_msg = f"Generic error updating asset '{asset_name}': {e}"
        print(f"[DATAPLEX ERROR] {error_msg}")
        traceback.print_exc()
        return False, error_msg

# --- FUNZIONI HELPER ESISTENTI ---
def determine_silver_path_components(file_path_in_bronze: str, file_extension: str, content_type: Optional[str] = None) -> List[str]:
    """
    Determina i componenti del percorso gerarchico in modo più compatto,
    concentrandosi sul contenuto effettivo dei dati.
    'file_path_in_bronze' è il nome del blob nel bucket bronze (es. "/data/raw/ditto/file.txt").
    """
    # Utilizziamo prefissi abbreviati per domain
    domain_map = {
        "finance": "fin",
        "sales": "sal",
        "marketing": "mkt",
        "hr": "hr",
        "operations": "ops",
        "it": "it",
        "general": "gen"  # Default
    }
    
    data_domain = "gen"  # Default abbreviato
    domain_patterns = {
        "finance": ["finance", "financial", "accounting", "invoice", "payment", "transaction"],
        "sales": ["sales", "revenue", "customer", "order", "product"],
        "marketing": ["marketing", "campaign", "advertisement", "promotion"],
        "hr": ["hr", "human_resources", "employee", "personnel", "recruitment"],
        "operations": ["operations", "logistics", "inventory", "supply_chain"],
        "it": ["it", "technology", "system", "software", "hardware", "tech", "dev"]
    }

    lower_file_in_bronze = file_path_in_bronze.lower()
    for domain, patterns in domain_patterns.items():
        if any(pattern in lower_file_in_bronze for pattern in patterns):
            data_domain = domain_map[domain]
            break

    # Abbreviamo anche le categorie
    category_map = {
        "structured": "str",
        "document": "doc",
        "image": "img",
        "spreadsheet": "spr",
        "unknown": "unk"
    }
    
    file_category = "unk"  # Default abbreviato
    if file_extension in ["csv", "parquet", "json", "jsonl", "avro", "orc"]:
        file_category = category_map["structured"]
    elif file_extension in ["pdf", "txt", "doc", "docx", "md", "rtf", "html"]:
        file_category = category_map["document"]
    elif file_extension in ["jpg", "jpeg", "png", "gif", "tiff", "bmp", "webp", "svg"]:
        file_category = category_map["image"]
    elif file_extension in ["xls", "xlsx", "ods", "numbers"]:
        file_category = category_map["spreadsheet"]

    # Semplifichiamo il context, usando direttamente il file_extension quando possibile
    content_context = file_extension
    if content_type:
        ct_lower = content_type.lower()
        if "application/json" in ct_lower:
            content_context = "json"
        elif "text/csv" in ct_lower:
            content_context = "csv"
        elif "application/pdf" in ct_lower:
            content_context = "pdf"
        elif "image/" in ct_lower:
            content_context = ct_lower.split('/')[-1].replace('jpeg', 'jpg')
        elif "text/plain" in ct_lower:
            content_context = "txt"
        elif "excel" in ct_lower or "spreadsheetml" in ct_lower:
            content_context = "excel"
    
    # Estrai il percorso della directory senza il nome del file
    directory_path = "/".join(file_path_in_bronze.split("/")[:-1])
    if directory_path.startswith("/"):
        directory_path = directory_path[1:]
    
    # Estrai il nome del file senza estensione per includerlo nel percorso
    file_name = os.path.basename(file_path_in_bronze)
    file_name_no_ext = os.path.splitext(file_name)[0]
    
    # Identifica pattern comuni nei nomi dei file (prefissi come train_, test_, validation_, ecc.)
    common_prefixes = ["train_", "test_", "val_", "validation_", "dev_", "sample_", "example_"]
    base_file_name = file_name_no_ext
    file_prefix = ""
    
    # Cerca prefissi comuni e separali dal nome base del file
    for prefix in common_prefixes:
        if file_name_no_ext.lower().startswith(prefix):
            base_file_name = file_name_no_ext[len(prefix):]  # Nome base senza il prefisso
            file_prefix = prefix[:-1]  # Rimuove l'underscore finale
            break
    
    # Identifica la parte più significativa del percorso
    significant_path = ""
    if directory_path:
        # Prendi solo le ultime 2 cartelle significative dal percorso originale
        path_parts = directory_path.split('/')
        if len(path_parts) > 2:
            significant_path = "/".join(path_parts[-2:])
        else:
            significant_path = directory_path
    
    # Costruisci componenti di percorso più compatti e focalizzati
    # Nuovo formato: dominio_categoria/tipo/percorso_significativo/nome_base
    # Il nome base è comune tra file correlati (train_audio, test_audio → base = audio)
    path_components = [
        f"{data_domain}_{file_category}",  # Prefisso compatto dominio_categoria
        content_context,                   # Tipo di contenuto
        significant_path,                  # Percorso significativo
        base_file_name                     # Nome base del file (senza prefissi comuni)
    ]
    
    # Se c'era un prefisso, lo aggiungiamo come metadato al nome della tabella finale
    # ma non al percorso gerarchico, così i file correlati restano nello stesso percorso
    if file_prefix and path_components:
        # Opzionale: per BigQuery table naming, potresti voler includere il prefisso
        # ma non influenza il percorso gerarchico
        # Ad esempio, potrebbe essere aggiunto successivamente quando si costruisce il nome della tabella
        print(f"File {file_name_no_ext} ha prefisso '{file_prefix}' e base '{base_file_name}'. "
              f"Verranno raggruppati con altri file della stessa base.")
    
    # Pulisci il percorso rimuovendo componenti vuoti
    return [part for part in path_components if part]

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

# --- FUNZIONI DI PROCESSAMENTO PER TIPO DI FILE ---
def process_file_by_type(file_path, file_extension, content_type, file_size, original_file_name):
    """
    Elabora un file in base alla sua estensione e restituisce un DataFrame.
    
    Args:
        file_path: Percorso al file temporaneo
        file_extension: Estensione del file (es. 'csv', 'pdf')
        content_type: Content-type del file
        file_size: Dimensione del file in bytes
        original_file_name: Nome originale del file
        
    Returns:
        pandas.DataFrame: DataFrame contenente i dati elaborati
    """
    df_processed = None
    
    # Elabora in base al tipo di file
    if file_extension == "txt":
        df_processed = _process_text_file(file_path)
    elif file_extension in ["csv", "tsv"]:
        df_processed = _process_tabular_file(file_path, file_extension)
    elif file_extension == "json":
        df_processed = _process_json_file(file_path)
    elif file_extension == "jsonl":
        df_processed = _process_jsonl_file(file_path)
    elif file_extension == "parquet":
        df_processed = _process_parquet_file(file_path)
    elif file_extension in ["xlsx", "xls"]:
        df_processed = _process_excel_file(file_path)
    elif file_extension == "pdf":
        df_processed = process_pdf(file_path)
    elif file_extension in ["jpg", "jpeg", "png", "gif", "tiff", "bmp", "webp", "svg"]:
        df_processed = process_image(file_path, file_extension)
    else:
        df_processed = _process_unsupported_file(content_type, file_size, original_file_name, file_extension)
    
    return df_processed

def _process_text_file(file_path):
    """Elabora un file di testo semplice."""
    with open(file_path, 'r', encoding='utf-8', errors='replace') as f_txt:
        return pd.DataFrame([{
            "extracted_text": f_txt.read(), 
            "deep_processed_ok": True
        }])

def _process_tabular_file(file_path, file_extension):
    """Elabora un file CSV o TSV con gestione robusta di vari formati."""
    
    # Prima tenta di rilevare il delimitatore
    import csv
    
    def detect_delimiter(filepath, sample_size=4096):
        with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
            sample = f.read(sample_size)
            
        sniffer = csv.Sniffer()
        try:
            dialect = sniffer.sniff(sample)
            return dialect.delimiter
        except:
            # Fallback a delimitatore standard basato su estensione
            print(f"Could not auto-detect delimiter, using default for {file_extension}")
            return ',' if file_extension == "csv" else '\t'
    
    print(f"Processing tabular file: {file_path}")
    
    # Serie di tentativi con configurazioni sempre più permissive
    attempts = [
        # Primo tentativo: auto-rilevamento delimitatore
        lambda: pd.read_csv(file_path, delimiter=detect_delimiter(file_path)),
        
        # Secondo tentativo: delimitatore standard + skip bad lines
        lambda: pd.read_csv(
            file_path, 
            delimiter=',' if file_extension == "csv" else '\t',
            on_bad_lines='skip',  # Skip rows with parsing errors
            low_memory=False  # Avoid dtype warnings/errors
        ),
        
        # Terzo tentativo: più configurazioni per robustezza
        lambda: pd.read_csv(
            file_path,
            delimiter=',' if file_extension == "csv" else '\t',
            on_bad_lines='skip',
            quoting=csv.QUOTE_NONE,  # Ignore quotes
            low_memory=False,
            engine='python'  # Sometimes more forgiving
        ),
        
        # Quarto tentativo: metodo estremo per file molto inconsistenti
        lambda: pd.read_csv(
            file_path,
            delimiter=',' if file_extension == "csv" else '\t',
            on_bad_lines='skip',
            quoting=csv.QUOTE_NONE,
            escapechar='\\',
            engine='python',
            low_memory=False,
            skip_blank_lines=True,
            encoding='utf-8',
            encoding_errors='replace'
        )
    ]
    
    errors = []
    for i, attempt_func in enumerate(attempts):
        try:
            print(f"CSV parsing attempt {i+1}/{len(attempts)}...")
            df = attempt_func()
            if not df.empty:
                print(f"Successfully parsed with attempt {i+1}")
                df["deep_processed_ok"] = True
                return df
        except Exception as e:
            errors.append(f"Attempt {i+1} failed: {str(e)}")
            print(f"CSV parsing attempt {i+1} failed: {e}")
    
    # Se tutti i tentativi falliscono, crea un DataFrame con gli errori come informazioni
    print(f"All CSV parsing attempts failed. Creating error DataFrame with metadata.")
    return pd.DataFrame([{
        "original_file_path": file_path,
        "file_extension": file_extension,
        "deep_processed_ok": False,
        "processing_errors": "; ".join(errors),
        "error_description": "Failed to parse tabular file after multiple attempts with different settings"
    }])

def _process_json_file(file_path):
    """Elabora un file JSON."""
    try:
        df = pd.read_json(file_path, orient='records')
        df["deep_processed_ok"] = True
        return df
    except ValueError:
        # Prova a caricare come JSONL se fallisce come JSON standard
        df = pd.read_json(file_path, lines=True)
        df["deep_processed_ok"] = True
        return df

def _process_jsonl_file(file_path):
    """Elabora un file JSONL (JSON Lines)."""
    df = pd.read_json(file_path, lines=True)
    df["deep_processed_ok"] = True
    return df

def _process_parquet_file(file_path):
    """Elabora un file Parquet."""
    df = pd.read_parquet(file_path)
    df["deep_processed_ok"] = True
    return df

def _process_excel_file(file_path):
    """Elabora un file Excel."""
    df = pd.read_excel(file_path, engine=None)
    df["deep_processed_ok"] = True
    return df

def _process_unsupported_file(content_type, file_size, file_name, file_extension):
    """Crea un DataFrame con i metadati per file di tipo non supportato."""
    return pd.DataFrame([{
        "original_content_type": content_type,
        "original_file_size_bytes": file_size,
        "original_file_name": file_name,
        "deep_processed_ok": False,
        "processing_note": f"Unsupported file type '{file_extension}' for deep processing."
    }])

# --- FUNZIONI DI ARRICCHIMENTO E PREPARAZIONE DATI ---

def prepare_dataframe_for_parquet(df, metadata_column_names):
    """
    Prepara il DataFrame per la conversione in Parquet:
    - Separa i metadati dai dati
    - Gestisce i tipi di dati problematici
    - Normalizza valori nulli
    
    Args:
        df: DataFrame da preparare
        metadata_column_names: Lista di nomi colonna da considerare metadati
        
    Returns:
        Tuple[pandas.DataFrame, dict]: DataFrame pulito per Parquet e dizionario metadati
    """
    if not isinstance(df, pd.DataFrame) or df.empty:
        raise ValueError("Input must be a non-empty pandas DataFrame")
    
    # Estrai i metadati prima di rimuoverli dal DataFrame
    metadata_values = {}
    for col in metadata_column_names:
        if col in df.columns:
            # Prendi il primo valore non nullo, o None se tutti nulli o colonna non presente
            values = df[col].dropna()
            if not values.empty:
                metadata_value = values.iloc[0]
                # Converti datetime in formato ISO per JSON
                if isinstance(metadata_value, pd.Timestamp):
                    metadata_value = metadata_value.isoformat()
                metadata_values[col] = metadata_value
    
    # Rimuovi le colonne di metadati dal DataFrame da salvare come Parquet
    metadata_cols_to_remove = [col for col in metadata_column_names if col in df.columns]
    df_data_only = df.drop(columns=metadata_cols_to_remove, errors='ignore')
    
    # Gestisci le colonne che potrebbero avere tipi misti
    df_data_only = _handle_mixed_type_columns(df_data_only, df)
    
    # Sostituisci tutti i valori nan/None con stringhe vuote per le colonne di tipo object
    for col in df_data_only.select_dtypes(include=['object']):
        df_data_only[col] = df_data_only[col].fillna('')
    
    # Aggiungi colonna date_partition come stringa normale, non come partizione Hive
    if 'date_partition' not in df_data_only.columns:
        current_date = datetime.datetime.utcnow().strftime("%Y/%m/%d")
        df_data_only['date_partition'] = current_date
    
    return df_data_only, metadata_values

def _handle_mixed_type_columns(df_data_only, original_df):
    """
    Gestisce le colonne con potenziali tipi di dati misti.
    """
    # Elenco delle colonne che potrebbero contenere tipi di dati misti
    potential_mixed_type_columns = [
        "year_founded", "established_date", "registration_id", "reference_code"
    ]
    
    for col in df_data_only.columns:
        # Gestione specifica per colonne con potenziali tipi misti
        if col in potential_mixed_type_columns or df_data_only[col].dtype == 'object':
            try:
                # Se la colonna contiene tutti valori numerici, converte in float
                df_data_only[col] = pd.to_numeric(df_data_only[col], errors='coerce')
                # Se ci sono valori NaN dopo conversione (originariamente non numerici),
                # converte tutta la colonna in string
                if df_data_only[col].isna().any():
                    # Salva lo stato originale della colonna per non perdere valori non numerici
                    original_values = original_df[col].copy()
                    # Ripristina i valori originali e converte tutto in stringa
                    df_data_only[col] = original_values.astype(str)
            except Exception as e_col:
                print(f"Conversione della colonna '{col}' a formato omogeneo fallita: {e_col}. Conversione in stringa.")
                # In caso di errore, converti in stringa
                df_data_only[col] = df_data_only[col].astype(str)
    
    return df_data_only

# --- FUNZIONI DI STORAGE E INTEGRAZIONE ---
def save_dataframe_to_parquet(df, output_path):
    """
    Salva il DataFrame come file Parquet, con gestione degli errori.
    
    Args:
        df: DataFrame da salvare
        output_path: Percorso dove salvare il file Parquet
        
    Returns:
        str: Percorso del file salvato
    """
    print(f"Tipi di dati nel DataFrame prima del salvataggio Parquet: {df.dtypes}")
    
    try:
        df.to_parquet(output_path, index=False, engine='pyarrow')
    except Exception as e_parquet:
        print(f"Errore nel salvataggio Parquet, tentativo con conversione estrema: {e_parquet}")
        # Ultima risorsa: converti tutte le colonne in stringa
        for col in df.columns:
            if df[col].dtype != 'int64' and df[col].dtype != 'float64' and df[col].dtype != 'bool':
                df[col] = df[col].astype(str)
        df.to_parquet(output_path, index=False, engine='pyarrow')
    
    return output_path

def upload_to_gcs_and_update_manifest(
    parquet_file_path, 
    silver_bucket_name, 
    silver_data_path, 
    silver_manifest_path,
    file_basename,
    bronze_uri,
    metadata_values,
    df_data
):
    """
    Carica il file Parquet su GCS e aggiorna il manifest.
    
    Args:
        parquet_file_path: Percorso locale del file Parquet
        silver_bucket_name: Nome del bucket silver
        silver_data_path: Percorso directory dati nel bucket silver
        silver_manifest_path: Percorso manifest nel bucket silver
        file_basename: Nome base del file (senza estensione)
        bronze_uri: URI del file originale nel bronze bucket
        metadata_values: Dizionario dei valori di metadati
        df_data: DataFrame con i dati (per conteggio record e schema)
        
    Returns:
        str: URI completo del file Parquet nel bucket silver
    """
    silver_bucket = storage_client.bucket(silver_bucket_name)
    
    # Prepara il percorso del file Parquet
    silver_parquet_filename = f"{file_basename}.parquet"
    silver_parquet_full_gcs_path = f"{silver_data_path}/{silver_parquet_filename}"
    
    # Carica il file Parquet su GCS
    silver_blob_data_upload = silver_bucket.blob(silver_parquet_full_gcs_path)
    silver_blob_data_upload.upload_from_filename(parquet_file_path)
    print(f"Uploaded Parquet to gs://{silver_bucket_name}/{silver_parquet_full_gcs_path}")
    
    # Prepara il percorso del manifest
    silver_manifest_full_gcs_path = f"{silver_manifest_path}/_partition_manifest.json"
    
    # Aggiorna il manifest
    manifest_blob = silver_bucket.blob(silver_manifest_full_gcs_path)
    current_manifest_entries = _load_existing_manifest(manifest_blob)
    
    # Prepara l'URI del file Parquet nel silver bucket
    uri_parquet_in_silver = f"gs://{silver_bucket_name}/{silver_parquet_full_gcs_path}"
    
    # Filtra eventuali voci duplicate per lo stesso file
    current_manifest_entries = [
        e for e in current_manifest_entries 
        if e.get("silver_file_uri") != uri_parquet_in_silver
    ]
    
    # Aggiungi la nuova voce al manifest
    manifest_entry = _create_manifest_entry(
        uri_parquet_in_silver,
        bronze_uri,
        df_data,
        silver_data_path,
        metadata_values
    )
    
    current_manifest_entries.append(manifest_entry)
    
    # Salva il manifest aggiornato
    manifest_json = json.dumps(
        current_manifest_entries, 
        default=_json_serializable, 
        indent=2
    )
    manifest_blob.upload_from_string(manifest_json, content_type="application/json")
    print(f"Manifest updated at gs://{silver_bucket_name}/{silver_manifest_full_gcs_path}")
    
    return uri_parquet_in_silver

def _load_existing_manifest(manifest_blob):
    """Carica il manifest esistente o inizializza una lista vuota."""
    current_manifest_entries = []
    
    if manifest_blob.exists():
        try:
            manifest_content = manifest_blob.download_as_text()
            loaded_manifest = json.loads(manifest_content)
            if isinstance(loaded_manifest, list):
                current_manifest_entries = loaded_manifest
            else:
                print(f"Warning: Manifest {manifest_blob.name} was not a list. Reinitializing.")
        except Exception as e_m_load:
            print(f"Warning: Could not load/parse manifest {manifest_blob.name}: {e_m_load}. Reinitializing.")
    
    return current_manifest_entries

def _create_manifest_entry(uri_parquet, bronze_uri, df, data_path_base, metadata_values):
    """Crea una nuova voce per il manifest."""
    # Schema DataFrame con conversione valori NumPy
    safe_schema = {}
    for col, dtype in df.dtypes.items():
        safe_schema[col] = str(dtype)
    
    # Estrai i metadati base della sorgente
    bronze_parts = bronze_uri.split('/')
    bronze_bucket = bronze_parts[2] if len(bronze_parts) > 2 else ''
    bronze_blob_path = '/'.join(bronze_parts[3:]) if len(bronze_parts) > 3 else ''
    
    return {
        "silver_file_uri": uri_parquet,
        "bronze_source_uri": bronze_uri,
        "record_count": int(len(df)),  # Conversione esplicita per sicurezza
        "silver_processed_at": datetime.datetime.utcnow().isoformat() + "Z",
        "bronze_bucket": bronze_bucket,
        "bronze_blob_path": bronze_blob_path,
        "silver_df_schema": safe_schema,
        "silver_data_path_base": data_path_base,
        "metadata": json.loads(json.dumps(metadata_values, default=_json_serializable))  # Conversione sicura
    }

def _json_serializable(obj):
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

def prepare_bigquery_columns_info(df):
    """
    Prepara le informazioni sulle colonne per BigQuery.
    
    Args:
        df: DataFrame con i dati
        
    Returns:
        List[dict]: Lista di dizionari con nome e tipo di ogni colonna
    """
    processed_columns_with_types = []
    
    for col_name, dtype in df.dtypes.items():
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
    
    return processed_columns_with_types

def calculate_bigquery_table_id(project_id, path_components, root_prefix):
    """
    Calcola l'ID della tabella BigQuery basato sul percorso.
    
    Args:
        project_id: ID del progetto GCP
        path_components: Componenti del percorso
        root_prefix: Prefisso radice (es. silver_data_files)
        
    Returns:
        str: ID completo della tabella BigQuery
    """
    # Prepara le parti del nome della tabella
    dataplex_table_name_parts = [root_prefix]
    dataplex_table_name_parts.extend(path_components)
    
    # Unisci i componenti con underscore per ottenere il nome della tabella
    dataplex_table_id = "_".join(dataplex_table_name_parts)
    
    # Sanitizzazione aggiuntiva per assicurarsi che sia un nome tabella BigQuery valido
    dataplex_table_id = ''.join(c if c.isalnum() or c == '_' else '_' for c in dataplex_table_id)
    if not dataplex_table_id[0].isalpha() and dataplex_table_id[0] != '_':
        dataplex_table_id = 'tbl_' + dataplex_table_id
    
    # Il nome completo della tabella BigQuery che Dataplex creerà
    return f"{project_id}.silver_zone.{dataplex_table_id}"

# --- NUOVA FUNZIONE PER AGGIORNARE I METADATI DEL FILE BRONZE ---
def update_bronze_file_metadata(
    bronze_bucket,
    bronze_blob_path,
    silver_uri,
    bigquery_table_id,
    record_count,
    columns_info
):
    """
    Aggiorna i metadati del file bronze originale per indicare che è stato processato
    e dove si trovano i dati elaborati in silver.
    
    Args:
        bronze_bucket: Bucket GCS del file bronze
        bronze_blob_path: Path del blob nel bucket bronze
        silver_uri: URI completo del file silver corrispondente
        bigquery_table_id: ID della tabella BigQuery che conterrà i dati
        record_count: Numero di record elaborati
        columns_info: Informazioni sulle colonne elaborate
    """
    try:
        # Ottieni il blob
        bronze_bucket_obj = storage_client.bucket(bronze_bucket)
        bronze_blob_obj = bronze_bucket_obj.get_blob(bronze_blob_path)
        
        if not bronze_blob_obj:
            print(f"WARNING: Blob {bronze_blob_path} non trovato in bucket {bronze_bucket} per aggiornamento metadati.")
            return False
        
        # Ottieni i metadati esistenti o inizializza un nuovo dict
        existing_metadata = bronze_blob_obj.metadata or {}
        
        # Aggiorna i metadati con le informazioni di elaborazione
        processing_metadata = {
            "processed": "true",
            "processed_timestamp": datetime.datetime.utcnow().isoformat(),
            "silver_path": silver_uri,
            "bigquery_table": bigquery_table_id,
            "record_count": str(record_count),  # Converti a string perché i metadati GCS richiedono stringhe
            "silver_columns_count": str(len(columns_info)) if columns_info else "0"
        }
        
        # Mantieni i metadati esistenti ma aggiorna/aggiungi quelli nuovi
        existing_metadata.update(processing_metadata)
        
        # Aggiorna i metadati del blob
        bronze_blob_obj.metadata = existing_metadata
        bronze_blob_obj.patch()
        
        print(f"Metadati del file bronze {bronze_blob_path} aggiornati con successo. Stato: processato.")
        return True
    
    except Exception as e:
        print(f"Errore nell'aggiornamento metadati del file bronze {bronze_blob_path}: {e}")
        traceback.print_exc()
        return False

# --- NUOVA FUNZIONE PER AGGIORNARE LA TABELLA METADATA_STORE.BRONZE_FILE_METADATA IN BQ ---
def update_bronze_metadata_in_bigquery(
    project_id,
    bronze_bucket,
    bronze_blob_path,
    silver_uri,
    bigquery_table_id,
    record_count,
    columns_info
):
    """
    Aggiorna la tabella metadata_store.bronze_file_metadata in BigQuery con le informazioni sul file bronze processato.
    Evita l'errore di streaming buffer inserendo un nuovo record invece di fare UPDATE.
    
    Args:
        project_id: ID del progetto GCP
        bronze_bucket: Bucket GCS del file bronze
        bronze_blob_path: Path del blob nel bucket bronze
        silver_uri: URI completo del file silver corrispondente
        bigquery_table_id: ID della tabella BigQuery che conterrà i dati
        record_count: Numero di record elaborati
        columns_info: Informazioni sulle colonne elaborate
    
    Returns:
        bool: True se l'operazione è andata a buon fine, False altrimenti
    """
    try:
        # Inizializza il client BigQuery
        bq_client = bigquery.Client(project=project_id)
        
        # Costruisci il nome completo della tabella
        table_id = f"{project_id}.metadata_store.bronze_file_metadata"
        
        # Costruisci il GCS URI completo per il file bronze con doppio slash dopo il bucket
        # Questo formato sembra essere quello usato nella tabella
        clean_bronze_path = bronze_blob_path.lstrip('/')
        bronze_gcs_uri = f"gs://{bronze_bucket}//{clean_bronze_path}"
        
        print(f"Cercando record con file_gcs_uri: {bronze_gcs_uri}")
        
        # Verifica se esiste già un record per questo file usando file_gcs_uri
        check_query = f"""
        SELECT * FROM `{table_id}` 
        WHERE file_gcs_uri = "{bronze_gcs_uri}"
        LIMIT 1
        """
        
        query_job = bq_client.query(check_query)
        result = list(query_job.result())
        record_exists = len(result) > 0
        
        # Recupera informazioni esistenti se disponibili
        # Questo ci permette di preservare i campi che non stiamo aggiornando
        existing_data = {}
        if record_exists:
            record = result[0]
            # Salva TUTTI i campi esistenti
            for field in record.keys():
                if field not in ['processed', 'processed_timestamp', 'silver_path', 'bigquery_table', 'record_count', 'silver_columns']:
                    value = getattr(record, field)
                    # Per array e JSON, gestisci correttamente i valori NULL
                    if field in ['tags', 'additional_metadata'] and value is None:
                        if field == 'tags':
                            value = []
                        elif field == 'additional_metadata':
                            value = {}
                    existing_data[field] = value
            print(f"Trovato record esistente per file_gcs_uri: {bronze_gcs_uri}")
        
        # Prepara le colonne delle tabelle come JSON
        columns_json = json.dumps([{
            "name": col["name"],
            "type": col["type"]
        } for col in columns_info])
        
        # Timestamp di elaborazione
        processed_timestamp = datetime.datetime.utcnow().isoformat()
        current_time = datetime.datetime.utcnow()
        
        # Prepara i valori di default per i campi obbligatori
        file_name = os.path.basename(bronze_blob_path)
        file_extension = os.path.splitext(file_name)[1].lstrip('.') if '.' in file_name else ''
        file_path = f"/{clean_bronze_path}"
        event_time = current_time.isoformat()
        metadata_ingestion_time = existing_data.get('metadata_ingestion_time', current_time.isoformat())
        processing_status = "PROCESSED_TO_SILVER"
        
        
        # Nota: questa query non viene eseguita per evitare problemi con lo streaming buffer.
        # Se vuoi eseguirla, puoi decommentare la riga seguente:
        # bq_client.query(delete_old_row_query).result()
        
        # Costruisci la query INSERT con tutti i campi necessari
        # Gestisci correttamente i campi specifici
        insert_query = f"""
        INSERT INTO `{table_id}` (
          file_gcs_uri,
          bucket_name,
          file_path,
          file_name,
          file_extension,
          content_type,
          file_size_bytes,
          gcs_generation_id,
          gcs_metageneration_id,
          gcs_crc32c_hash,
          gcs_md5_hash,
          event_time,
          metadata_ingestion_time,
          processing_status,
          last_processed_by,
          last_processing_notes,
          source_system,
          data_domain,
          tags,
          has_text_content,
          additional_metadata,
          processed,
          processed_timestamp,
          silver_path,
          bigquery_table,
          record_count,
          silver_columns
        )
        VALUES (
          "{bronze_gcs_uri}",
          "{bronze_bucket}",
          "{file_path}",
          "{file_name}",
          "{file_extension}",
          "{existing_data.get('content_type', '')}",
          {existing_data.get('file_size_bytes', 'NULL')},
          "{existing_data.get('gcs_generation_id', '')}",
          "{existing_data.get('gcs_metageneration_id', '')}",
          "{existing_data.get('gcs_crc32c_hash', '')}",
          "{existing_data.get('gcs_md5_hash', '')}",
          TIMESTAMP("{event_time}"),
          TIMESTAMP("{metadata_ingestion_time}"),
          "{processing_status}",
          "bronze-to-silver",
          "File processato automaticamente da bronze a silver",
          "{existing_data.get('source_system', '')}",
          "{existing_data.get('data_domain', '')}",
        """
        
        # Gestisci specificamente l'array 'tags' (che potrebbe essere NULL)
        tags_value = existing_data.get('tags', [])
        if tags_value:
            # Se abbiamo tag, convertiamoli in formato array per SQL
            tags_sql = json.dumps(tags_value)
            insert_query += f"\n          {tags_sql},"
        else:
            insert_query += "\n          [],\n"
        
        # Aggiungi il resto dei campi
        insert_query += f"""
          {existing_data.get('has_text_content', 'FALSE')},
        """
        
        # Gestisci il campo additional_metadata (JSON)
        additional_metadata = existing_data.get('additional_metadata', {})
        if additional_metadata:
            # Serializza come JSON valido per SQL
            metadata_json = json.dumps(additional_metadata)
            insert_query += f"\n          JSON '{metadata_json}',"
        else:
            insert_query += "\n          JSON '{}',\n"
        
        # Completa la query con i valori di elaborazione
        insert_query += f"""
          TRUE,
          TIMESTAMP("{processed_timestamp}"),
          "{silver_uri}",
          "{bigquery_table_id}",
          {record_count},
          JSON '{columns_json}'
        )
        """
        
        
        print(f"Inserimento nuovo record in {table_id} per file_gcs_uri: {bronze_gcs_uri}")
        try:
            bq_client.query(insert_query).result()
            print("Nuovo record inserito con successo")
            
            return True
        except Exception as e_insert:
            print(f"Errore nell'inserimento del record: {e_insert}")
            if "duplicate" in str(e_insert).lower():
                print("Questo è normale se il file è stato elaborato recentemente e ha un vincolo di unicità.")
                return True  # Consideriamo comunque l'operazione riuscita
            else:
                raise  # Rilanciamo l'eccezione se è un errore diverso
            
    except Exception as e:
        print(f"Errore nell'aggiornamento della tabella metadata_store.bronze_file_metadata: {e}")
        traceback.print_exc()
        return False

# --- FUNZIONE PRINCIPALE CLOUD FUNCTION (Riorganizzata) ---
@functions_framework.http
def bronze_to_silver(request: Request):
    """
    Funzione HTTP per convertire file dal bucket bronze al bucket silver.
    Salva i dati Parquet in una struttura di cartelle e i manifest JSON in una struttura parallela.
    La scansione Dataplex è ora gestita da una funzione separata.
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

        # Validazione input
        if not request.is_json:
            return ({"status": "error", "error": "Invalid content type, expected application/json"}, 415, response_cors_headers)

        data_payload = request.get_json(silent=True)
        if data_payload is None:
             return ({"status": "error", "error": "Malformed JSON or empty request body"}, 400, response_cors_headers)
        if "path" not in data_payload:
            return ({"status": "error", "error": "Missing 'path' in request JSON"}, 400, response_cors_headers)

        # Estrai e verifica il percorso del file bronze
        full_path_from_caller = data_payload["path"]
        force_processing = data_payload.get("force_processing", False)
        custom_data_prefix_override = data_payload.get("custom_prefix", None)
        # Manteniamo il parametro skip_dataplex per retrocompatibilità, ma non lo utilizziamo più attivamente
        skip_dataplex = data_payload.get("skip_dataplex", True)  # Default a True ora che la scansione è separata

        # Handle both gs:// URI format and simple bucket/path format
        if full_path_from_caller.startswith("gs://"):
            # Remove 'gs://' prefix and split remaining path
            path_without_protocol = full_path_from_caller[5:]  # Remove 'gs://'
            parts = path_without_protocol.split('/', 1)
            if len(parts) < 2 or not parts[0] or not parts[1]:
                return ({"status": "error", "error": "Invalid GCS URI format. Expected 'gs://bucket_name/path/to/file'"}, 400, response_cors_headers)
            bronze_bucket_name = parts[0]
            blob_name_in_gcs = '/' + parts[1]  # Add leading slash for GCS operations
        else:
            # Original handling for bucket_name/path/to/file format
            if not isinstance(full_path_from_caller, str) or '/' not in full_path_from_caller:
                return ({"status": "error", "error": "Invalid 'path' format. Expected string 'bucket_name/path/to/file'"}, 400, response_cors_headers)

            bronze_bucket_name, *blob_parts = full_path_from_caller.split("/", 1)
            if not blob_parts or not blob_parts[0]:
                return ({"status": "error", "error": "Invalid path format. File path part is missing after bucket name."}, 400, response_cors_headers)

            object_path_from_caller_no_leading_slash = blob_parts[0].lstrip('/')
            blob_name_in_gcs = f"/{object_path_from_caller_no_leading_slash}"  # Path GCS inizia con /

        print(f"Original path from caller: '{full_path_from_caller}'")
        print(f"Derived bronze_bucket_name: '{bronze_bucket_name}'")
        print(f"Blob name used for GCS operations: '{blob_name_in_gcs}'")

        # Estrai informazioni sul file
        file_name_original_ext = os.path.basename(blob_name_in_gcs)
        file_extension_original = os.path.splitext(file_name_original_ext)[1].lower().lstrip('.')
        base_filename_no_ext = os.path.splitext(file_name_original_ext)[0]

        # Verifica esistenza del file nel bucket bronze
        bronze_bucket = storage_client.bucket(bronze_bucket_name)
        bronze_blob = bronze_bucket.blob(blob_name_in_gcs)

        print(f"Checking existence of bronze file: gs://{bronze_bucket_name}{blob_name_in_gcs}")
        if not bronze_blob.exists():
            return ({"status": "error", "error": f"File not found in bronze: gs://{bronze_bucket_name}{blob_name_in_gcs}"}, 404, response_cors_headers)
        print(f"Bronze file gs://{bronze_bucket_name}{blob_name_in_gcs} confirmed to exist.")

        # Ottieni metadati del file
        bronze_blob.reload()
        original_blob_content_type = bronze_blob.content_type or "application/octet-stream"
        original_blob_size = bronze_blob.size

        # Download del file in un percorso temporaneo
        with tempfile.NamedTemporaryFile(delete=False, suffix=f".{file_extension_original}") as tmp_in:
            tmp_in_path = tmp_in.name
            print(f"Downloading bronze file to temporary path: {tmp_in_path}")
            
        bronze_blob.download_to_filename(tmp_in_path)
        print(f"Downloaded bronze file: gs://{bronze_bucket_name}{blob_name_in_gcs} to {tmp_in_path}")
        
        # Verifica che il file temporaneo esista
        if not os.path.exists(tmp_in_path) or not os.path.getsize(tmp_in_path) > 0:
            error_msg = f"Failed to download file or file is empty: {tmp_in_path}"
            print(error_msg)
            return ({"status": "error", "error": error_msg}, 500, response_cors_headers)

        # Determina i componenti del percorso silver
        path_suffix_components = determine_silver_path_components(
            blob_name_in_gcs,
            file_extension_original,
            original_blob_content_type
        )
        path_suffix_str = "/".join(path_suffix_components)

        # Costruisci i percorsi silver
        silver_data_files_base_path = f"{SILVER_DATA_FILES_ROOT_PREFIX}/{path_suffix_str}"
        silver_manifests_base_path = f"{SILVER_MANIFESTS_ROOT_PREFIX}/{path_suffix_str}"

        if custom_data_prefix_override:
            silver_data_files_base_path = custom_data_prefix_override.rstrip('/')
            print(f"Using custom data prefix: {silver_data_files_base_path}")

        # 1. Elabora il file in base al tipo
        df_processed = process_file_by_type(
            tmp_in_path,
            file_extension_original,
            original_blob_content_type,
            original_blob_size,
            file_name_original_ext
        )

        if not isinstance(df_processed, pd.DataFrame):
            return ({"status": "error", "error": "Internal error: Processing did not yield a DataFrame."}, 500, response_cors_headers)

        # 3. Prepara il DataFrame per la conversione in Parquet
        if df_processed is not None and not df_processed.empty:
            # Lista delle colonne di metadati
            metadata_columns = [
                "silver_ingestion_ts", "bronze_source_uri", "original_file_extension",
                "silver_data_domain", "silver_file_category", "deep_processed_ok"
            ]
            
            # Prepara il DataFrame e estrai i metadati
            df_data_only, metadata_values = prepare_dataframe_for_parquet(df_processed, metadata_columns)
            
            # 4. Salva il DataFrame come Parquet in un file temporaneo
            with tempfile.NamedTemporaryFile(delete=False, suffix=".parquet") as tmp_out:
                tmp_out_path = tmp_out.name
            
            save_dataframe_to_parquet(df_data_only, tmp_out_path)
            
            # Arricchisci il DataFrame con metadati standard
            bronze_uri = f"gs://{bronze_bucket_name}{blob_name_in_gcs}"
            
            # 5. Carica il file Parquet su GCS e aggiorna il manifest
            uri_parquet_in_silver = upload_to_gcs_and_update_manifest(
                tmp_out_path,
                SILVER_BUCKET_NAME,
                silver_data_files_base_path,
                silver_manifests_base_path,
                base_filename_no_ext,
                bronze_uri,
                metadata_values,
                df_data_only
            )
            
            # 6. La scansione Dataplex è ora gestita separatamente - aggiorniamo solo i messaggi informativi
            dataplex_info = "La scansione Dataplex è ora gestita separatamente tramite la funzione batch-dataplex-scan"
            
            # Identifica il project_id corrente
            project_id = os.environ.get("GCP_PROJECT") or os.environ.get("GOOGLE_CLOUD_PROJECT")
            if not project_id:
                print("ATTENZIONE: Impossibile determinare il project_id dagli env vars.")
                project_id = "soy-transducer-456512-t0"  # Fallback project ID
            
            # 7. Prepara le informazioni sulle colonne per la risposta
            processed_columns_with_types = prepare_bigquery_columns_info(df_data_only)
            
            # 8. Calcola il nome della tabella BigQuery che verrà creata
            expected_bq_table_ref = calculate_bigquery_table_id(
                project_id,
                path_suffix_components,
                SILVER_DATA_FILES_ROOT_PREFIX
            )
            
            # NUOVO: Aggiorna i metadati del file bronze originale
            # Rimuovi il prefisso di GCS per ottenere solo il path relativo per il blob
            bronze_blob_path = blob_name_in_gcs
            if bronze_blob_path.startswith('/'):
                bronze_blob_path = bronze_blob_path[1:]  # Rimuovi lo slash iniziale se presente
                
            # Manteniamo l'aggiornamento dei metadati sul blob
            update_success = update_bronze_file_metadata(
                bronze_bucket_name,
                bronze_blob_path,
                uri_parquet_in_silver,
                expected_bq_table_ref,
                len(df_data_only),
                processed_columns_with_types
            )
            
            # NUOVO: Aggiorniamo anche la tabella BigQuery metadata_store.bronze_file_metadata
            update_bq_success = update_bronze_metadata_in_bigquery(
                project_id,
                bronze_bucket_name,
                bronze_blob_path,  # Già senza slash iniziale se necessario
                uri_parquet_in_silver,
                expected_bq_table_ref,
                len(df_data_only),
                processed_columns_with_types
            )
            
            # 9. Prepara e restituisci la risposta
            response_data = {
                "status": "success",
                "message": f"Processed gs://{bronze_bucket_name}{blob_name_in_gcs} to Silver: {uri_parquet_in_silver}",
                "silver_path": uri_parquet_in_silver,
                "columns": processed_columns_with_types,
                "record_count": len(df_data_only),
                "silver_path_prefix_base": silver_data_files_base_path,
                "bigquery_table": expected_bq_table_ref,
                "bronze_metadata_updated": update_success,
                "bronze_metadata_updated_in_bigquery": update_bq_success  # Nuova informazione nella risposta
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