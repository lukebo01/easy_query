import 'dart:convert';
import 'dart:developer' as dev;
import 'package:easy_query/services/rest_service.dart';

class GeminiFlashService {
  final RestService restService;
  final String apiKey;
  // Proprietà per memorizzare l'ultima analisi di contesto
  Map<String, dynamic>? _lastContextAnalysis;
  GeminiFlashService({required this.restService, required this.apiKey});

  /// Genera una risposta di testo generica con Gemini
  Future<dynamic> generateText(
    String prompt, {
    double temperature = 0.2,
    double topP = 0.9,
    int topK = 40,
  }) async {
    try {
      final payload = {
        'contents': [
          {
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'generationConfig': {
          'temperature': temperature,
          'topP': topP,
          'topK': topK,
        },
      };

      // Utilizza gemini-2.0-flash invece di gemini-pro per mantenere coerenza con gli altri metodi
      final response = await restService.post(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$apiKey',
        payload,
      );

      if (response['candidates'] != null && response['candidates'].isNotEmpty) {
        return response['candidates'][0]['content']['parts'][0]['text'].trim();
      }

      throw Exception('No text in Gemini response');
    } catch (e) {
      dev.log('Error generating text with Gemini: $e', error: e);
      throw Exception('Failed to generate text with Gemini: $e');
    }
  }

  /// Traduci in inglese un testo in italiano
  Future<String> translateToEnglish(String italianText) async {
    try {
      // Build prompt for the LLM
      final prompt = '''
      Sei un traduttore esperto. Il tuo compito è tradurre il seguente testo dall'italiano all'inglese mantenendo il significato
      originale e utilizzando un linguaggio naturale fluente.

      Testo in italiano: $italianText

      Rispondi solo con la traduzione in inglese senza aggiungere altro testo.
      ''';

      // Get response from LLM
      final response = await generateText(
        prompt,
        temperature: 0.2,
        topP: 0.9,
        topK: 40,
      );
      return response;
    } catch (e) {
      dev.log('Error translating to English: $e', error: e);
      throw Exception('Failed to translate to English: $e');
    }
  }

  /* -- AI AGENTS PIPELINE FOR QUERY GENERATION -- */

  /// Analyze user intent from a natural language question
  Future<String> analyzeIntent(String userQuestion) async {
    try {
      // Build prompt for the LLM
      final prompt = '''
      Sei un analizzatore semantico. Ricevi una richiesta in linguaggio naturale e devi estrarre: 
      intenti principali, entità (persone, oggetti, prodotti), intervalli temporali, metriche, condizioni di filtro, e possibili sinonimi 
      usati nel dominio aziendale.
      
      Rispondi solo con un output strutturato con campi chiave, ad es. { "kpi": "vendite", "entità": ["prodotti"], "tempo": "ultimi 6 mesi" }

      User Question: $userQuestion
      ''';

      // Get response from LLM
      final response = await generateText(
        prompt,
        temperature: 0.2,
        topP: 0.9,
        topK: 40,
      );

      return response;
    } catch (e) {
      dev.log('Error analyzing user intent: $e', error: e);
      throw Exception('Failed to analyze user intent: $e');
    }
  }

  /// Suggest bronze files based on user intent and metadata
  Future<Map<String, dynamic>> suggestBronzeFiles(
    String userIntent,
    List<Map<String, dynamic>> bronzeMetadata,
  ) async {
    try {
      // Build prompt for the LLM
      final prompt = '''
      Sei un esperto di data engineering. Il tuo compito è quello di valutare i metadati di una serie di file che ti vengono proposti 
      in relazione all'intento dell'utente. Devi valutare attentamente se alcuni dei file (non sempre strutturati) proposti sono utili 
      per rispondere all'utente.

      Prima di consigliare un file valuta se i dati sono aggiornati e se contengono informazioni
      in linea con gli intenti della richiesta, se i metadati mostrano che il file è stato già trasformato allora NON includerlo.

      Rispondi solo con un output strutturato contenente i nomi (completi di percorso) dei file bronze suggeriti nella forma: 
      suggested_files:['path/to/file1','path/to/file2', ...]

      User Intent: $userIntent

      Bronze Metadata: $bronzeMetadata
      ''';

      // Get response from LLM
      final response = await generateText(
        prompt,
        temperature: 0.3,
        topP: 0.85,
        topK: 50,
      );

      return response;
    } catch (e) {
      dev.log('Error suggesting bronze files: $e', error: e);
      throw Exception('Failed to suggest bronze files: $e');
    }
  }

  /// Suggest gold and silver schemas based on user intent and existing schemas
  Future<List<Map<String, dynamic>>> goldAndSilverDiscovery(
    String userIntent,
    List<Map<String, dynamic>> goldAndSilverSchemas,
    Map<String, List<Map<String, dynamic>>> goldAndSilverSamples,
  ) async {
    try {
      // Build prompt for the LLM
      final prompt = '''
      Sei un esperto di Big Data e data lineage. Ti sono state suggerite delle tabelle (con schemas e prime ennuple) da valutare,
      il tuo compito è individuare quali tabelle sono utili per soddisfare gli intenti dell'utente.
      
      Prima di suggerire una tabella Silver controlla se questa abbia versioni più recenti o versioni Gold,
      in quel caso preferisci le altre versioni.

      Rispondi solo con un output strutturato contenente i nomi delle tabelle suggerite nella forma:

      output: {suggested_silver_tables:['table1','table2', ...]
               , suggested_gold_tables:['table1','table2', ...]}

      User Intent: $userIntent

      Gold and Silver Schemas: $goldAndSilverSchemas

      Gold and Silver Samples: $goldAndSilverSamples
      ''';

      // Get response from LLM
      final response = await generateText(
        prompt,
        temperature: 0.3,
        topP: 0.85,
        topK: 50,
      );

      return response;
    } catch (e) {
      dev.log('Error retrieving gold and silver schemas: $e', error: e);
      throw Exception('Failed to suggest gold and silver schemas: $e');
    }
  }

  /// Plan a query based on user intent and selected schemas
  Future<String> planQuery(
    String userIntent,
    Map<String, dynamic> selectedSchemas,
  ) async {
    try {
      // Build prompt for the LLM
      final prompt = '''
      Sei un architetto di dati. Ricevi gli intenti utente e una lista di tabelle Silver e Gold rilevanti con i loro schemi.
      Definisci un piano per una query SQL BigQuery: quali tabelle usare, join logici, filtri, e aggregazioni.

      Individua connessioni semantiche tra le colonne esaminando sia i nomi delle colonne che i valori effettivi dei dati.

      Considera il fuzzy matching tra valori simili in diverse tabelle (ad esempio, "Elettronica" in una tabella potrebbe corrispondere a "Dispositivi Elettronici" in un'altra).

      Rispondi solo con una spiegazione chiara in linguaggio naturale.

      User Intent: $userIntent

      Selected table Schemas: $selectedSchemas
      ''';

      // Get response from LLM
      final response = await generateText(
        prompt,
        temperature: 0.4,
        topP: 0.9,
        topK: 40,
      );

      return response;
    } catch (e) {
      dev.log('Error planning query: $e', error: e);
      throw Exception('Failed to plan query: $e');
    }
  }

  /// Generate a SQL query based on the user intent and planned query
  Future<String> buildQuery(
    String userIntent,
    String plannedQuery,
    Map<String, dynamic> selectedSchemas,
  ) async {
    try {
      // Build prompt for the LLM
      final prompt = '''
      Sei un esperto di SQL e di BigQuery. Ricevi gli intenti dell'utente e un piano di query definito da un esperto.
      Il tuo compito è quello di soddisfare l'intento dell'utente costruendo una query BigQuery seguendo attentamente il piano
      che ti è stato fornito.

      Rispondi solo con la query SQL senza spiegazioni.

      User Intent: $userIntent

      Planned Query: $plannedQuery

      Selected table Schemas: $selectedSchemas
      ''';

      // Get response from LLM
      final response = await generateText(
        prompt,
        temperature: 0.5,
        topP: 0.95,
        topK: 40,
      );

      return response;
    } catch (e) {
      dev.log('Error building query: $e', error: e);
      throw Exception('Failed to build query: $e');
    }
  }

  /// Validate the SQL query against the database schema
  Future<String> validateSchemasAndCorrectQuery(
    String sqlQuery,
    Map<String, dynamic> selectedDatabaseSchemas,
  ) async {
    try {
      // Build prompt for the LLM
      final prompt = '''
      Sei un esperto di SQL e di BigQuery. Ricevi una query SQL e una serie di schemi di database.

      Il tuo compito è quello di validare e correggere la query rispetto agli schemi, verificando la 
      presenza delle tabelle e colonne nello schema

      Sostituisci i nomi di tabelle e di colonne che non corrispondono a quelli a tua disposizione
      con quelli più appropriati, lascia tutto il resto invariato.

      Rispondi soltanto con la query SQL corretta.

      SQL Query: $sqlQuery

      Database Schema: $selectedDatabaseSchemas
      ''';

      // Get response from LLM
      final response = await generateText(
        prompt,
        temperature: 0.1,
        topP: 0.8,
        topK: 30,
      );

      return response;
    } catch (e) {
      dev.log('Error correcting query: $e', error: e);
      throw Exception('Failed to correct query: $e');
    }
  }

  /// Correct the syntax of the SQL query
  Future<String> correctQuerySyntax(String sqlQuery) async {
    try {
      // Build prompt for the LLM
      final prompt = '''
      Sei un esperto di SQL e di BigQuery. Ricevi una query SQL e il tuo compito è quello di correggere eventuali errori di sintassi e di migliorare
      la qualità della query.

      Assicurati che la query sia conforme agli standard di BigQuery e che utilizzi le migliori pratiche.

      Racchiudi ogni nome di tabella e colonna tra backtick (``) per evitare conflitti con parole chiave riservate.

      Formatta le date e i timestamp in modo appropriato e utilizza le funzioni corrette per la manipolazione dei testi.

      Rispondi soltanto con la query SQL corretta.

      SQL Query: $sqlQuery
      ''';

      // Get response from LLM
      final response = await generateText(
        prompt,
        temperature: 0.1,
        topP: 0.8,
        topK: 30,
      );

      return response;
    } catch (e) {
      dev.log('Error correcting query syntax: $e', error: e);
      throw Exception('Failed to correct query syntax: $e');
    }
  }

  /* -- AI AGENT FOR QUERY ANALYSIS -- */
  /// Analyze query results to generate insights
  Future<String> analyzeQueryResults(
    String sqlQuery,
    List<Map<String, dynamic>> results,
  ) async {
    try {
      // Build prompt for the LLM
      final prompt = '''
      You are a data analysis expert tasked with analyzing the results of a SQL query.
      
      SQL Query: $sqlQuery
      
      Results: ${jsonEncode(results)}
      
      Please provide a detailed analysis of these results, including:
      
      1. A summary of the key findings
      2. Interpretation of any trends, patterns, or anomalies
      3. Actionable insights or recommendations based on the data
      4. Any limitations of the data or analysis
      
      Format your analysis with clear headings and bullet points where appropriate.
      ''';

      // Get response from LLM
      final response = await generateText(prompt);

      // Extract the path from the response
      return _extractPathFromResponse(response);
    } catch (e) {
      print('Error analyzing query results: $e');
      throw Exception('Failed to analyze query results: $e');
    }
  }

  /* -- AI AGENT FOR FILE PATH SUGGESTION -- */
  /// Suggest a file path based on content analysis
  Future<String> suggestFilePath(
    String bucketStructure,
    Map<String, String> fileMetadata,
    String fileContent,
  ) async {
    try {
      // Build prompt for the LLM
      final prompt = '''
      Analyze the following bucket structure and file metadata. 
      Suggest the most appropriate storage path in the format folder/subfolder/ based on:
      1. The existing bucket structure
      2. The file type and content
      3. The tags and metadata provided
      4. The context of the file (e.g., if it's a report, image, etc.)

      BUCKET STRUCTURE:
      $bucketStructure

      FILE METADATA:
      ${fileMetadata.entries.map((e) => '${e.key}: ${e.value}').join('\n')}

      FILE CONTENT (sample):
      ${fileContent ?? 'Binary file - content not available'}

      Respond ONLY with the suggested path in the format /folder/subfolder/ without adding the filename.
      If new folders need to be created, briefly explain why.
      ''';

      // Get response from LLM
      final response = await generateText(prompt);

      // Extract the path from the response
      return _extractPathFromResponse(response);
    } catch (e) {
      print('Error suggesting file path: $e');
      throw Exception('Failed to suggest file path: $e');
    }
  }

  /// Extract a path from LLM response
  String _extractPathFromResponse(String response) {
    // Look for a pattern that resembles a path
    final RegExp pathRegex = RegExp(r'\/[a-zA-Z0-9_\-\/]+\/?');
    final match = pathRegex.firstMatch(response);

    if (match != null) {
      String path = match.group(0) ?? '';

      // Ensure the path starts with / and ends with /
      if (!path.startsWith('/')) {
        path = '/$path';
      }
      if (!path.endsWith('/')) {
        path = '$path/';
      }

      return path;
    }

    // If no path pattern is found, extract the first line as a suggestion
    final firstLine = response.split('\n').first.trim();
    if (firstLine.isNotEmpty) {
      return firstLine.startsWith('/') ? firstLine : '/$firstLine';
    }

    return '/'; // Default: root of the bucket
  }
}
