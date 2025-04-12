import 'package:flutter/material.dart';
import 'package:easy_query/services/rest_service.dart';
import 'package:easy_query/services/gemini_flash_service.dart';
import 'package:easy_query/services/big_query_service.dart';
import 'package:easy_query/pages/search_page.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

Future<String> fetchGeminiApiKey() async {
  final response = await http.get(
    Uri.parse('https://get-gemini-api-key.lucaborrelli-work.workers.dev'),
  );

  if (response.statusCode == 200) {
    final data = json.decode(response.body);
    return data['apiKey'];
  } else {
    throw Exception('Failed to load Gemini API key');
  }
}

void main() async {
  // Initialize services
  WidgetsFlutterBinding.ensureInitialized();

  final restService = RestService();
  final apiKeyGemini = await fetchGeminiApiKey();

  print('API Gemini Key: $apiKeyGemini');
  final geminiService = GeminiFlashService(
    restService: restService,
    apiKey: apiKeyGemini, // Replace with actual API key
  );

  final bigQueryService = BigQueryService(projectId: 'YOUR_GCP_PROJECT_ID');

  // For demo purposes, we're not initializing BigQuery with credentials
  // In a real app, you would load credentials from a secure source
  // await bigQueryService.initialize(credentialsJson);

  runApp(MyApp(geminiService: geminiService, bigQueryService: bigQueryService));
}

class MyApp extends StatelessWidget {
  final GeminiFlashService geminiService;
  final BigQueryService bigQueryService;

  const MyApp({
    super.key,
    required this.geminiService,
    required this.bigQueryService,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EasyQuery',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: SearchPage(
        geminiService: geminiService,
        bigQueryService: bigQueryService,
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}
