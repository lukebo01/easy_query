import 'package:flutter/material.dart';
import 'package:easy_query/services/rest_service.dart';
import 'package:easy_query/services/gemini_flash_service.dart';
import 'package:easy_query/services/big_query_service.dart';
import 'package:easy_query/pages/search_page.dart';
import 'package:flutter/services.dart' show rootBundle;

void main() async {
  // Initialize services
  final restService = RestService();
  WidgetsFlutterBinding.ensureInitialized(); // Necessario per usare rootBundle
  String apiKeyGemini = await rootBundle.loadString('api_key_gemini.txt');
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
