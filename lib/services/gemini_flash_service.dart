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
  ) async {
    final payload = {
      'contents': [
        {
          'parts': [
            {
              'text':
                  'You are a SQL expert. Convert this question to a SQL for Big Query (Standard SQL) query '
                  'based on the provided schema.\n'
                  'Question: $userQuestion\n'
                  'Database Schema: $databaseSchema\n'
                  'Generate only the SQL query without any explanations.',
            },
          ],
        },
      ],
      // Se vuoi mantenere questi parametri di generazione (se supportati)
      'generationConfig': {'temperature': 0.2, 'topP': 0.8, 'topK': 40},
    };

    // NOTA: endpoint aggiornato alla versione v1beta e al modello gemini-1.5-flash
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
