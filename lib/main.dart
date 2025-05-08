import 'package:flutter/material.dart';
import 'package:easy_query/services/rest_service.dart';
import 'package:easy_query/services/gemini_flash_service.dart';
import 'package:easy_query/services/big_query_service.dart';
import 'package:easy_query/pages/search_page.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_app_icons/flutter_app_icons.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:easy_query/services/cloud_storage_service.dart';

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

// fetchServiceJson
Future<String> fetchServiceJson() async {
  final response = await http.get(
    Uri.parse('https://get-service-api-key.lucaborrelli-work.workers.dev'),
  );

  if (response.statusCode == 200) {
    final data = json.decode(response.body);
    return data['apiKey'];
  } else {
    throw Exception('Failed to load service JSON');
  }
}

void main() async {
  final flutterAppIconsPlugin = FlutterAppIcons();
  final iconPath =
      kReleaseMode ? 'assets/assets/favicon.png' : 'assets/favicon.png';
  await flutterAppIconsPlugin.setIcon(icon: iconPath);
  // Initialize services
  WidgetsFlutterBinding.ensureInitialized();

  final restService = RestService();
  final apiKeyGemini = await fetchGeminiApiKey();

  print('API Gemini Key: $apiKeyGemini');
  final geminiService = GeminiFlashService(
    restService: restService,
    apiKey: apiKeyGemini, // Replace with actual API key
  );

  /// Recupera il JSON del Service Account dal relativo endpoint
  final serviceAccountJson = await fetchServiceJson();

  // Parsifica il JSON in Map (per verificare che il formato sia corretto)
  final Map<String, dynamic> serviceAccountMap = jsonDecode(serviceAccountJson);
  final String privateKey = serviceAccountMap['private_key'];
  print("Lunghezza della private_key: ${privateKey.length}");

  print('Service Account Map: $serviceAccountMap');

  // Se il campo 'private_key' contiene sequenze "\n" letterali, le converto in newline reali
  if (serviceAccountMap['private_key'] is String) {
    serviceAccountMap['private_key'] = (serviceAccountMap['private_key']
            as String)
        .replaceAllMapped(RegExp(r'\\n'), (match) => '\n');
  }
  final String credentialsJson = jsonEncode(serviceAccountMap);

  String projectId = serviceAccountMap['project_id'] ?? 'your-project-id';

  print('==================================================================');

  // Inizializza il servizio BigQuery con le credenziali ottenute
  final bigQueryService = BigQueryService(projectId: projectId);
  await bigQueryService.initialize(credentialsJson);

  // Initialize Cloud Storage service
  final cloudStorageService = CloudStorageService(projectId: projectId);
  await cloudStorageService.initialize(credentialsJson);

  runApp(
    MyApp(
      geminiService: geminiService,
      bigQueryService: bigQueryService,
      cloudStorageService: cloudStorageService,
    ),
  );
}

class MyApp extends StatelessWidget {
  final GeminiFlashService geminiService;
  final BigQueryService bigQueryService;
  final CloudStorageService cloudStorageService;

  const MyApp({
    super.key,
    required this.geminiService,
    required this.bigQueryService,
    required this.cloudStorageService,
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
        cloudStorageService: cloudStorageService,
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}
