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
  // Nuovo URL per la scansione Dataplex batch
  final String _batchDataplexScanUrl;

  DataOrchestrationService({
    required GeminiFlashService geminiService,
    required BigQueryService bigQueryService,
    required CloudStorageService cloudStorageService,
    required String bronzeToSilverUrl,
    required String silverToGoldUrl,
    String? batchDataplexScanUrl,
  }) : _geminiService = geminiService,
       _bigQueryService = bigQueryService,
       _cloudStorageService = cloudStorageService,
       _bronzeToSilverUrl = bronzeToSilverUrl,
       _silverToGoldUrl = silverToGoldUrl,
       _batchDataplexScanUrl =
           batchDataplexScanUrl ??
           'https://europe-central2-soy-transducer-456512-t0.cloudfunctions.net/batch-dataplex-scan';

  /* -- METODI DI INIZIALIZZAZIONE -- */

  Future<Map<String, List<String>>> getSilverAndGoldTables() async {
    try {
      // Recupera l'elenco dei dataset nel progetto BigQuery
      final datasets = await _bigQueryService.getDatasets();
      dev.log('List of datasets: $datasets');
      if (datasets.isEmpty) {
        throw Exception("No datasets found in the project.");
      }

      // Recupera le tabelle per ogni dataset, escludendo 'metadata_store'
      final Map<String, List<String>> datasetTablesMap = {};
      for (var datasetId in datasets) {
        if (datasetId.toLowerCase() != 'metadata_store') {
          final tables = await _bigQueryService.getTables(datasetId);
          datasetTablesMap[datasetId] = tables;
        }
      }

      // Otteniamo tutte le tabelle Silver e Gold divise per dataset
      dev.log('Dataset to tables mapping: $datasetTablesMap');
      return datasetTablesMap;
    } catch (e) {
      dev.log('Error fetching datasets or tables: $e');
      throw Exception('Failed to fetch datasets or tables: $e');
    }
  }

  Future<Map<String, dynamic>> initializeTableMaps(
    Map<String, List<String>> datasetTablesMap,
  ) async {
    final projectId = _bigQueryService.projectId;
    List<Map<String, dynamic>> schemas = [];
    Map<String, List<Map<String, dynamic>>> sampleData = {};
    List<String> tableNames = [];

    for (var entry in datasetTablesMap.entries) {
      final targetDataset = entry.key;
      final tablesInDataset = entry.value;
      for (var tableIdInDataset in tablesInDataset) {
        final fullTableName = '$projectId.$targetDataset.$tableIdInDataset';
        try {
          final schemaJson = await _bigQueryService.getTableSchema(
            targetDataset,
            tableIdInDataset,
          );
          final Map<String, dynamic> schemaMap = jsonDecode(schemaJson);
          schemas.add(schemaMap); // schemaMap è già un Map<String, dynamic>
          tableNames.add(fullTableName);

          String sampleQuery;

          if (targetDataset == 'silver_zone') {
            // Per tabelle silver_zone, usa LIMIT senza filtri di partizione
            sampleQuery = "SELECT * FROM `$fullTableName` LIMIT 15";
            dev.log(
              "Using simple LIMIT query for silver_zone table $fullTableName to avoid partition issues",
            );
          } else {
            // Per altre tabelle usa TABLESAMPLE
            sampleQuery =
                "SELECT * FROM `$fullTableName` TABLESAMPLE SYSTEM (1 PERCENT) LIMIT 15";
          }

          try {
            final tableSample = await _bigQueryService.executeQuery(
              sampleQuery,
            );
            sampleData[fullTableName] = tableSample;
          } catch (e) {
            dev.log(
              'Warning: Failed to get sample data from $fullTableName (Query: $sampleQuery). Error: $e',
            );

            // Se fallisce con la query principale, prova un fallback con solo LIMIT
            if (targetDataset == 'silver_zone') {
              try {
                final fallbackQuery = "SELECT * FROM `$fullTableName` LIMIT 5";
                dev.log(
                  "Trying fallback query for $fullTableName: $fallbackQuery",
                );
                final fallbackSample = await _bigQueryService.executeQuery(
                  fallbackQuery,
                );
                sampleData[fullTableName] = fallbackSample;
                dev.log("Fallback query successful for $fullTableName");
              } catch (fallbackError) {
                dev.log(
                  'Failed fallback query for $fullTableName: $fallbackError',
                );
                sampleData[fullTableName] =
                    []; // Inizializza a lista vuota in caso di errore
              }
            } else {
              sampleData[fullTableName] =
                  []; // Inizializza a lista vuota in caso di errore
            }
          }
        } catch (e) {
          dev.log(
            'Warning: Failed to get schema for table $fullTableName. Skipping. Error: $e',
          );
        }
      }
    }

    // Abbiamo ottenuto nomi, schemi e dati di esempio per tutte le tabelle Silver e Gold
    dev.log('Table names fetched: ${tableNames.length}');
    dev.log('Table schemas fetched: ${schemas.length}');
    dev.log('Sample data fetched for ${sampleData.keys.length} tables');

    // Ritorno i valori ottenuti in una mappa
    return {
      'tableNames': tableNames,
      'schemas': schemas,
      'sampleData': sampleData,
    };
  }

  /// Ottieni le intenzioni dell'utente dalla domanda in linguaggio naturale
  Future<String> getUserIntent(String userQuestion) async {
    return _geminiService.analyzeIntent(userQuestion);
  }

  /* -- METODI PER LA DATA TRANSFORMATION -- */

  /// Trasforma un file Bronze in un file Silver
  /// skipDataplex: sempre true, indica che la scansione Dataplex viene saltata
  /// per il singolo file e fatta collettivamente alla fine
  Future<Map<String, dynamic>?> transformBronzeToSilver(
    String bronzeFileGcsUri, {
    bool skipDataplex =
        true, // Sempre true per fare la scansione collettiva alla fine
  }) async {
    try {
      dev.log(
        "Attempting Bronze to Silver transformation for input GCS URI: \"$bronzeFileGcsUri\"",
      );

      final requestBody = {
        "path": bronzeFileGcsUri,
        "skip_dataplex": true, // Sempre true per la scansione collettiva
      };

      // Utilizza un client HTTP con timeout aumentato
      final client = http.Client();
      final request = http.Request('POST', Uri.parse(_bronzeToSilverUrl));
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(requestBody);

      final response = await client
          .send(request)
          .timeout(
            const Duration(seconds: 600),
            onTimeout: () {
              dev.log(
                "Timeout during Bronze to Silver transformation for $bronzeFileGcsUri.",
                level: 900,
              );
              throw TimeoutException('Request timed out after 10 minutes');
            },
          );

      final responseBody = await response.stream.bytesToString();
      client.close();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final result = jsonDecode(responseBody) as Map<String, dynamic>;
        return result;
      } else {
        dev.log(
          "Bronze to Silver transformation failed with status ${response.statusCode}: $responseBody",
          level: 900,
        );
        return {
          "status": "error",
          "error": "HTTP Error ${response.statusCode}: $responseBody",
        };
      }
    } catch (e) {
      dev.log("Exception calling Bronze to Silver function: $e", error: e);
      return {"status": "error", "error": e.toString()};
    }
  }

  /// Avvia una scansione Dataplex batch per tutti i file Silver generati
  Future<Map<String, dynamic>?> triggerBatchDataplexScan(
    List<String> silverFileUris,
    List<String> finalTableNames,
  ) async {
    try {
      dev.log(
        "Triggering batch Dataplex scan for ${silverFileUris.length} files",
      );

      // Importante: lavoriamo solo con le tabelle relative ai file silver attuali
      // Creiamo una copia locale delle tabelle che contenga solo quelle generate in questa esecuzione
      final currentTablesOnly = List<String>.from(finalTableNames);
      dev.log("Tabelle da attendere: ${currentTablesOnly.join(', ')}");

      final requestBody = {"silver_files": silverFileUris};

      final response = await http.post(
        Uri.parse(_batchDataplexScanUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      );

      dev.log("1");

      if (response.statusCode >= 200 && response.statusCode < 300) {
        dev.log("2");
        final result = jsonDecode(response.body) as Map<String, dynamic>;
        dev.log("WAITING DATAPLEX!!!!!");
        await waitForAllSilverTables(
          currentTablesOnly,
        ); // Passa la copia locale invece dell'originale
        dev.log('"DATAPLEX SCANNING COMPLETED!"');
        return result;
      } else if (response.statusCode == 429) {
        dev.log("no1");
        dev.log(
          "Dataplex API quota exceeded. Tables will be created when quota resets.",
          level: 500,
        );
        return {
          "status": "quota_exceeded",
          "message": "Dataplex quota exceeded. Tables will be created later.",
        };
      } else {
        dev.log("no2");
        dev.log(
          "Batch Dataplex scan failed with status ${response.statusCode}: ${response.body}",
          level: 900,
        );
        return {
          "status": "error",
          "error": "HTTP Error ${response.statusCode}: ${response.body}",
        };
      }
    } catch (e) {
      dev.log("no3");
      dev.log("Exception calling Batch Dataplex scan function: $e", error: e);
      return {"status": "error", "error": e.toString()};
    }
  }

  /// Attende che tutte le tabelle attese siano presenti nel dataset "silver_zone"
  Future<void> waitForAllSilverTables(List<String> finalTableNames) async {
    while (true) {
      final tables = await _bigQueryService.getTables("silver_zone");
      dev.log("Tables fetched: $tables");
      // Stampo

      bool allTablesFound = true;
      for (String fullTableName in finalTableNames) {
        String tableNameOnly = fullTableName;
        if (fullTableName.contains('.')) {
          tableNameOnly = fullTableName.split('.').last;
        }

        bool found = false;
        if (tables != null) {
          for (var table in tables) {
            if (table.toLowerCase() == tableNameOnly.toLowerCase()) {
              found = true;
              break;
            }
          }
        }

        if (!found) {
          allTablesFound = false;
          dev.log(
            "Tabella non trovata: $fullTableName (nome semplice: $tableNameOnly)",
          );
        }
      }

      if (allTablesFound) {
        dev.log(
          "Tutte le tabelle attese (${finalTableNames.length}) sono presenti nella Silver zone.",
        );
        break;
      } else {
        dev.log("Tabelle lette: ${tables?.join(', ')}");
        dev.log(
          "Tabelle attese (nomi completi): ${finalTableNames.join(', ')}",
        );
        dev.log(
          "Non tutte le tabelle attese sono presenti nella Silver zone. Attendo 1 minuto prima di riprovare...",
        );
        await Future.delayed(const Duration(minutes: 1));
      }
    }
  }

  Future<Map<String, dynamic>> dataTransformationPipeline(
    String userIntent,
    List<Map<String, dynamic>> goldAndSilverSchemas,
    Map<String, List<Map<String, dynamic>>> goldAndSilverSamples,
    List<Map<String, dynamic>> bronzeMetadata,
  ) async {
    // Definizione di liste per memorizzare i risultati
    List<String> transformedSilverFileUris = [];
    List<Map<String, dynamic>> finalSchemas = [];
    List<String> finalTableNames = [];

    /* -- PROCESSO DI TRASFORMAZIONE -- */
    // Ottieni i nomi dei file bronze da trasformare (DA FARE ITERATIVAMENTE IN BATCH)
    final List<String> filesToTransformBronze = await _geminiService
        .suggestBronzeFiles(userIntent, bronzeMetadata);

    // Se ci sono file da trasformare, procedi con la trasformazione
    if (filesToTransformBronze.isNotEmpty) {
      dev.log(
        "Gemini suggested ${filesToTransformBronze.length} files for Bronze-to-Silver transformation",
      );

      for (int i = 0; i < filesToTransformBronze.length; i++) {
        // Memorizza l'Uri del file corrente
        final bronzeFileGcsUri = filesToTransformBronze[i];

        // TRASFORMAZIONE BRONZE → SILVER
        dev.log(
          "Processing Bronze file for Silver transformation: $bronzeFileGcsUri",
        );
        final silverTransformResult = await transformBronzeToSilver(
          bronzeFileGcsUri,
        );

        // Se la trasformazione ha avuto successo
        if (silverTransformResult != null &&
            silverTransformResult['status'] == 'success') {
          // Memorizza il percorso Silver trasformato
          final String? silverPathUri =
              silverTransformResult['silver_path'] as String?;

          if (silverPathUri != null && silverPathUri.isNotEmpty) {
            dev.log(
              "Bronze file $bronzeFileGcsUri transformed/found at Silver path: $silverPathUri",
            );
            // Aggiungi il percorso Silver alla lista dei file trasformati (per la futura scansione Dataplex)
            transformedSilverFileUris.add(silverPathUri);

            final String? bigQueryTableName =
                silverTransformResult['bigquery_table'] as String?;
            String silverFileNameNoExt = ''; // Per fallback

            // GESTIONE NOME TABELLA
            // Dove viene aggiunto il nome della tabella BigQuery
            if (bigQueryTableName != null && bigQueryTableName.isNotEmpty) {
              // Mantieni il formato completo project.dataset.table ma normalizza il nome della tabella
              final parts = bigQueryTableName.split('.');
              final normalizedTableName = "${parts[0]}.${parts[1]}.${parts[2].toLowerCase()}";
              
              if (!finalTableNames.contains(normalizedTableName)) {
                finalTableNames.add(normalizedTableName);
                dev.log("Added normalized Silver external table to context: $normalizedTableName");
              }
              silverFileNameNoExt = parts[2].toLowerCase(); // Nome della tabella in minuscolo
            } else {
              // Fallback per derivare il nome della tabella se non fornito
              try {
                final uriParts = Uri.parse(silverPathUri).pathSegments;
                if (uriParts.isNotEmpty) {
                  final silverFileNameWithExt = uriParts.last;
                  silverFileNameNoExt = silverFileNameWithExt.replaceAll('.parquet', '').toLowerCase();
                  const String silverDatasetIdFallback = "silver_zone";
                  final String newSilverTableNameFallback = 
                      "${_bigQueryService.projectId}.$silverDatasetIdFallback.$silverFileNameNoExt";
                  if (!finalTableNames.contains(newSilverTableNameFallback)) {
                    // Aggiungi il nome della tabella di fallback alla lista finale
                    finalTableNames.add(newSilverTableNameFallback);
                    dev.log(
                      "Added new Silver table to context (fallback naming): $newSilverTableNameFallback",
                    );
                  }
                }
              } catch (e) {
                dev.log(
                  "Error in fallback table naming for $silverPathUri: $e",
                );
              }
            }

            // GESTIONE SCHEMA CON TIPI
            if (silverTransformResult['columns'] != null &&
                silverTransformResult['columns'] is List) {
              final List<dynamic> columnsRaw =
                  silverTransformResult['columns'] as List<dynamic>;
              if (columnsRaw.isNotEmpty) {
                final List<Map<String, String>> schemaFields =
                    columnsRaw.map((colInfoRaw) {
                      final Map<String, dynamic> colInfo =
                          colInfoRaw as Map<String, dynamic>;
                      final String columnName = colInfo['name'] as String;
                      final String columnType =
                          colInfo['type'] as String; // Tipo BQ da CF Python
                      return {
                        "name": columnName,
                        "type":
                            columnType, // Usa direttamente il tipo fornito dalla CF
                        "mode": "NULLABLE",
                      };
                    }).toList();

                if (schemaFields.isNotEmpty) {
                  String datasetIdForSchema = "silver_zone"; // Default
                  String tableIdForSchema =
                      silverFileNameNoExt; // Derivato sopra

                  if (bigQueryTableName != null &&
                      bigQueryTableName.isNotEmpty) {
                    final parts = bigQueryTableName.split('.');
                    if (parts.length == 3) {
                      datasetIdForSchema = parts[1];
                      tableIdForSchema = parts[2];
                    }
                  }
                  // Rimuovi lo schema esistente per questa tabella, se presente, per evitare duplicati
                  finalSchemas.removeWhere(
                    (schema) =>
                        schema['tableReference']?['tableId'] ==
                            tableIdForSchema &&
                        schema['tableReference']?['datasetId'] ==
                            datasetIdForSchema,
                  );

                  // Aggiungi il nuovo schema alla lista finale degli schemi
                  finalSchemas.add({
                    "tableReference": {
                      "projectId":
                          _bigQueryService
                              .projectId, // o projectId estratto da bigQueryTableName
                      "datasetId": datasetIdForSchema,
                      "tableId": tableIdForSchema,
                    },
                    "schema": {
                      // Struttura corretta per schema BQ
                      "fields": schemaFields,
                    },
                  });
                  dev.log(
                    "Added/Updated schema for Silver table: ${_bigQueryService.projectId}.$datasetIdForSchema.$tableIdForSchema with ${schemaFields.length} columns based on types from CF.",
                  );
                }
              }
            } else {
              dev.log(
                "Info: 'columns' field not found or not a List in response for $silverPathUri. Schema not added/updated for this run.",
              );
            }
          } else {
            dev.log(
              'Warning: Bronze-to-Silver success response for $bronzeFileGcsUri missing valid "silver_path". Result: $silverTransformResult',
              level: 900,
            );
          }
        } else {
          dev.log(
            'Warning: Bronze-to-Silver transformation failed or status was not "success" for $bronzeFileGcsUri. Result: $silverTransformResult',
            level: 900,
          );
        }
      } // for della trasformazione

      /* -- DATAPLEX SCAN -- */
      // Se ci sono file trasformati, avvia una scansione Dataplex batch per tutti i file Silver generati
      if (transformedSilverFileUris.isNotEmpty) {
        dev.log(
          "Triggering batch Dataplex scan for ${transformedSilverFileUris.length} Silver files",
        );
        final dataplexResult = await triggerBatchDataplexScan(
          transformedSilverFileUris,
          finalTableNames,
        );
        if (dataplexResult != null) {
          dev.log(
            "Batch Dataplex scan triggered: ${jsonEncode(dataplexResult)}",
          );
          // Non attendiamo il completamento qui - sarà asincrono
        } else {
          dev.log(
            "Failed to trigger batch Dataplex scan. Tables may not be immediately available.",
            level: 900,
          );
        }
      }
    } else {
      dev.log("No Bronze files suggested for transformation by Gemini.");
    }

    /* -- GOLD E SILVER DISCOVERY -- */
    // Ottieni le tabelle e gli schemi Silver e Gold (DA FARE ITERATIVAMENTE IN BATCH)
    final goldAndSilverSuggestedTables = await _geminiService
        .goldAndSilverDiscovery(
          userIntent,
          goldAndSilverSchemas,
          goldAndSilverSamples,
        );

    dev.log(
      "Gemini gold ans silver suggestion result: ${jsonEncode(goldAndSilverSuggestedTables)}",
    );

    // Estrai gli schemi e i nomi della tabelle dalla scoperta di Gold e Silver
    List<String> silverTableNames =
        goldAndSilverSuggestedTables['suggested_silver_tables'] as List<String>;
    List<String> goldTableNames =
        goldAndSilverSuggestedTables['suggested_gold_tables'] as List<String>;

    // Unisci i nomi delle tabelle Silver e Gold in un'unica lista
    final allSuggestedTables = [...silverTableNames, ...goldTableNames];

    dev.log(
      "Gemini suggested ${silverTableNames.length} Silver tables and ${goldTableNames.length} Gold tables for further processing.",
    );

    // Crea una mappa aggiornata delle tabelle da utilizzare che contiene le tabelle e gli schemi ottenuti dalla trasformazione
    // e quelli ottenuti dalla scoperta di Gold e Silver
    Map<String, dynamic> updatedSchemas = {};

    // Ottieni gli schemi delle tabelle Silver e Gold suggerite e aggiungile alla mappa finale degli schemi
    for (String tableFullName in allSuggestedTables) {
      final parts = tableFullName.split('.');
      if (parts.length >= 3) {
        String datasetName = parts[1]; // secondo elemento è il dataset
        String tableName = parts[2]; // terzo elemento è il nome della tabella

        try {
          final schema = await _bigQueryService.getTableSchema(
            datasetName,
            tableName,
          );
          if (schema.isNotEmpty) {
            // Aggiungi lo schema come valore e il nome della tabella come chiave
            updatedSchemas[tableFullName] = jsonDecode(schema);
            dev.log("Added schema for table: $datasetName.$tableName");
          } else {
            dev.log(
              "Warning: Empty schema for table $datasetName.$tableName",
              level: 900,
            );
          }
        } catch (e) {
          dev.log(
            "Error fetching schema for $datasetName.$tableName: $e",
            error: e,
            level: 900,
          );
        }
      } else {
        dev.log(
          "Warning: Invalid table name format '$tableFullName'. Expected format: project.dataset.table",
          level: 900,
        );
      }
    }

    // Ritorna la mappa ottenuta
    return updatedSchemas;
  }

  /* -- METODI PER LA COSTRUZIONE DELLA QUERY --*/

  Future<String> queryBuildingPipeline(
    String userIntent,
    Map<String, dynamic> selectedSchemas,
  ) async {
    // Ottieni il piano di esecuzione della query
    String queryPlan = await _geminiService.planQuery(
      userIntent,
      selectedSchemas,
    );

    // Genera una query SQL BigQuery
    String sqlQuery = await _geminiService.buildQuery(
      userIntent,
      queryPlan,
      selectedSchemas,
    );

    // Valida gli schemi utilizzati nella query
    sqlQuery = await _geminiService.validateSchemasAndCorrectQuery(
      sqlQuery,
      selectedSchemas,
    );

    // Correggi eventuali errori e migliora la sintassi della query
    sqlQuery = await _geminiService.correctQuerySyntax(sqlQuery);

    // Ritorna la query perfezionata
    return sqlQuery;
  }
}
