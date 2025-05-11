import 'dart:convert';
import 'dart:developer' as dev;
import 'package:http/http.dart' as http;
import 'package:easy_query/services/gemini_flash_service.dart';
import 'package:easy_query/services/big_query_service.dart';
import 'package:easy_query/services/cloud_storage_service.dart';

/// Servizio che orchestera le trasformazioni dei dati tramite LLM
class DataOrchestrationService {
  final GeminiFlashService _geminiService;
  final BigQueryService _bigQueryService;
  final CloudStorageService _cloudStorageService;
  
  // URL delle Cloud Functions
  final String _bronzeToSilverUrl;
  final String _silverToGoldUrl;
  
  DataOrchestrationService({
    required GeminiFlashService geminiService,
    required BigQueryService bigQueryService,
    required CloudStorageService cloudStorageService,
    required String bronzeToSilverUrl,
    required String silverToGoldUrl,
  }) : 
    _geminiService = geminiService,
    _bigQueryService = bigQueryService,
    _cloudStorageService = cloudStorageService,
    _bronzeToSilverUrl = bronzeToSilverUrl,
    _silverToGoldUrl = silverToGoldUrl;
  
  /// Analizza la query utente e decide se è necessario eseguire trasformazioni
  Future<Map<String, dynamic>> analyzeQueryAndPrepareData(
    String userQuestion,
    List<Map<String, dynamic>> schemas,
    List<String> tableNames,
    Map<String, List<Map<String, dynamic>>> sampleData,
    List<Map<String, dynamic>> bronzeMetadata,
  ) async {
    try {
      // 1. Analisi del contesto tramite Gemini
      dev.log("Analyzing query context to determine if transformations are needed");
      final contextAnalysis = await _geminiService.analyzeQueryContext(
        userQuestion,
        jsonEncode(schemas),
        jsonEncode(bronzeMetadata),
        tableNames,
        sampleData,
      );
      
      // 2. Verifica se sono suggeriti file Bronze da trasformare
      List<String> transformedFiles = [];
      List<Map<String, dynamic>> newSchemas = [...schemas];
      List<String> updatedTableNames = [...tableNames];
      
      if (contextAnalysis['suggested_files'] != null && 
          contextAnalysis['suggested_files'].isNotEmpty) {
        dev.log("Found files to transform: ${contextAnalysis['suggested_files']}");
        
        // Esegui le trasformazioni Bronze → Silver
        for (String filePath in contextAnalysis['suggested_files']) {
          final result = await _transformBronzeToSilver(filePath);
          if (result != null) {
            transformedFiles.add(result['silver_path']);
            
            // Ottieni schema del nuovo file Silver convertito
            // (simuliamo uno schema per semplicità)
            final newTableName = "${_bigQueryService.projectId}.silver.${result['silver_path'].split('/').last.replaceAll('.parquet', '')}";
            updatedTableNames.add(newTableName);
            
            // Aggiungi uno schema semplificato
            final columns = result['columns'] as List<dynamic>;
            final schemaFields = columns.map((col) => {
              "name": col,
              "type": "STRING", // Semplificato - in realtà dovresti rilevare il tipo
              "mode": "NULLABLE"
            }).toList();
            
            newSchemas.add({
              "tableReference": {
                "projectId": _bigQueryService.projectId,
                "datasetId": "silver",
                "tableId": result['silver_path'].split('/').last.replaceAll('.parquet', '')
              },
              "schema": {
                "fields": schemaFields
              }
            });
          }
        }
      }
      
      // 3. Analizza se è necessario ottimizzare in Gold
      if (transformedFiles.isNotEmpty) {
        dev.log("Analyzing if Gold optimization is needed for transformed files");
        final optimizationNeeded = await _shouldOptimizeForGold(
          userQuestion, 
          transformedFiles,
          updatedTableNames,
          newSchemas
        );
        
        if (optimizationNeeded['optimize']) {
          dev.log("Gold optimization recommended: ${optimizationNeeded['reason']}");
          
          // Esegui l'ottimizzazione Silver → Gold
          final goldResult = await _transformSilverToGold(
            transformedFiles,
            optimizationNeeded['optimization_type'],
            optimizationNeeded['params'],
            optimizationNeeded['output_name']
          );
          
          if (goldResult != null) {
            dev.log("Gold optimization completed: ${goldResult['output_path']}");
            // Aggiungi la tabella Gold all'elenco delle tabelle disponibili
            if (goldResult['bigquery_table'] != null) {
              updatedTableNames.add(goldResult['bigquery_table']);
              
              // Aggiungi schema della tabella Gold
              final goldColumns = goldResult['columns'] as List<dynamic>;
              final goldSchemaFields = goldColumns.map((col) => {
                "name": col,
                "type": "STRING", // Semplificato
                "mode": "NULLABLE"
              }).toList();
              
              newSchemas.add({
                "tableReference": {
                  "projectId": _bigQueryService.projectId,
                  "datasetId": "gold_optimized",
                  "tableId": goldResult['bigquery_table'].split('.').last
                },
                "schema": {
                  "fields": goldSchemaFields
                }
              });
            }
          }
        }
      }
      
      // 4. Restituisci contesto aggiornato
      return {
        'contextAnalysis': contextAnalysis,
        'updatedSchemas': newSchemas,
        'updatedTableNames': updatedTableNames,
        'transformedFiles': transformedFiles
      };
    } catch (e) {
      dev.log("Error in data orchestration: $e", error: e);
      throw Exception("Failed to orchestrate data: $e");
    }
  }
  
  /// Chiede al LLM se è necessario ottimizzare in Gold
  Future<Map<String, dynamic>> _shouldOptimizeForGold(
    String userQuestion,
    List<String> silverFiles,
    List<String> tableNames,
    List<Map<String, dynamic>> schemas
  ) async {
    final prompt = '''
      Analizza questa query utente e i file Silver disponibili per determinare se è necessaria un'ottimizzazione Gold.

      Query utente: $userQuestion
      
      File Silver disponibili: ${jsonEncode(silverFiles)}
      
      Tabelle disponibili: ${jsonEncode(tableNames)}
      
      Schemi: ${jsonEncode(schemas)}
      
      Determina:
      1. Se è necessaria un'ottimizzazione Gold (rispondi 'true' o 'false')
      2. Quale tipo di ottimizzazione sarebbe più efficace (aggregate, join, filter, denormalize)
      3. I parametri specifici per l'ottimizzazione
      4. Un nome appropriato per la tabella ottimizzata
      5. La motivazione della tua decisione
      
      Rispondi SOLO in formato JSON: 
      {
        "optimize": true/false,
        "optimization_type": "tipo",
        "params": {parametri specifici},
        "output_name": "nome",
        "reason": "motivazione"
      }
    ''';
    
    final response = await _geminiService.generateText(prompt);
    
    try {
      // Estrai il JSON dalla risposta
      final jsonStartIndex = response.indexOf('{');
      final jsonEndIndex = response.lastIndexOf('}') + 1;
      
      if (jsonStartIndex >= 0 && jsonEndIndex > jsonStartIndex) {
        final jsonStr = response.substring(jsonStartIndex, jsonEndIndex);
        return jsonDecode(jsonStr);
      }
      
      // Fallback se non viene trovato JSON valido
      return {"optimize": false, "reason": "No valid optimization suggested by AI"};
    } catch (e) {
      dev.log("Error parsing optimization suggestion: $e");
      return {"optimize": false, "reason": "Error analyzing optimization needs"};
    }
  }
  
  /// Trasforma un file Bronze in Silver
  Future<Map<String, dynamic>?> _transformBronzeToSilver(String fileGcsUri) async {
    dev.log('Attempting Bronze to Silver transformation for input GCS URI: "$fileGcsUri"');

    String processedPath = fileGcsUri;

    // 1. Rimuovi il prefisso 'gs://' se presente
    if (processedPath.startsWith('gs://')) {
      processedPath = processedPath.substring(5);
    } else {
      dev.log(
        'Warning: Input file path "$fileGcsUri" does not start with "gs://". Assuming it is already in "bucket/object" format.',
        level: 800,
      );
    }

    // 2. Normalizza il path per rimuovere doppi slash e slash iniziali/finali dalla parte dell'oggetto
    //    Esempio: "bucket//path/to//file.txt/" -> "bucket/path/to/file.txt"
    List<String> parts = processedPath.split('/');
    if (parts.isEmpty) {
      dev.log(
        'Error: Processed path "$processedPath" is empty after splitting by "/".',
        level: 1000, error: 'Invalid GCS path format.',
      );
      return null;
    }

    String bucketName = parts.first; // Il primo elemento dovrebbe essere il nome del bucket
    List<String> objectPathSegments = parts.sublist(1).where((segment) => segment.isNotEmpty).toList(); // Rimuove segmenti vuoti (da //)
    String objectPath = objectPathSegments.join('/'); // Ricostruisce il path dell'oggetto

    // Il path finale da inviare alla Cloud Function
    String pathForCloudFunction = '$bucketName/$objectPath';
    
    // Se objectPath era vuoto (es. input era "gs://bucket" o "gs://bucket/"),
    // allora pathForCloudFunction sarà "bucket/" che è invalido per un file.
    // La funzione Python dovrebbe comunque gestire un blob_name vuoto.
    if (objectPath.isEmpty && parts.length > 1) { // parts.length > 1 per input come "bucket/"
         dev.log(
            'Warning: Object path is empty for GCS URI "$fileGcsUri". Resulting path for CF: "$pathForCloudFunction"',
            level: 800,
        );
        // Potresti voler restituire null qui se un path di oggetto vuoto non è mai valido
        // return null;
    } else if (objectPath.isEmpty && parts.length <=1) { // input era solo "bucket" o ""
         dev.log(
            'Error: Path "$fileGcsUri" does not seem to contain a valid object path after bucket.',
            level: 1000, error: 'Invalid GCS path format.',
        );
        return null;
    }


    dev.log('Calling bronze-to-silver Cloud Function with payload path: "$pathForCloudFunction"');

    try {
      final response = await http.post(
        Uri.parse(_bronzeToSilverUrl),
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
        },
        body: jsonEncode({
          'path': pathForCloudFunction,
          'force_processing': false,
          'delete_original': false,
        }),
      );

      dev.log('Bronze-to-Silver CF Response Status: ${response.statusCode}');
      dev.log('Bronze-to-Silver CF Response Body: ${response.body}');

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          if (response.body.isNotEmpty) {
            return jsonDecode(response.body) as Map<String, dynamic>;
          } else {
            dev.log('Bronze-to-Silver CF returned a 2xx status but with an empty body.', level: 800);
            return {'status': 'success', 'message': 'Operation successful with empty response body'};
          }
        } catch (e, stackTrace) {
          dev.log('Error decoding JSON response from Bronze-to-Silver CF: $e', error: e, stackTrace: stackTrace, level: 1000);
          return null;
        }
      } else {
        dev.log('Error response from Bronze-to-Silver CF: ${response.statusCode} - ${response.body}', level: 1000);
        return null;
      }
    } catch (e, stackTrace) {
      dev.log('Exception during HTTP call to Bronze-to-Silver CF: $e', error: e, stackTrace: stackTrace, level: 1000);
      return null;
    }
  }
  
  /// Trasforma dati Silver in Gold
  Future<Map<String, dynamic>?> _transformSilverToGold(
    List<String> silverFiles,
    String optimizationType,
    Map<String, dynamic> params,
    String outputName
  ) async {
    try {
      final response = await http.post(
        Uri.parse(_silverToGoldUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'files': silverFiles,
          'optimization_type': optimizationType,
          'optimization_params': params,
          'output_name': outputName,
          'description': 'Automatic optimization triggered by query: ${DateTime.now()}',
          'create_bq_table': true
        }),
      );
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        dev.log("Error transforming Silver to Gold: ${response.body}");
        return null;
      }
    } catch (e) {
      dev.log("Exception in Silver to Gold transformation: $e");
      return null;
    }
  }
}