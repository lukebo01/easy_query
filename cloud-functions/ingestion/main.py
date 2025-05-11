import functions_framework
from google.cloud import bigquery, storage, vision, documentai, language
import datetime
import os
import re
import mimetypes
import hashlib
from PIL import Image
import io
import PyPDF2
import json

# Configurazione
PROJECT_ID = os.environ.get("GCP_PROJECT")
BIGQUERY_DATASET_ID = "metadata_store"
BIGQUERY_TABLE_ID = "bronze_file_metadata"
BIGQUERY_TABLE_FULL_ID = f"{PROJECT_ID}.{BIGQUERY_DATASET_ID}.{BIGQUERY_TABLE_ID}"

bq_client = bigquery.Client()
storage_client = storage.Client()

def _get_file_extension(file_name):
    parts = file_name.split('.')
    if len(parts) > 1:
        return parts[-1].lower()
    return ""

def _extract_text_from_pdf(blob):
    """Estrae testo da un PDF."""
    try:
        pdf_content = blob.download_as_bytes()
        pdf_reader = PyPDF2.PdfReader(io.BytesIO(pdf_content))
        text = ""
        for page in pdf_reader.pages:
            text += page.extract_text() or ""
        return text
    except Exception as e:
        print(f"Errore nell'estrazione del testo dal PDF: {e}")
        return ""

def _extract_image_metadata(blob):
    """Estrae metadati dalle immagini."""
    try:
        image_content = blob.download_as_bytes()
        image = Image.open(io.BytesIO(image_content))
        metadata = {
            "format": image.format,
            "size": image.size,
            "mode": image.mode,
        }
        if hasattr(image, "info"):
            metadata["exif"] = str(image.info)
        return metadata
    except Exception as e:
        print(f"Errore nell'estrazione dei metadati dell'immagine: {e}")
        return {}

def _analyze_content_for_tags(text, file_type):
    """Analizza il contenuto ed estrae tag rilevanti."""
    # Implementazione semplificata - in produzione usare NLP
    tags = []
    # Categorie comuni da identificare
    categories = {
        "finance": ["budget", "invoice", "cost", "price", "expense", "revenue", "profit", "tax", "investment", "loan", "credit", "debt"],
        "marketing": ["campaign", "customer", "lead", "conversion", "social media", "advertisement", "branding", "promotion", "SEO", "content", "engagement"],
        "human_resources": ["employee", "resume", "hiring", "contract", "payroll", "recruitment", "training", "benefits", "performance", "onboarding"],
        "technical": ["system", "software", "hardware", "bug", "feature", "update", "patch", "network", "database", "API", "infrastructure"],
        "research": ["study", "analysis", "experiment", "result", "hypothesis", "data", "survey", "publication", "discovery", "innovation", "theory"],
        "legal": ["contract", "agreement", "policy", "compliance", "law", "regulation", "rights", "liability", "dispute", "case", "court"],
        "education": ["course", "lesson", "student", "teacher", "curriculum", "exam", "assignment", "grade", "learning", "school", "university"],
        "healthcare": ["patient", "diagnosis", "treatment", "medicine", "hospital", "doctor", "nurse", "therapy", "health", "disease", "symptom"],
        "operations": ["logistics", "inventory", "supply", "procurement", "workflow", "efficiency", "process", "management", "delivery", "production"],
        "it": ["development", "coding", "programming", "deployment", "cloud", "security", "encryption", "backup", "monitoring", "virtualization"]
    }
    
    text_lower = text.lower()
    for category, keywords in categories.items():
        if any(keyword in text_lower for keyword in keywords):
            tags.append(category)
    
    # Aggiungi tag basati sul tipo di file
    if file_type:
        tags.append(file_type.lower())
    
    return list(set(tags))  # Rimuovi duplicati

def _guess_content_domain(file_path, content_type, extracted_text=""):
    """Indovina il dominio di contenuto in base a path e contenuto."""
    path_lower = file_path.lower()
    domain = "general"
    
    # Deduzione da path
    domain_paths = {
        "financial": ["finance", "accounting", "revenue", "cost", "budget"],
        "hr": ["human-resources", "hr", "personnel", "employee"],
        "marketing": ["marketing", "campaign", "social-media", "ads"],
        "operations": ["operations", "logistics", "inventory"],
        "it": ["it", "systems", "infrastructure", "development"],
        "research": ["research", "study", "analysis"]
    }
    
    for potential_domain, keywords in domain_paths.items():
        if any(keyword in path_lower for keyword in keywords):
            domain = potential_domain
            break
    
    # Raffina in base al contenuto se è testo
    if extracted_text and domain == "general":
        # Implementazione semplificata - in produzione usa NLP appropriato
        text_lower = extracted_text.lower()
        for potential_domain, keywords in domain_paths.items():
            if any(keyword in text_lower for keyword in keywords):
                domain = potential_domain
                break
    
    return domain

@functions_framework.cloud_event
def gcs_metadata_extractor(cloud_event):
    """
    Triggered by a change to a Cloud Storage bucket.
    Extracts metadata and stores it in BigQuery.
    """
    data = cloud_event.data
    bucket_name = data["bucket"]
    file_path_full = data["name"]

    print(f"Processing file: {file_path_full} from bucket: {bucket_name}")

    # Ignora cartelle
    if file_path_full.endswith('/'):
        print(f"Skipping folder object: {file_path_full}")
        return

    # Recupera il blob per analisi approfondita
    bucket = storage_client.bucket(bucket_name)
    blob = bucket.blob(file_path_full)
    
    file_name_only = os.path.basename(file_path_full)
    file_extension = _get_file_extension(file_name_only)
    gcs_uri = f"gs://{bucket_name}/{file_path_full}"
    content_type = data.get("contentType", "")
    
    # Gestione file non strutturati
    extracted_text = ""
    additional_metadata = {}
    content_tags = []
    
    # Estrazione testo e metadati in base al tipo di file
    if file_extension == "pdf":
        extracted_text = _extract_text_from_pdf(blob)
        additional_metadata["page_count"] = len(PyPDF2.PdfReader(io.BytesIO(blob.download_as_bytes())).pages)
    elif file_extension in ["jpg", "jpeg", "png", "gif", "bmp", "tiff"]:
        image_metadata = _extract_image_metadata(blob)
        additional_metadata.update(image_metadata)
    elif file_extension in ["docx", "doc", "xlsx", "xls", "pptx", "ppt", "txt", "csv", "json"]:
        # Per semplicità, scarichiamo il file solo se è di piccole dimensioni
        if int(data.get("size", 0)) < 10_000_000:  # 10MB limit
            content = blob.download_as_string().decode('utf-8', errors='ignore')
            extracted_text = content[:5000]  # Limita a 5000 caratteri per l'analisi
    
    # Estrai tag dal contenuto
    if extracted_text:
        content_tags = _analyze_content_for_tags(extracted_text, file_extension)
    
    # Determina il dominio dei dati
    data_domain = _guess_content_domain(file_path_full, content_type, extracted_text)
    
    additional_metadata_value_to_insert = json.dumps(additional_metadata) # CORRETTO
    print(f"FUNZIONE VERSIONE CON JSON.DUMPS - Type of additional_metadata_value_to_insert: {type(additional_metadata_value_to_insert)}")
    print(f"FUNZIONE VERSIONE CON JSON.DUMPS - Value: {additional_metadata_value_to_insert}")
    
    # Costruisci il record per BigQuery
    row_to_insert = {
        "file_gcs_uri": gcs_uri,
        "bucket_name": bucket_name,
        "file_path": file_path_full,
        "file_name": file_name_only,
        "file_extension": file_extension,
        "content_type": content_type,
        "file_size_bytes": int(data.get("size", 0)),
        "gcs_generation_id": str(data.get("generation", "")),
        "gcs_metageneration_id": str(data.get("metageneration", "")),
        "gcs_crc32c_hash": data.get("crc32c", ""),
        "gcs_md5_hash": data.get("md5Hash", ""),
        "event_time": data.get("timeCreated"),
        "metadata_ingestion_time": datetime.datetime.utcnow().isoformat(),
        "processing_status": "AVAILABLE_IN_BRONZE",
        "last_processed_by": "enhanced_metadata_extractor",
        "last_processing_notes": "Enhanced metadata extraction complete",
        "source_system": data.get("metadata", {}).get("source_system", "UPLOADED"),
        "data_domain": data_domain,
        "tags": content_tags,
        "has_text_content": bool(extracted_text),
        "additional_metadata": additional_metadata_value_to_insert
    }

    # Insert into BigQuery
    print(f"Attempting to insert row: {row_to_insert}")
    errors = bq_client.insert_rows_json(BIGQUERY_TABLE_FULL_ID, [row_to_insert])
    if errors == []:
        print(f"Enhanced metadata for {gcs_uri} successfully inserted into BigQuery.")
    else:
        print(f"Errors occurred while inserting metadata for {gcs_uri}: {errors}")