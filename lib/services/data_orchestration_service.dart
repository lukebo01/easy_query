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
    List<Map<String, dynamic>> initialSchemas, // Schemi delle tabelle BQ esistenti
    List<String> initialTableNames, // Nomi completi delle tabelle BQ esistenti
    Map<String, List<Map<String, dynamic>>> initialSampleData, // Dati campione per tabelle BQ
    List<Map<String, dynamic>> bronzeMetadata, // Metadati dei file nel bucket Bronze
  ) async {
    dev.log("Starting data orchestration for user question: \"$userQuestion\"");

    try {
      // 1. Analisi del contesto tramite Gemini per identificare file bronze da trasformare
      dev.log("Analyzing query context with Gemini to determine if transformations are needed...");
      final contextAnalysis = await _geminiService.analyzeQueryContext(
        userQuestion,
        jsonEncode(initialSchemas),
        jsonEncode(bronzeMetadata),
        initialTableNames,
        initialSampleData,
      );
      dev.log("Gemini context analysis received: ${jsonEncode(contextAnalysis)}");
      
      // Inizializza le liste che verranno aggiornate
      List<String> transformedSilverFileUris = [];
      List<Map<String, dynamic>> finalSchemas = List<Map<String, dynamic>>.from(initialSchemas);
      List<String> finalTableNames = List<String>.from(initialTableNames);
      
      // 2. Trasformazione Bronze → Silver se suggerita da Gemini
      // Gemini dovrebbe restituire una lista di stringhe (URI GCS) in contextAnalysis['suggested_files']
      final List<dynamic>? suggestedFilesRaw = contextAnalysis['suggested_files'] as List<dynamic>?;
      final List<String> filesToTransformBronze = suggestedFilesRaw?.map((e) => e.toString()).toList() ?? [];

      if (filesToTransformBronze.isNotEmpty) {
        dev.log("Gemini suggested files for Bronze-to-Silver transformation: $filesToTransformBronze");
        
        for (String bronzeFileGcsUri in filesToTransformBronze) {
          dev.log("Processing Bronze file for Silver transformation: $bronzeFileGcsUri");
          final silverTransformResult = await _transformBronzeToSilver(bronzeFileGcsUri); // Chiamata alla funzione HTTP
          
          if (silverTransformResult != null && silverTransformResult['status'] == 'success') {
            final String? silverPathUri = silverTransformResult['silver_path'] as String?;
            
            if (silverPathUri != null && silverPathUri.isNotEmpty) {
              dev.log("Bronze file $bronzeFileGcsUri transformed/found at Silver path: $silverPathUri");
              transformedSilverFileUris.add(silverPathUri);
              
              // Costruisci il nome della tabella BigQuery per il file Silver
              // Assumendo che il file Silver sia un Parquet e che il nome della tabella BQ
              // derivi dal nome del file Parquet senza estensione, nel dataset "silver_zone".
              // Esempio: gs://silver-bucket/path/myfile.parquet -> progetto.silver_zone.myfile
              try {
                final uriParts = Uri.parse(silverPathUri).pathSegments; // Es: [silver-bucket, path, myfile.parquet]
                if (uriParts.isNotEmpty) {
                  final silverFileNameWithExt = uriParts.last;
                  final silverFileNameNoExt = silverFileNameWithExt.replaceAll('.parquet', '');
                  
                  // VERIFICA E CORREGGI QUESTO DATASET ID SE NECESSARIO
                  const String silverDatasetId = "silver_zone"; 
                  final String newSilverTableName = "${_bigQueryService.projectId}.$silverDatasetId.$silverFileNameNoExt";
                  
                  if (!finalTableNames.contains(newSilverTableName)) {
                    finalTableNames.add(newSilverTableName);
                    dev.log("Added new Silver table to context: $newSilverTableName");
                  }

                  // Aggiungi/Aggiorna lo schema per questa nuova tabella Silver
                  // La risposta dalla CF Python dovrebbe contenere 'columns' se il file è stato appena processato.
                  if (silverTransformResult['columns'] != null && silverTransformResult['columns'] is List) {
                    final List<dynamic> columnsRaw = silverTransformResult['columns'] as List<dynamic>;
                    if (columnsRaw.isNotEmpty) {
                      final List<Map<String, String>> schemaFields = columnsRaw.map((col) {
                        final String columnName = col.toString(); // Assicura che sia una stringa
                        return {
                          "name": columnName,
                          "type": "STRING", // Semplificato: idealmente, dovresti derivare il tipo
                          "mode": "NULLABLE"
                        };
                      }).toList();

                      if (schemaFields.isNotEmpty) {
                        // Rimuovi schema precedente se esisteva per questa tabella (per aggiornamento)
                        finalSchemas.removeWhere((schema) =>
                            schema['tableReference']?['tableId'] == silverFileNameNoExt &&
                            schema['tableReference']?['datasetId'] == silverDatasetId);
                        
                        finalSchemas.add({
                          "tableReference": {
                            "projectId": _bigQueryService.projectId,
                            "datasetId": silverDatasetId,
                            "tableId": silverFileNameNoExt
                          },
                          "schema": {
                            "fields": schemaFields
                          }
                        });
                        dev.log("Added/Updated schema for Silver table: $newSilverTableName with ${schemaFields.length} columns.");
                      }
                      else {
                        dev.log("Info: 'columns' field was an empty list for $silverPathUri. Schema not added/updated for this run.");
                      }
                    } else {
                      dev.log("Info: 'columns' field was an empty list for $silverPathUri. Schema not added/updated.");
                    }
                  } else {
                    dev.log("Info: 'columns' field not found or not a List in response for $silverPathUri (file might have been 'already processed' or processing failed to return columns). Schema not added/updated for this run. You might need to fetch schema separately if this table is new to the context.");
                    // TODO: Se questa tabella silver è nuova al contesto e le colonne non sono state fornite,
                    // potresti voler provare a interrogare `INFORMATION_SCHEMA.COLUMNS` di BigQuery per il suo schema
                    // o leggere i metadati del file Parquet da GCS, se assolutamente necessario qui.
                  }
                }
              } catch (e, stackTrace) {
                dev.log("Error processing silver path or schema for $silverPathUri: $e", error: e, stackTrace: stackTrace, level: 900);
              }
            } else {
              dev.log('Warning: Bronze-to-Silver success response for $bronzeFileGcsUri missing valid "silver_path". Result: $silverTransformResult', level: 900);
            }
          } else {
            dev.log('Warning: Bronze-to-Silver transformation failed or status was not "success" for $bronzeFileGcsUri. Result: $silverTransformResult', level: 900);
          }
        }
      } else {
        dev.log("No Bronze files suggested for transformation by Gemini.");
      }
      
      // 3. Analizza se è necessaria un'ottimizzazione Silver → Gold (opzionale)
      if (transformedSilverFileUris.isNotEmpty) { // O basati su una logica più complessa se ottimizzare anche tabelle silver non appena trasformate
        dev.log("Analyzing if Gold optimization is needed for Silver files/tables: $transformedSilverFileUris");
        final optimizationNeeded = await _shouldOptimizeForGold(
          userQuestion, 
          transformedSilverFileUris, // Passa gli URI GCS dei file Silver, o i nomi delle tabelle BQ Silver
          finalTableNames, // Includi i nomi delle nuove tabelle Silver
          finalSchemas // Includi i nuovi schemi Silver
        );
        
        if (optimizationNeeded['optimize'] == true) { // Controllo esplicito per booleano
          dev.log("Gold optimization recommended: ${optimizationNeeded['reason']}");
          
          final goldResult = await _transformSilverToGold(
            transformedSilverFileUris, // O i nomi delle tabelle Silver
            optimizationNeeded['optimization_type'] as String? ?? 'default_optimization',
            optimizationNeeded['params'] as Map<String, dynamic>? ?? {},
            optimizationNeeded['output_name'] as String? ?? 'optimized_gold_table'
          );
          
          if (goldResult != null && goldResult['status'] == 'success') {
            dev.log("Gold optimization completed. Output path: ${goldResult['output_path']}, BigQuery table: ${goldResult['bigquery_table']}");
            
            final String? goldBqTableFullName = goldResult['bigquery_table'] as String?;
            if (goldBqTableFullName != null && goldBqTableFullName.isNotEmpty) {
              if (!finalTableNames.contains(goldBqTableFullName)) {
                finalTableNames.add(goldBqTableFullName);
              }

              // Aggiungi/Aggiorna schema della tabella Gold
              if (goldResult['columns'] != null && goldResult['columns'] is List) {
                final List<dynamic> goldColumnsRaw = goldResult['columns'] as List<dynamic>;
                final List<Map<String, String>> goldSchemaFields = goldColumnsRaw.map((col) {
                  final String columnName = col.toString();
                  return {
                    "name": columnName,
                    "type": "STRING", // Semplificato
                    "mode": "NULLABLE"
                  };
                }).toList();

                if (goldSchemaFields.isNotEmpty) {
                   final goldTableParts = goldBqTableFullName.split('.');
                   final String goldProjectId = goldTableParts.length > 2 ? goldTableParts[0] : _bigQueryService.projectId;
                   final String goldDatasetId = goldTableParts.length > 2 ? goldTableParts[1] : "gold_layer_dataset"; // Assumi un dataset di default
                   final String goldTableId = goldTableParts.last;

                  finalSchemas.removeWhere((schema) =>
                      schema['tableReference']?['tableId'] == goldTableId &&
                      schema['tableReference']?['datasetId'] == goldDatasetId);

                  finalSchemas.add({
                    "tableReference": {
                      "projectId": goldProjectId,
                      "datasetId": goldDatasetId, 
                      "tableId": goldTableId
                    },
                    "schema": {
                      "fields": goldSchemaFields
                    }
                  });
                  dev.log("Added/Updated schema for Gold table: $goldBqTableFullName");
                }
              } else {
                 dev.log("Info: Gold transformation response for $goldBqTableFullName did not contain column information. Schema not added/updated for this run.");
              }
            }
          } else {
            dev.log("Gold optimization step was recommended but failed or did not return success. Result: $goldResult", level: 900);
          }
        } else {
          dev.log("No Gold optimization needed or suggested for this query.");
        }
      }
      
      // 4. Restituisci il contesto aggiornato (nuovi schemi, nuovi nomi di tabelle)
      //    e il risultato dell'analisi iniziale di Gemini.
      dev.log("Data orchestration complete. Returning updated context.");
      dev.log("Final Schemas Count: ${finalSchemas.length}");
      dev.log("Final Table Names: $finalTableNames");

      return {
        'contextAnalysis': contextAnalysis, // L'analisi originale di Gemini sui file bronze
        'updatedSchemas': finalSchemas,     // Gli schemi, potenzialmente con nuove tabelle Silver/Gold
        'updatedTableNames': finalTableNames, // I nomi delle tabelle, potenzialmente con nuove Silver/Gold
        'transformedSilverFileUris': transformedSilverFileUris // Gli URI dei file Silver processati
      };

    } catch (e, stackTrace) {
      dev.log("Critical error in data orchestration pipeline: $e", error: e, stackTrace: stackTrace, level: 1200);
      // In caso di errore critico, restituisci il contesto iniziale per permettere almeno una query base
      // o solleva un'eccezione più specifica se preferisci che l'intero processo fallisca.
      // throw Exception("Failed to orchestrate data after multiple steps: $e");
      return {
        'contextAnalysis': {'error': 'Orchestration failed: $e'},
        'updatedSchemas': initialSchemas,
        'updatedTableNames': initialTableNames,
        'transformedSilverFileUris': <String>[]
      };
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
      Analyze the user query, available Silver files/tables, and their schemas to determine if a Gold optimization is necessary.

      User query: $userQuestion
      
      Available Silver files/tables (these are the inputs for potential optimization): ${jsonEncode(silverFiles)}
      
      All available BigQuery tables in the current context (including Silver tables): ${jsonEncode(tableNames)}
      
      Schemas of available BigQuery tables: ${jsonEncode(schemas)}
      
      Consider the following optimization types: 'aggregate', 'join', 'filter', 'denormalize'.

      Determine and respond EXCLUSIVELY in JSON format with the following structure:
      {
        "optimize": true_or_false, // Boolean: Is a Gold optimization necessary?
        "optimization_type": "type_string", // String: one of 'aggregate', 'join', 'filter', 'denormalize', or 'none' if optimize is false.
        "params": {
          // Specific parameters for the optimization type. Examples:
          // For "aggregate": {"group_by": ["col1", "col2"], "aggregations": {"col3_sum": "sum", "col4_avg": "mean"}}
          // For "join": {"on": "common_id_column", "how": "inner"} 
          //             or {"join_instructions": [{"left_df_index": 0, "right_df_index": 1, "left_on": "colA", "right_on": "colB", "how": "inner"}]}
          // For "filter": {"conditions": [{"column": "column_name", "operator": "pandas_operator", "value": "value_to_filter_by"}, ...]} 
          //               (Valid Pandas operators for .query() or boolean indexing: ==, !=, >, >=, <, <=, 'in', 'notin'. 
          //                For 'contains', 'startswith', 'endswith', 'isnull', 'isnotnull', the Python logic will handle them).
          // For "denormalize": {"join_maps": [{"left_on": "id", "right_on": "fk_id", "how": "left"}, ...]}
        },
        "output_name": "suggested_gold_table_name_prefix", // String: a descriptive prefix for the resulting Gold table (without hash or extensions)
        "reason": "brief_explanation_for_your_decision" // String: a brief rationale
      }

      If the optimization_type is 'filter', the "value" field in "conditions" can be a string, a number, a boolean, or a list of values (for 'in' or 'notin' operators).
      If "optimize" is false, the other fields can be null or default/empty strings.
      Prioritize optimizations that significantly reduce the amount of data scanned or simplify complex queries related to the user's question.
      If the necessary data is already well-structured and focused in an existing Silver table, optimization might not be needed.
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