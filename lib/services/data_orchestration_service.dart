import 'dart:convert';
import 'dart:developer' as dev;
import 'package:http/http.dart' as http;
import 'package:easy_query/services/gemini_flash_service.dart';
import 'package:easy_query/services/big_query_service.dart';
import 'package:easy_query/services/cloud_storage_service.dart';
import 'dart:async';

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
      final List<dynamic>? suggestedFilesRaw = contextAnalysis['suggested_files'] as List<dynamic>?;
      final List<String> filesToTransformBronze = suggestedFilesRaw?.map((e) => e.toString()).toList() ?? [];

      if (filesToTransformBronze.isNotEmpty) {
        dev.log("Gemini suggested files for Bronze-to-Silver transformation: $filesToTransformBronze");

        for (String bronzeFileGcsUri in filesToTransformBronze) {
          dev.log("Processing Bronze file for Silver transformation: $bronzeFileGcsUri");
          final silverTransformResult = await _transformBronzeToSilver(bronzeFileGcsUri);

          if (silverTransformResult != null && silverTransformResult['status'] == 'success') {
            final String? silverPathUri = silverTransformResult['silver_path'] as String?;

            if (silverPathUri != null && silverPathUri.isNotEmpty) {
              dev.log("Bronze file $bronzeFileGcsUri transformed/found at Silver path: $silverPathUri");
              transformedSilverFileUris.add(silverPathUri);

              final String? bigQueryTableName = silverTransformResult['bigquery_table'] as String?;
              String silverFileNameNoExt = ''; // Per fallback

              if (bigQueryTableName != null && bigQueryTableName.isNotEmpty) {
                if (!finalTableNames.contains(bigQueryTableName)) {
                  finalTableNames.add(bigQueryTableName);
                  dev.log("Added new Silver external table to context: $bigQueryTableName");
                }
                // Estrai tableId per rimozione schema
                final tableNamePartsForId = bigQueryTableName.split('.');
                silverFileNameNoExt = tableNamePartsForId.last;

              } else {
                 // Fallback per derivare il nome della tabella se non fornito
                try {
                  final uriParts = Uri.parse(silverPathUri).pathSegments;
                  if (uriParts.isNotEmpty) {
                    final silverFileNameWithExt = uriParts.last;
                    silverFileNameNoExt = silverFileNameWithExt.replaceAll('.parquet', '');
                    const String silverDatasetIdFallback = "silver_zone";
                    final String newSilverTableNameFallback = "${_bigQueryService.projectId}.$silverDatasetIdFallback.$silverFileNameNoExt";
                    if (!finalTableNames.contains(newSilverTableNameFallback)) {
                      finalTableNames.add(newSilverTableNameFallback);
                      dev.log("Added new Silver table to context (fallback naming): $newSilverTableNameFallback");
                    }
                  }
                } catch (e) {
                  dev.log("Error in fallback table naming for $silverPathUri: $e");
                }
              }

              // Gestione dello schema con i TIPI ricevuti dalla CF
              if (silverTransformResult['columns'] != null && silverTransformResult['columns'] is List) {
                final List<dynamic> columnsRaw = silverTransformResult['columns'] as List<dynamic>;
                if (columnsRaw.isNotEmpty) {
                  // *** INIZIO MODIFICA: Gestione schemaFields con tipi ***
                  final List<Map<String, String>> schemaFields = columnsRaw.map((colInfoRaw) {
                    final Map<String, dynamic> colInfo = colInfoRaw as Map<String, dynamic>;
                    final String columnName = colInfo['name'] as String;
                    final String columnType = colInfo['type'] as String; // Tipo BQ da CF Python
                    return {
                      "name": columnName,
                      "type": columnType, // Usa direttamente il tipo fornito dalla CF
                      "mode": "NULLABLE"
                    };
                  }).toList();
                  // *** FINE MODIFICA ***

                  if (schemaFields.isNotEmpty) {
                    String datasetIdForSchema = "silver_zone"; // Default
                    String tableIdForSchema = silverFileNameNoExt; // Derivato sopra

                    if (bigQueryTableName != null && bigQueryTableName.isNotEmpty) {
                        final parts = bigQueryTableName.split('.');
                        if (parts.length == 3) {
                           datasetIdForSchema = parts[1];
                           tableIdForSchema = parts[2];
                        }
                    }

                    finalSchemas.removeWhere((schema) =>
                        schema['tableReference']?['tableId'] == tableIdForSchema &&
                        schema['tableReference']?['datasetId'] == datasetIdForSchema);

                    finalSchemas.add({
                      "tableReference": {
                        "projectId": _bigQueryService.projectId, // o projectId estratto da bigQueryTableName
                        "datasetId": datasetIdForSchema,
                        "tableId": tableIdForSchema
                      },
                      "schema": { // Struttura corretta per schema BQ
                        "fields": schemaFields
                      }
                    });
                    dev.log("Added/Updated schema for Silver table: ${_bigQueryService.projectId}.$datasetIdForSchema.$tableIdForSchema with ${schemaFields.length} columns based on types from CF.");
                  }
                }
              } else {
                dev.log("Info: 'columns' field not found or not a List in response for $silverPathUri. Schema not added/updated for this run.");
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

      /*
      // 3. Analizza se è necessaria un'ottimizzazione Silver → Gold (opzionale)
      if (transformedSilverFileUris.isNotEmpty) {
        dev.log("Analyzing if Gold optimization is needed for Silver files/tables: $transformedSilverFileUris");
        final optimizationNeeded = await _shouldOptimizeForGold(
          userQuestion,
          transformedSilverFileUris,
          finalTableNames,
          finalSchemas
        );

        if (optimizationNeeded['optimize'] == true) {
          dev.log("Gold optimization recommended: ${optimizationNeeded['reason']}");

          final goldResult = await _transformSilverToGold(
            transformedSilverFileUris,
            optimizationNeeded['optimization_type'] as String? ?? 'default_optimization',
            optimizationNeeded['params'] as Map<String, dynamic>? ?? {},
            optimizationNeeded['output_name'] as String? ?? 'optimized_gold_table'
          );

          if (goldResult != null && goldResult['status'] == 'success') {
            dev.log("Gold optimization completed. Output path: ${goldResult['gold_output_gcs_uri']}, BigQuery table: ${goldResult['gold_bigquery_table']}");

            final String? goldBqTableFullName = goldResult['gold_bigquery_table'] as String?;
            if (goldBqTableFullName != null && goldBqTableFullName.isNotEmpty) {
              if (!finalTableNames.contains(goldBqTableFullName)) {
                finalTableNames.add(goldBqTableFullName);
              }

              // Aggiungi/Aggiorna schema della tabella Gold
              if (goldResult['gold_df_columns'] != null && goldResult['gold_df_columns'] is List) {
                // La CF silver-to-gold ora dovrebbe restituire "gold_df_columns" come List<Map{"name": "col", "type": "BQ_TYPE"}>
                final List<dynamic> goldColumnsRaw = goldResult['gold_df_columns'] as List<dynamic>;

                // *** INIZIO MODIFICA: Gestione schemaFields con tipi per Gold ***
                final List<Map<String, String>> goldSchemaFields = goldColumnsRaw.map((colInfoRaw) {
                  final Map<String, dynamic> colInfo = colInfoRaw as Map<String, dynamic>; // colInfo è Map<String, dynamic>
                  final String columnName = colInfo['name'] as String;
                  final String columnType = colInfo['type'] as String; // Tipo BQ da CF Python
                  return {
                    "name": columnName,
                    "type": columnType,
                    "mode": "NULLABLE"
                  };
                }).toList();
                // *** FINE MODIFICA ***

                if (goldSchemaFields.isNotEmpty) {
                   final goldTableParts = goldBqTableFullName.split('.');
                   final String goldProjectId = goldTableParts.length > 2 ? goldTableParts[0] : _bigQueryService.projectId;
                   final String goldDatasetId = goldTableParts.length > 2 ? goldTableParts[1] : "gold_layer_dataset";
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
                    "schema": { // Struttura corretta per schema BQ
                      "fields": goldSchemaFields
                    }
                  });
                  dev.log("Added/Updated schema for Gold table: $goldBqTableFullName based on types from CF.");
                }
              } else {
                 dev.log("Info: Gold transformation response for $goldBqTableFullName did not contain 'gold_df_columns' or it was not a list. Schema not added/updated for this run.");
              }
            }
          } else {
            dev.log("Gold optimization step was recommended but failed or did not return success. Result: $goldResult", level: 900);
          }
        } else {
          dev.log("No Gold optimization needed or suggested for this query.");
        }
      }*/

      dev.log("Data orchestration complete. Returning updated context.");
      dev.log("Final Schemas Count: ${finalSchemas.length}");
      dev.log("Final Table Names: $finalTableNames");

      return {
        'contextAnalysis': contextAnalysis,
        'updatedSchemas': finalSchemas,
        'updatedTableNames': finalTableNames,
        'transformedSilverFileUris': transformedSilverFileUris
      };

    } catch (e, stackTrace) {
      dev.log("Critical error in data orchestration pipeline: $e", error: e, stackTrace: stackTrace, level: 1200);
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
      final jsonStartIndex = response.indexOf('{');
      final jsonEndIndex = response.lastIndexOf('}') + 1;
      if (jsonStartIndex >= 0 && jsonEndIndex > jsonStartIndex) {
        final jsonStr = response.substring(jsonStartIndex, jsonEndIndex);
        return jsonDecode(jsonStr) as Map<String, dynamic>;
      }
      return {"optimize": false, "reason": "No valid optimization suggested by AI"};
    } catch (e) {
      dev.log("Error parsing optimization suggestion: $e");
      return {"optimize": false, "reason": "Error analyzing optimization needs"};
    }
  }

  /// Trasforma un file Bronze in un file Silver
  Future<Map<String, dynamic>?> _transformBronzeToSilver(String bronzeFileGcsUri) async {
    try {
      dev.log("Attempting Bronze to Silver transformation for input GCS URI: \"$bronzeFileGcsUri\"");
      
      final requestBody = {"path": bronzeFileGcsUri};
      
      // Utilizza un client HTTP con timeout aumentato
      final client = http.Client();
      final request = http.Request('POST', Uri.parse(_bronzeToSilverUrl));
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(requestBody);
      
      // Aumenta il timeout a 300 secondi (5 minuti)
      final response = await client.send(request).timeout(
        const Duration(seconds: 600), // Aumentato da 60 secondi (default) a 300 secondi
        onTimeout: () {
          dev.log("Timeout during Bronze to Silver transformation for $bronzeFileGcsUri.", level: 900);
          throw TimeoutException('Request timed out after 10 minutes');
        },
      );
      
      final responseBody = await response.stream.bytesToString();
      client.close();
      
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final result = jsonDecode(responseBody) as Map<String, dynamic>;
        return result;
      } else {
        dev.log("Bronze to Silver transformation failed with status ${response.statusCode}: $responseBody", level: 900);
        return {"status": "error", "error": "HTTP Error ${response.statusCode}: $responseBody"};
      }
    } catch (e) {
      dev.log("Exception calling Bronze to Silver function: $e", error: e);
      return {"status": "error", "error": e.toString()};
    }
  }

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
          'create_bq_table': true // Assicurati che la CF silver-to-gold gestisca questo
        }),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) { // Controlla anche < 300
        final Map<String, dynamic> responseData = jsonDecode(response.body) as Map<String, dynamic>;
        dev.log("Silver to Gold transformation successful. Response: $responseData");
        // La CF silver-to-gold dovrebbe restituire "gold_df_columns" con i tipi corretti.
        return responseData;
      } else {
        dev.log("Error transforming Silver to Gold: ${response.statusCode} - ${response.body}");
        return {'status': 'error', 'error': 'HTTP error ${response.statusCode}', 'details': response.body};
      }
    } catch (e) {
      dev.log("Exception in Silver to Gold transformation: $e");
      return {'status': 'error', 'error': 'Exception: $e'};
    }
  }
}