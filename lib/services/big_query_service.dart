import 'dart:convert';
import 'package:googleapis/bigquery/v2.dart';
import 'package:googleapis_auth/auth_io.dart';

class BigQueryService {
  final String projectId;
  late BigqueryApi _bigQueryApi;
  bool _isInitialized = false;

  BigQueryService({required this.projectId});

  Future<void> initialize(String credentialsJson) async {
    try {
      final credentials = ServiceAccountCredentials.fromJson(credentialsJson);
      final client = await clientViaServiceAccount(credentials, [
        BigqueryApi.bigqueryScope,
      ]);
      _bigQueryApi = BigqueryApi(client);
      _isInitialized = true;
    } catch (e) {
      throw Exception('Failed to initialize BigQuery: $e');
    }
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

      final response = await _bigQueryApi.jobs.query(queryRequest, projectId);

      if (response.errors != null && response.errors!.isNotEmpty) {
        throw Exception('Query error: ${response.errors!.join(', ')}');
      }

      final rows = <Map<String, dynamic>>[];

      if (response.rows != null) {
        for (var row in response.rows!) {
          final Map<String, dynamic> rowData = {};
          for (var i = 0; i < response.schema!.fields!.length; i++) {
            final field = response.schema!.fields![i];
            final value = row.f![i].v;
            rowData[field.name!] = value;
          }
          rows.add(rowData);
        }
      }

      return rows;
    } catch (e) {
      throw Exception('Failed to execute query: $e');
    }
  }

  Future<String> getDatasetSchema(String datasetId, String tableId) async {
    if (!_isInitialized) {
      throw Exception('BigQuery service not initialized');
    }

    try {
      final table = await _bigQueryApi.tables.get(
        projectId,
        datasetId,
        tableId,
      );
      return jsonEncode(table.schema!.toJson());
    } catch (e) {
      throw Exception('Failed to get schema: $e');
    }
  }
}
