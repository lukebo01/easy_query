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
    #date_partition_str = datetime.datetime.utcnow().strftime("date_%Y_%m_%d") # Formato non-Hive
    
    # da file_path_in_bronze scompongo il path nelle varie cartelle, eliminando il nome del file
    
    # Extract the directory path by removing everything after the last "/"
    directory_path = "/".join(file_path_in_bronze.split("/")[:-1])
    print(f"Directory path (without filename): {directory_path}")

    # Use the directory path instead of the full file path for consistency
    # This ensures we only use folder structure without the filename
    
    if directory_path.startswith("/"):
        directory_path = directory_path[1:]

    path_components = [
        data_domain,
        file_category,
        content_context,
        directory_path
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
    """Elabora un file CSV o TSV."""
    delimiter = ',' if file_extension == "csv" else '\t'
    df = pd.read_csv(file_path, delimiter=delimiter)
    df["deep_processed_ok"] = True
    return df

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
    # Elenco delle colonne che potrebbero contenere tipi misti
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

# --- FUNZIONE PRINCIPALE CLOUD FUNCTION (Riorganizzata) ---
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
            
            # 6. Avvia la scansione Dataplex
            dataplex_success = False
            dataplex_info = "Scansione Dataplex non eseguita"
            
            # Identifica il project_id corrente
            project_id = os.environ.get("GCP_PROJECT") or os.environ.get("GOOGLE_CLOUD_PROJECT")
            if not project_id:
                print("ATTENZIONE: Impossibile determinare il project_id dagli env vars.")
                project_id = "soy-transducer-456512-t0"  # Fallback project ID
            
            try:
                # Avvia la scansione Dataplex
                dataplex_success, dataplex_info = trigger_dataplex_discovery(project_id)
                
                if dataplex_success:
                    print(f"Scansione Dataplex avviata con successo.")
                else:
                    print(f"Avviso: Scansione Dataplex non riuscita: {dataplex_info}")
            
            except Exception as e_dataplex:
                dataplex_success = False
                dataplex_info = f"Errore durante la scansione Dataplex: {str(e_dataplex)}"
                traceback.print_exc()
            
            # 7. Prepara le informazioni sulle colonne per la risposta
            processed_columns_with_types = prepare_bigquery_columns_info(df_data_only)
            
            # 8. Calcola il nome della tabella BigQuery che verrà creata
            expected_bq_table_ref = calculate_bigquery_table_id(
                project_id,
                path_suffix_components,
                SILVER_DATA_FILES_ROOT_PREFIX
            )
            
            # 9. Prepara e restituisci la risposta
            response_data = {
                "status": "success",
                "message": f"Processed gs://{bronze_bucket_name}{blob_name_in_gcs} to Silver: {uri_parquet_in_silver}. Dataplex discovery triggered.",
                "silver_path": uri_parquet_in_silver,
                "columns": processed_columns_with_types,
                "record_count": len(df_data_only),
                "silver_path_prefix_base": silver_data_files_base_path,
                "bigquery_table": expected_bq_table_ref,
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