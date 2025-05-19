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

  Future<List<Map<String, dynamic>>> executeQuery(
    String query, {
    int timeout = 60,
  }) async {
    if (!_isInitialized) {
      throw Exception('BigQuery service not initialized');
    }

    try {
      final queryRequest =
          QueryRequest()
            ..query = query
            ..timeoutMs = timeout * 1000
            ..useLegacySql = false;

      log('Executing BQ Query: $query');
      // Specify location if known, otherwise let API infer (might default to US)
      // For queries, location is often less critical than for jobs
      final response = await _bigQueryApi.jobs.query(queryRequest, projectId);

      if (response.jobComplete == false) {
        // Handle asynchronous query if needed (poll job status)
        log(
          'Warning: Query job did not complete immediately. Results might be partial or delayed.',
        );
        // You might want to implement polling here similar to the upload job
      }

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
      log('BQ Query successful, rows fetched: ${rows.length}');
      return rows;
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
