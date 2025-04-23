import 'dart:convert';
import 'package:easy_query/services/rest_service.dart';

class GeminiFlashService {
  final RestService _restService;
  final String _apiKey;

  GeminiFlashService({required RestService restService, required String apiKey})
    : _restService = restService,
      _apiKey = apiKey;

  Future<String> generateSqlQuery(
    String userQuestion,
    String databaseSchema,
    String tableName,
  ) async {
    final payload = {
      'contents': [
        {
          'parts': [
            {
              'text':
                '''
                You are a SQL expert. Convert this question to a SQL for Big Query (Standard SQL) query based on the provided schemas.
                Question: $userQuestion
                Database Schemas: $databaseSchema
                Tables names: $tableName
                Use the following guidelines:
                1. Generate only the SQL query without any explanations.
                2. Use backticks (`) around column names with spaces to avoid errors (even in aggregating operations eg., SELECT AVG(`gross income`)) 
                3. Always use the `LIMIT` clause to limit the number of rows returned to 100.
                4. Use `SELECT *` only when necessary.
                5. Always select from the table associated with the requested field.
                6. Some requested fields could appear on multiple tables with different names, JOIN the tables and show all the fields that appear in both tables.
                7. Never use DELETE, INSERT, or UPDATE statements.
                8. If the user requested information about a column that does not exist, find the most similar column name in the schema and use it instead.
                '''
            },
          ],
        },
      ],
      // Se vuoi mantenere questi parametri di generazione (se supportati)
      'generationConfig': {'temperature': 0.2, 'topP': 0.8, 'topK': 40},
    };

    final response = await _restService.post(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$_apiKey',
      payload,
    );

    // Estrarre le parti di testo restituite dal modello
    if (response['candidates'] != null && response['candidates'].isNotEmpty) {
      return response['candidates'][0]['content']['parts'][0]['text'];
    }

    throw Exception('Failed to generate SQL query');
  }

  Future<String> analyzeQueryResults(
    String query,
    List<Map<String, dynamic>> results,
  ) async {
    // Converti i risultati a stringa (limitati i primi 10 per sicurezza)
    final resultsPreview =
        results.length > 10 ? results.sublist(0, 10) : results;
    final resultsStr = jsonEncode(resultsPreview);
    final totalResults = results.length;

    final payload = {
      'contents': [
        {
          'parts': [
            {
              'text':
                  'Analyze these query results and provide insights. '
                  'Suggest what types of charts would be appropriate.\n'
                  'Query: $query\n'
                  'Results (${resultsPreview.length} of $totalResults rows): $resultsStr\n'
                  'Format your response in these sections:\n'
                  '1. Summary of findings\n'
                  '2. Key insights\n'
                  '3. Recommended visualizations',
            },
          ],
        },
      ],
      'generationConfig': {'temperature': 0.7, 'topP': 0.95, 'topK': 40},
    };

    final response = await _restService.post(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$_apiKey',
      payload,
    );

    if (response['candidates'] != null && response['candidates'].isNotEmpty) {
      return response['candidates'][0]['content']['parts'][0]['text'];
    }

    throw Exception('Failed to analyze query results');
  }
}
