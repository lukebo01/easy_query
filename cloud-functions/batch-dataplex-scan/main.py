import os
import json
import traceback
from typing import List, Dict, Any, Optional
import functions_framework
from flask import Request
from google.cloud import dataplex_v1
import google.api_core.exceptions
from google.protobuf import field_mask_pb2

# --- CONFIGURAZIONE GLOBALE ---
DATAPLEX_LOCATION = "europe-central2"
LAKE_ID = "easyquery-lake"
ZONE_ID = "silver-zone"
ASSET_ID = "silver-layer"

@functions_framework.http
def batch_dataplex_scan(request: Request):
    """
    Funzione HTTP per avviare una scansione Dataplex su più file Silver.
    
    Formato della richiesta JSON:
    {
        "silver_files": ["gs://silver-layer-bucket/path/to/file1.parquet", "gs://silver-layer-bucket/path/to/file2.parquet"]
    }
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

    try:
        print("[DATAPLEX] Validating request...")
        
        # Validazione input
        if not request.is_json:
            return ({"status": "error", "error": "Invalid content type, expected application/json"}, 415, response_cors_headers)

        data_payload = request.get_json(silent=True)
        if data_payload is None:
             return ({"status": "error", "error": "Malformed JSON or empty request body"}, 400, response_cors_headers)
        
        silver_files = data_payload.get("silver_files", [])
        if not silver_files or not isinstance(silver_files, list):
            return ({"status": "error", "error": "Missing or invalid 'silver_files' parameter. Expected non-empty list."}, 400, response_cors_headers)
        
        # Identifica il project_id corrente
        project_id = os.environ.get("GCP_PROJECT") or os.environ.get("GOOGLE_CLOUD_PROJECT")
        if not project_id:
            print("ATTENZIONE: Impossibile determinare il project_id dagli env vars.")
            return ({"status": "error", "error": "Unable to determine project ID from environment variables."}, 500, response_cors_headers)
        
        print(f"[DATAPLEX] Starting discovery for {len(silver_files)} files in project {project_id}")
        
        # Avvia la scansione Dataplex
        try:
            success, result = trigger_dataplex_discovery(project_id, silver_files)
            
            if success:
                response_data = {
                    "status": "success",
                    "message": "Dataplex discovery scheduled for {0} files".format(len(silver_files)),
                    "details": {
                        "location": DATAPLEX_LOCATION,
                        "lake": LAKE_ID,
                        "zone": ZONE_ID,
                        "asset": ASSET_ID,
                        "file_count": len(silver_files)
                    }
                }
                print(f"Dataplex discovery result: {json.dumps(response_data)}")
                return (response_data, 200, response_cors_headers)
            else:
                if isinstance(result, dict) and result.get("error_type") == "quota_exceeded":
                    # Caso speciale per errore di quota
                    response_data = {
                        "status": "quota_exceeded",
                        "message": result.get("message", "Dataplex API quota exceeded"),
                        "details": result.get("details", "")
                    }
                    return (response_data, 429, response_cors_headers)
                else:
                    return ({"status": "error", "error": f"Failed to trigger Dataplex discovery: {result}"}, 500, response_cors_headers)
        
        except Exception as e:
            error_msg = str(e)
            print(f"[DATAPLEX] Error triggering discovery: {error_msg}")
            traceback.print_exc()
            return ({"status": "error", "error": error_msg, "details": traceback.format_exc()}, 500, response_cors_headers)
        
    except Exception as e:
        error_msg = str(e)
        print(f"[DATAPLEX] Unhandled error: {error_msg}")
        traceback.print_exc()
        return ({"status": "error", "error": error_msg, "details": traceback.format_exc()}, 500, response_cors_headers)

def trigger_dataplex_discovery(project_id: str, silver_file_paths: List[str]) -> (bool, Any):
    """
    Tenta di forzare una discovery run per un asset specifico aggiornando
    la sua discovery_spec.schedule con un cron valido alternato.

    Args:
        project_id: L'ID del progetto GCP.
        silver_file_paths: Lista di percorsi file Silver da scansionare.
        
    Returns:
        Tuple[bool, Any]: (successo, messaggio o dettagli errore)
    """
    print(f"[DATAPLEX] Triggering discovery for asset: {ASSET_ID}")
    client = dataplex_v1.DataplexServiceClient()
    asset_name = client.asset_path(project_id, DATAPLEX_LOCATION, LAKE_ID, ZONE_ID, ASSET_ID)

    try:
        asset = client.get_asset(name=asset_name)
        current_schedule_str = asset.discovery_spec.schedule
        print(f"[DATAPLEX] Current discovery schedule: '{current_schedule_str}'")

        # Definisci due stringhe cron VALIDE e leggermente diverse
        cron_schedule1 = "0 * * * *"
        cron_schedule2 = "5 * * * *"

        # Alterna tra i due cron per forzare un cambiamento
        if current_schedule_str == cron_schedule1:
            new_schedule_str = cron_schedule2
        else:
            new_schedule_str = cron_schedule1
        
        print(f"[DATAPLEX] Setting new discovery schedule to: '{new_schedule_str}'")

        # Prepara l'oggetto Asset per l'aggiornamento
        asset_update_payload = dataplex_v1.Asset()
        asset_update_payload.name = asset_name
        asset_update_payload.discovery_spec.schedule = new_schedule_str
        
        # Costruisci la maschera di aggiornamento
        update_mask = field_mask_pb2.FieldMask(paths=["discovery_spec.schedule"])

        operation = client.update_asset(
            asset=asset_update_payload,
            update_mask=update_mask
        )
        print(f"[DATAPLEX] UpdateAsset operation started: {operation.operation.name}")
        
        # Attendi il completamento dell'operazione
        result = operation.result(timeout=120)
        print(f"[DATAPLEX] UpdateAsset operation completed. Discovery scheduled.")
        
        # Per questa funzione non facciamo polling completo che richiederebbe troppo tempo
        # La discovery è stata avviata e continuerà in background
        return True, {
            "message": "Discovery scheduled successfully",
            "new_schedule": new_schedule_str
        }

    except google.api_core.exceptions.ResourceExhausted as e:
        # Gestione specifica per errori di quota (429)
        error_msg = f"Quota exceeded error: {e}"
        print(f"[DATAPLEX] {error_msg}")
        return False, {
            "error_type": "quota_exceeded",
            "message": "Dataplex API quota exceeded. Tables will be created when quota resets.",
            "details": str(e)
        }
    except Exception as e:
        error_msg = f"Error: {e}"
        print(f"[DATAPLEX] {error_msg}")
        traceback.print_exc()
        return False, error_msg
