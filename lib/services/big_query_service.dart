import 'dart:convert';
import 'dart:async'; // Added for Future.delayed and polling
import 'dart:typed_data'; // Added for Uint8List
import 'package:googleapis/bigquery/v2.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http; // Needed for Media
import 'dart:developer'; // Added for logging

class BigQueryService {
  final String projectId;
  late BigqueryApi _bigQueryApi;
  late http.Client _client; // Store the client for reuse
  bool _isInitialized = false;
  
  // Impostazioni di sicurezza per le query
  static const int DEFAULT_MAX_ROWS = 100; // Default limit for rows returned
  static const int ABSOLUTE_MAX_ROWS = 400; // Hard safety limit
  static const int DEFAULT_TIMEOUT_SECONDS = 60;

  BigQueryService({required this.projectId});

  Future<void> initialize(String credentialsJson) async {
    try {
      final credentials = ServiceAccountCredentials.fromJson(credentialsJson);
      _client = await clientViaServiceAccount(credentials, [
        BigqueryApi.bigqueryScope,
        BigqueryApi.cloudPlatformScope, // Needed for jobs
      ]);
      _bigQueryApi = BigqueryApi(_client);
      _isInitialized = true;
      log('BigQuery service initialized successfully');
    } catch (e) {
      log('Failed to initialize BigQuery: $e', error: e);
      throw Exception('Failed to initialize BigQuery: $e');
    }
  }

  // Closes the underlying HTTP client
  void dispose() {
    _client.close();
    log('BigQuery service disposed');
  }

  /// Modifica la query per aggiungere clausola LIMIT se necessario
  String _ensureSafeQuery(String query, int maxRows) {
    // Controlla se la query ha già una clausola LIMIT
    final hasLimit = RegExp(r'\bLIMIT\s+\d+', caseSensitive: false).hasMatch(query);
    
    // Se non ha un LIMIT, aggiungilo
    if (!hasLimit) {
      // Rimuove eventuali caratteri di punteggiatura finali e aggiunge LIMIT
      query = query.trimRight();
      if (query.endsWith(';')) {
        query = query.substring(0, query.length - 1);
      }
      query = '$query LIMIT $maxRows';
    }
    
    return query;
  }

  Future<List<Map<String, dynamic>>> executeQuery(
    String query, {
    int timeout = DEFAULT_TIMEOUT_SECONDS,
    int maxRows = DEFAULT_MAX_ROWS,
    bool enforceSafeLimit = true,
  }) async {
    if (!_isInitialized) {
      throw Exception('BigQuery service not initialized');
    }

    try {
      // Assicurati che maxRows non superi il limite massimo assoluto
      if (maxRows > ABSOLUTE_MAX_ROWS) {
        log('Warning: Requested maxRows ($maxRows) exceeds safety limit. Using $ABSOLUTE_MAX_ROWS instead.');
        maxRows = ABSOLUTE_MAX_ROWS;
      }

      // Aggiungi LIMIT se la query non ce l'ha già e enforceSafeLimit è true
      final safeQuery = enforceSafeLimit ? _ensureSafeQuery(query, maxRows) : query;
      
      // Log query originale e modificata se diverse
      if (query != safeQuery) {
        log('Original query: $query');
        log('Modified safe query: $safeQuery');
      } else {
        log('Executing BQ Query: $safeQuery');
      }

      final queryRequest =
          QueryRequest()
            ..query = safeQuery
            ..timeoutMs = timeout * 1000
            ..useLegacySql = false
            ..maxResults = maxRows; // Imposta anche il limite massimo di risultati

      // Specify location if known, otherwise let API infer (might default to US)
      final response = await _bigQueryApi.jobs.query(queryRequest, projectId);

      // Gestione delle query di grandi dimensioni con paginazione
      List<Map<String, dynamic>> allRows = [];
      var pageToken = response.pageToken;
      
      // Processa i risultati della prima pagina
      allRows.addAll(_processQueryResultRows(response));
      
      // Se ci sono più pagine e non abbiamo ancora raggiunto maxRows, recuperale
      int totalRowsProcessed = allRows.length;
      int pageCount = 1;
      
      while (pageToken != null && totalRowsProcessed < maxRows) {
        // Calcola quanti risultati ancora possiamo recuperare
        int remainingRows = maxRows - totalRowsProcessed;
        
        log('Fetching next page of results (page ${pageCount + 1}), remaining rows: $remainingRows');
        
        final jobId = response.jobReference?.jobId;
        final location = response.jobReference?.location;
        
        if (jobId == null) {
          log('Warning: Could not get job ID for pagination');
          break;
        }
        
        // Recupera la pagina successiva
        final pageResponse = await _bigQueryApi.jobs.getQueryResults(
          projectId,
          jobId,
          maxResults: remainingRows,
          pageToken: pageToken,
          location: location,
        );
        
        // Processa i risultati
        final pageRows = _processQueryResultRows(pageResponse);
        allRows.addAll(pageRows);
        totalRowsProcessed += pageRows.length;
        pageCount++;
        
        // Aggiorna pageToken per la prossima iterazione
        pageToken = pageResponse.pageToken;
        
        // Limite di sicurezza per il numero di pagine
        if (pageCount > 10) {
          log('Warning: Reached maximum page count (10). Some data may be truncated.');
          break;
        }
      }

      log('BQ Query successful, total rows fetched: ${allRows.length} in $pageCount pages');
      return allRows;
    } catch (e) {
      log('Failed to execute BQ query: $e', error: e);
      // Rethrow with specific type if possible, otherwise generic Exception
      if (e is DetailedApiRequestError) {
        throw Exception(
          'Failed to execute query: DetailedApiRequestError(status: ${e.status}, message: ${e.message})',
        );
      } else {
        throw Exception('Failed to execute query: $e');
      }
    }
  }
  
  /// Processa le righe dei risultati della query da un oggetto QueryResponse o GetQueryResultsResponse
  List<Map<String, dynamic>> _processQueryResultRows(dynamic response) {
    if (response.errors != null && response.errors!.isNotEmpty) {
      final errorMessage = response.errors!
          .map((e) => '${e.reason}: ${e.message}')
          .join(', ');
      log('BigQuery query error: $errorMessage');
      // Throw a more specific error if possible
      if (response.errors!.first.reason == 'invalidQuery') {
        throw Exception('Invalid Query: $errorMessage');
      }
      throw Exception('Query error: $errorMessage');
    }

    final rows = <Map<String, dynamic>>[];
    if (response.rows != null && response.schema?.fields != null) {
      for (var row in response.rows!) {
        final Map<String, dynamic> rowData = {};
        if (row.f == null) continue; // Skip if row data is missing
        for (var i = 0; i < response.schema!.fields!.length; i++) {
          final field = response.schema!.fields![i];
          // Ensure index is within bounds of row data
          if (i < row.f!.length) {
            final value = row.f![i].v;
            // Basic type conversion (can be expanded)
            if (value != null) {
              if (field.type == 'INTEGER' || field.type == 'INT64') {
                rowData[field.name!] =
                    int.tryParse(value.toString()) ?? value;
              } else if (field.type == 'FLOAT' ||
                  field.type == 'FLOAT64' ||
                  field.type == 'NUMERIC' ||
                  field.type == 'BIGNUMERIC') {
                rowData[field.name!] =
                    double.tryParse(value.toString()) ?? value;
              } else if (field.type == 'BOOLEAN' || field.type == 'BOOL') {
                rowData[field.name!] =
                    value.toString().toLowerCase() == 'true';
              } else {
                rowData[field.name!] =
                    value; // Keep as string or original type
              }
            } else {
              rowData[field.name!] = null;
            }
          } else {
            rowData[field.name!] =
                null; // Handle cases where row has fewer fields than schema (shouldn't happen in valid response)
            log(
              'Warning: Row ${response.rows!.indexOf(row)} has fewer fields than schema expected.',
            );
          }
        }
        rows.add(rowData);
      }
    }
    return rows;
  }

  Future<List<Map<String, dynamic>>> getBronzeMetadata() async {
    if (!_isInitialized) {
      throw Exception('BigQuery service not initialized');
    }

    var query = """
      SELECT
        CONCAT('gs://', bucket_name, file_path) as file_gcs_uri,
        bucket_name,
        file_path,
        ARRAY_REVERSE(SPLIT(file_path, '/'))[SAFE_OFFSET(0)] as file_name,
        ARRAY_REVERSE(SPLIT(ARRAY_REVERSE(SPLIT(file_path, '/'))[SAFE_OFFSET(0)], '.'))[SAFE_OFFSET(0)] as file_extension,
        content_type,
        CAST(file_size_bytes AS STRING) as file_size_bytes,
        CAST(gcs_generation_id AS STRING) as gcs_generation_id,
        CAST(gcs_metageneration_id AS STRING) as gcs_metageneration_id,
        gcs_crc32c_hash,
        gcs_md5_hash,
        FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%S.%fZ', TIMESTAMP(event_time)) as event_time,
        FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%S.%6f', TIMESTAMP(metadata_ingestion_time)) as metadata_ingestion_time,
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
        silver_columns,
      FROM `soy-transducer-456512-t0.metadata_store.bronze_file_metadata`
      ORDER BY metadata_ingestion_time DESC
    """;

    try {
      log('Fetching bronze metadata from BigQuery');
      var results = await executeQuery(query);

      // Elimino dai risultati tutti i record in cui il campo 'file_gcs_uri' è duplicato
      results = results
          .where((row) =>
              results
                  .where((r) => r['file_gcs_uri'] == row['file_gcs_uri'])
                  .length ==
              1)
          .toList();

      log('Retrieved ${results.length} metadata records');
      return results;
    } catch (e) {
      log('Failed to fetch bronze metadata: $e', error: e);
      throw Exception('Failed to fetch bronze metadata: $e');
    }
  }

  Future<List<String>> getDatasets() async {
    if (!_isInitialized) {
      throw Exception('BigQuery service not initialized');
    }
    try {
      log('Fetching datasets for project: $projectId');
      final datasets = await _bigQueryApi.datasets.list(projectId);
      final datasetIds =
          datasets.datasets
              ?.map((d) => d.datasetReference?.datasetId ?? '')
              .where((id) => id.isNotEmpty)
              .toList() ??
          [];
      log('Datasets fetched: $datasetIds');
      return datasetIds;
    } catch (e) {
      log('Failed to get BQ datasets: $e', error: e);
      throw Exception('Failed to get datasets: $e');
    }
  }

  Future<List<String>> getTables(String datasetId) async {
    if (!_isInitialized) {
      throw Exception('BigQuery service not initialized');
    }
    try {
      log('Fetching tables for dataset: $projectId.$datasetId');
      final tables = await _bigQueryApi.tables.list(projectId, datasetId);
      final tableIds =
          tables.tables
              ?.map((t) => t.tableReference?.tableId ?? '')
              .where((id) => id.isNotEmpty)
              .toList() ??
          [];
      log('Tables fetched: $tableIds');
      return tableIds;
    } catch (e) {
      log('Failed to get BQ tables: $e', error: e);
      throw Exception('Failed to get tables: $e');
    }
  }

  Future<String> getTableSchema(String datasetId, String tableId) async {
    if (!_isInitialized) {
      throw Exception('BigQuery service not initialized');
    }
    try {
      log('Fetching schema for table: $projectId.$datasetId.$tableId');
      final table = await _bigQueryApi.tables.get(
        projectId,
        datasetId,
        tableId,
      );
      final schemaJson = jsonEncode(table.schema?.toJson() ?? {});
      log('Schema fetched successfully');
      return schemaJson;
    } catch (e) {
      log('Failed to get BQ table schema: $e', error: e);
      throw Exception('Failed to get schema: $e');
    }
  }

  // --- Updated Method: Upload CSV to BigQuery Table ---
  Future<void> uploadCsvToTable(
    String datasetId,
    String tableId,
    Uint8List csvBytes, {
    bool skipLeadingRows = true, // Default: assume header row
    bool autoDetectSchema = true, // Default: auto-detect schema
    String writeDisposition = 'WRITE_APPEND', // Default: append data
    String createDisposition =
        'CREATE_IF_NEEDED', // Default: create table if not exists
    Duration pollInterval = const Duration(seconds: 3),
    Duration timeout = const Duration(minutes: 5), // Timeout for the whole job
  }) async {
    if (!_isInitialized) {
      throw Exception('BigQuery service not initialized');
    }

    try {
      log('Starting CSV upload to $projectId.$datasetId.$tableId');
      final tableReference =
          TableReference()
            ..projectId = projectId
            ..datasetId = datasetId
            ..tableId = tableId;

      final jobConfigLoad =
          JobConfigurationLoad()
            ..destinationTable = tableReference
            ..sourceFormat = 'CSV'
            ..skipLeadingRows = skipLeadingRows ? 1 : 0
            ..autodetect = autoDetectSchema
            ..createDisposition = createDisposition
            ..writeDisposition = writeDisposition;

      final job =
          Job()..configuration = (JobConfiguration()..load = jobConfigLoad);

      final media = Media(
        Stream<List<int>>.value(csvBytes.toList()),
        csvBytes.length,
      );

      log('Inserting BigQuery load job...');
      final insertResponse = await _bigQueryApi.jobs.insert(
        job,
        projectId,
        uploadMedia: media,
      );

      final jobId = insertResponse.jobReference?.jobId;
      final location =
          insertResponse.jobReference?.location; // *** Get the job location ***

      if (jobId == null) {
        log('Error: Job insertion did not return a jobId.');
        throw Exception(
          'Failed to start BigQuery load job: No Job ID returned.',
        );
      }
      if (location == null) {
        // Although unlikely, handle missing location just in case.
        // The job might still succeed, but polling will fail.
        log(
          'Warning: Job insertion did not return a location. Polling might fail.',
        );
        throw Exception(
          'Failed to start BigQuery load job: No location returned.',
        );
      }

      log(
        'BigQuery load job started: $jobId in location: $location. Polling for completion...',
      );

      // Poll for job completion
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsed < timeout) {
        await Future.delayed(pollInterval);
        // *** Pass the location to jobs.get ***
        final jobStatus = await _bigQueryApi.jobs.get(
          projectId,
          jobId,
          location: location,
        );
        final state = jobStatus.status?.state;
        log(
          'Polling job $jobId (location: $location): State = $state, Elapsed = ${stopwatch.elapsed}',
        );

        if (state == 'DONE') {
          stopwatch.stop();
          final errorResult = jobStatus.status?.errorResult;
          if (errorResult != null) {
            // Log all errors if available
            String allErrors =
                jobStatus.status?.errors
                    ?.map((e) => '${e.reason}: ${e.message} at ${e.location}')
                    .join('') ??
                '';
            final errorMessage =
                '${errorResult.reason}: ${errorResult.message}';
            log(
              'BigQuery load job $jobId failed: $errorMessage Details: $allErrors',
              error: jobStatus.status?.errors,
            );
            throw Exception('BigQuery load job failed: $errorMessage');
          }
          log('BigQuery load job $jobId completed successfully.');
          return; // Success
        }
      }

      // Timeout reached
      stopwatch.stop();
      log('BigQuery load job $jobId timed out after ${stopwatch.elapsed}.');
      throw Exception(
        'BigQuery load job timed out after ${timeout.inSeconds} seconds.',
      );
    } catch (e) {
      log('Failed to upload CSV: $e', error: e);
      if (e is DetailedApiRequestError) {
        // Provide more context for API errors
        throw Exception(
          'Failed to upload CSV: API Error (status: ${e.status}, message: ${e.message})',
        );
      } else {
        throw Exception('Failed to upload CSV: ${e.toString()}');
      }
    }
  }
}
