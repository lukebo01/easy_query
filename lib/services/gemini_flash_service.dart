import 'dart:convert';
import 'dart:developer' as dev;
import 'package:easy_query/services/rest_service.dart';

class GeminiFlashService {
  final RestService restService;
  final String apiKey;
  
  // Costanti per i limiti di token
  static const int MAX_TOKEN_LIMIT = 90000;  // Limite massimo approssimativo per Gemini 2.0 Flash
  static const double TOKEN_CHAR_RATIO = 4.0; // Approssimativamente 4 caratteri per token
  
  /// Crea un'istanza del servizio Gemini Flash
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

      dev.log('User intent analysis: $response');

      return response;
    } catch (e) {
      dev.log('Error analyzing user intent: $e', error: e);
      throw Exception('Failed to analyze user intent: $e');
    }
  }

  /// Suggest bronze files based on user intent and metadata
  Future<List<String>> suggestBronzeFiles(
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

      Rispondi solo con un output strutturato JSON contenente i nomi (completi di percorso) dei file bronze suggeriti nella forma: 
      {"suggested_files":["path/to/file1","path/to/file2"]}

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

      // Clean the response from markdown formatting
      String cleanedResponse = response.trim();
      if (cleanedResponse.startsWith('```json')) {
        cleanedResponse = cleanedResponse.substring(7);
      }
      if (cleanedResponse.endsWith('```')) {
        cleanedResponse = cleanedResponse.substring(
          0,
          cleanedResponse.length - 3,
        );
      }
      cleanedResponse = cleanedResponse.trim();

      // Parse the JSON response
      final Map<String, dynamic> parsedResponse = jsonDecode(cleanedResponse);

      // Extract the list and convert to List<String>
      final List<String> suggestedFiles =
          (parsedResponse['suggested_files'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [];

      return suggestedFiles;
    } catch (e) {
      dev.log('Error suggesting bronze files: $e', error: e);
      throw Exception('Failed to suggest bronze files: $e');
    }
  }

  /// Suggest gold and silver schemas based on user intent and existing schemas
  Future<Map<String, List<String>>> goldAndSilverDiscovery(
    String userIntent,
    List<Map<String, dynamic>> goldAndSilverSchemas,
    Map<String, List<Map<String, dynamic>>> goldAndSilverSamples,
    {List<String> recentlyCreatedTables = const []}
  ) async {
    try {
      // Build prompt for the LLM
      final prompt = '''
      Sei un esperto di Big Data e data lineage. Ti sono state suggerite delle tabelle (con schemas e prime ennuple) da valutare,
      il tuo compito è individuare quali tabelle sono utili per soddisfare gli intenti dell'utente.
      
      IMPORTANTE:
      ${recentlyCreatedTables.isNotEmpty ? '*** TABELLE RECENTEMENTE CREATE: ${recentlyCreatedTables.join(', ')} ***\nQueste tabelle sono state APPENA create dalla trasformazione bronze-to-silver e DEVONO ESSERE INCLUSE nella tua selezione finale.' : ''}
      1. Se ci sono tabelle recentemente create dalla trasformazione bronze-to-silver, DEVI ASSOLUTAMENTE includerle nella tua selezione, anche se non sembrano perfettamente correlate all'intento dell'utente
      2. Dai massima priorità alle tabelle più recenti e appena create, in quanto molto probabilmente contengono i dati più rilevanti per la query dell'utente
      3. Se un nome di tabella contiene parole chiave presenti nell'intento dell'utente, è altamente probabile che sia la tabella corretta da utilizzare
      4. Non trascurare le tabelle Silver anche se possono esistere versioni Gold, valuta sempre prima il contenuto e la rilevanza
      5. Se l'intento dell'utente menziona esplicitamente un file o un tipo di documento, cerca tabelle che contengano nomi simili
      6. Se hai da poco elaborato un file bronze in silver, quel file DEVE essere incluso nella query finale
      
      Prima di suggerire una tabella Silver controlla se questa abbia versioni più recenti o versioni Gold,
      in quel caso preferisci le altre versioni.

      Rispondi solo con un output strutturato contenente i nomi delle tabelle suggerite nella forma:

      {"suggested_silver_tables":["table1","table2"],"suggested_gold_tables":["table1","table2"]}

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

      // Clean the response from markdown formatting
      String cleanedResponse = response.trim();
      if (cleanedResponse.startsWith('```json')) {
        cleanedResponse = cleanedResponse.substring(7);
      }
      if (cleanedResponse.endsWith('```')) {
        cleanedResponse = cleanedResponse.substring(
          0,
          cleanedResponse.length - 3,
        );
      }
      cleanedResponse = cleanedResponse.trim();

      // Parse the JSON response
      final Map<String, dynamic> parsedResponse = jsonDecode(cleanedResponse);

      // Extract the lists and convert to List<String>
      final List<String> suggestedSilverTables =
          (parsedResponse['suggested_silver_tables'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [];

      final List<String> suggestedGoldTables =
          (parsedResponse['suggested_gold_tables'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [];

      return {
        'suggested_silver_tables': suggestedSilverTables,
        'suggested_gold_tables': suggestedGoldTables,
      };
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

      IMPORTANTE: Le tabelle hanno nomi completi nel formato 'progetto.dataset.tabella'. Fa riferimento a questi nomi esatti.

      Individua connessioni semantiche tra le colonne esaminando sia i nomi delle colonne che i valori effettivi dei dati.

      Considera il fuzzy matching tra valori simili in diverse tabelle (ad esempio, "Elettronica" in una tabella potrebbe corrispondere a "Dispositivi Elettronici" in un'altra).

      Rispondi solo con una spiegazione chiara in linguaggio naturale che includa i nomi esatti delle tabelle da utilizzare.

      User Intent: $userIntent

      Selected table Schemas (nomi completi delle tabelle): $selectedSchemas
      ''';

      // Get response from LLM
      final response = await generateText(
        prompt,
        temperature: 0.4,
        topP: 0.9,
        topK: 40,
      );

      dev.log('Query plan: $response');

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

      IMPORTANTE: Utilizza SOLO i nomi delle tabelle esatti forniti negli schemi. NON utilizzare nomi generici come 'your_project' o 'your_dataset'.
      Ogni tabella negli schemi ha un nome completo nel formato 'progetto.dataset.tabella' - usa esattamente questi nomi.

      Racchiudi tutti i nomi di tabelle e colonne tra backtick (``) per evitare conflitti con parole riservate.

      Rispondi solo con la query SQL senza spiegazioni.

      User Intent: $userIntent

      Planned Query: $plannedQuery

      Selected table Schemas (usa esattamente questi nomi di tabelle): $selectedSchemas
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
      presenza delle tabelle e colonne nello schema.

      IMPORTANTE: 
      1. Utilizza SOLO i nomi delle tabelle esatti forniti negli schemi
      2. NON utilizzare nomi generici come 'your_project', 'your_dataset', ecc.
      3. Ogni tabella negli schemi ha un nome completo nel formato 'progetto.dataset.tabella' - usa esattamente questi nomi
      4. Racchiudi tutti i nomi di tabelle e colonne tra backtick (``)

      Sostituisci i nomi di tabelle e di colonne che non corrispondono a quelli a tua disposizione
      con quelli più appropriati basandoti sugli schemi forniti. Lascia tutto il resto invariato.

      Rispondi soltanto con la query SQL corretta.

      SQL Query: $sqlQuery

      Database Schema (usa esattamente questi nomi di tabelle): $selectedDatabaseSchemas
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

      IMPORTANTE:
      1. Racchiudi ogni nome di tabella e colonna tra backtick (``) per evitare conflitti con parole chiave riservate
      2. Formatta le date e i timestamp in modo appropriato e utilizza le funzioni corrette per la manipolazione dei testi
      3. Per le conversioni di tipo, usa SAFE_CAST invece di CAST per evitare errori su valori non validi
      4. Quando converti stringhe in numeri, aggiungi filtri per escludere valori NULL o non numerici
      5. Usa REGEXP_CONTAINS per identificare valori numerici validi prima della conversione
      6. Gestisci i valori misti (numerici e testuali) nelle colonne usando condizioni WHERE appropriate

      Esempio di conversione sicura:
      SAFE_CAST(column AS INT64) invece di CAST(column AS INT64)
      WHERE REGEXP_CONTAINS(column, r'^[0-9]+\$') per filtrare solo valori numerici

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

  // Aggiungi questa funzione nel GeminiFlashService
List<Map<String, dynamic>> sanitizeQueryResults(List<Map<String, dynamic>> results) {
  return results.map((row) {
    final sanitizedRow = <String, dynamic>{};
    row.forEach((key, value) {
      if (value is double) {
        if (value.isInfinite) {
          // Converti infinito in stringa indicativa
          sanitizedRow[key] = value.isNegative ? "-Infinity" : "Infinity";
        } else if (value.isNaN) {
          // Converti NaN in null o in un valore di placeholder
          sanitizedRow[key] = null;
        } else {
          sanitizedRow[key] = value;
        }
      } else {
        sanitizedRow[key] = value;
      }
    });
    return sanitizedRow;
  }).toList();
}

  /* -- AI AGENT FOR QUERY ANALYSIS -- */
  /// Analyze query results to generate insights
  Future<String> analyzeQueryResults(
    String sqlQuery,
    List<Map<String, dynamic>> results,
  ) async {
    var sanitizedResults = sanitizeQueryResults(results);
    try {
      // Build prompt for the LLM
      final prompt = '''
      You are a data analysis expert tasked with analyzing the results of a SQL query.
      
      SQL Query: $sqlQuery
      
      Results: ${jsonEncode(sanitizedResults)}
      
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

  /// Stima il numero di token in un testo
  int estimateTokenCount(String text) {
    // Un'approssimazione molto semplificata: circa 4 caratteri per token
    // Questa è una stima grezza e non tiene conto di tokenizzazione specifica
    return (text.length / TOKEN_CHAR_RATIO).ceil();
  }
  
  /// Verifica se un prompt supera il limite di token
  bool exceedsTokenLimit(String prompt, {int maxTokens = MAX_TOKEN_LIMIT}) {
    int estimatedTokens = estimateTokenCount(prompt);
    return estimatedTokens > maxTokens;
  }

  /// Divide una lista di dati in batch più piccoli per evitare di superare i limiti di token
  List<List<T>> createBatches<T>(List<T> items, int maxBatchSize) {
    if (items.isEmpty) return [];
    
    List<List<T>> batches = [];
    for (int i = 0; i < items.length; i += maxBatchSize) {
      int end = (i + maxBatchSize < items.length) ? i + maxBatchSize : items.length;
      batches.add(items.sublist(i, end));
    }
    return batches;
  }

  /// Versione a batch di suggestBronzeFiles
  Future<List<String>> batchedSuggestBronzeFiles(
    String userIntent,
    List<Map<String, dynamic>> bronzeMetadata,
  ) async {
    // Se i metadati sono pochi, usa la funzione normale
    final testPrompt = """
      User Intent: $userIntent
      Bronze Metadata: ${jsonEncode(bronzeMetadata)}
    """;
    
    if (!exceedsTokenLimit(testPrompt)) {
      return await suggestBronzeFiles(userIntent, bronzeMetadata);
    }
    
    // Altrimenti, suddividi in batch
    dev.log("Metadata too large, processing in batches");
    final batches = createBatches(bronzeMetadata, 50); // Inizia con batch di 50 elementi
    dev.log("Created ${batches.length} batches");
    
    Set<String> allSuggestedFiles = {};
    
    for (var batch in batches) {
      try {
        final batchResults = await suggestBronzeFiles(userIntent, batch);
        allSuggestedFiles.addAll(batchResults);
      } catch (e) {
        dev.log("Error in batch processing: $e");
        // Se un batch è ancora troppo grande, riduci ulteriormente
        if (batch.length > 10) {
          final smallerBatches = createBatches(batch, batch.length ~/ 2);
          for (var smallerBatch in smallerBatches) {
            try {
              final results = await suggestBronzeFiles(userIntent, smallerBatch);
              allSuggestedFiles.addAll(results);
            } catch (e) {
              dev.log("Error in smaller batch: $e");
            }
          }
        }
      }
    }
    
    return allSuggestedFiles.toList();
  }
  
  /// Versione a batch di goldAndSilverDiscovery
  Future<Map<String, List<String>>> batchedGoldAndSilverDiscovery(
    String userIntent,
    List<Map<String, dynamic>> goldAndSilverSchemas,
    Map<String, List<Map<String, dynamic>>> goldAndSilverSamples,
    {List<String> recentlyCreatedTables = const []}
  ) async {
    // Verifica iniziale
    final testPrompt = """
      User Intent: $userIntent
      Gold and Silver Schemas: ${jsonEncode(goldAndSilverSchemas)}
      Gold and Silver Samples: ${jsonEncode(goldAndSilverSamples)}
    """;
    
    if (!exceedsTokenLimit(testPrompt)) {
      return await goldAndSilverDiscovery(
        userIntent, 
        goldAndSilverSchemas, 
        goldAndSilverSamples,
        recentlyCreatedTables: recentlyCreatedTables
      );
    }
    
    dev.log("Schema and sample data too large, processing in batches");
    
    // Creiamo batch per gli schemi
    final schemaBatches = createBatches(goldAndSilverSchemas, 10);
    dev.log("Created ${schemaBatches.length} schema batches");
    
    Set<String> suggestedSilverTables = {};
    Set<String> suggestedGoldTables = {};
    
    // Elabora ogni batch di schemi con un sottoinsieme di campioni relativi
    for (var schemaBatch in schemaBatches) {
      // Estrai solo i campioni pertinenti per questo batch di schemi
      Map<String, List<Map<String, dynamic>>> relevantSamples = {};
      for (var schema in schemaBatch) {
        // Estrai il nome della tabella dallo schema
        String? tableName;
        if (schema['tableReference'] != null) {
          var tableRef = schema['tableReference'];
          tableName = '${tableRef['projectId']}.${tableRef['datasetId']}.${tableRef['tableId']}';
        }
        
        if (tableName != null && goldAndSilverSamples.containsKey(tableName)) {
          // Limita i campioni se sono troppi
          var samples = goldAndSilverSamples[tableName]!
              .map((sample) => sample as Map<String, dynamic>)
              .toList();
          relevantSamples[tableName] = samples.length > 5 ? samples.sublist(0, 5) : samples;
        }
      }
      
      try {
        final batchResults = await goldAndSilverDiscovery(
          userIntent, 
          schemaBatch, 
          relevantSamples,
          recentlyCreatedTables: recentlyCreatedTables
        );
        
        suggestedSilverTables.addAll(batchResults['suggested_silver_tables'] as List<String>);
        suggestedGoldTables.addAll(batchResults['suggested_gold_tables'] as List<String>);
      } catch (e) {
        dev.log("Error in batch processing: $e");
        // Se ancora troppo grande, prova con batch più piccoli
        if (schemaBatch.length > 2) {
          final smallerBatches = createBatches(schemaBatch, schemaBatch.length ~/ 2);
          for (var smallerBatch in smallerBatches) {
            try {
              final results = await goldAndSilverDiscovery(
                userIntent, 
                smallerBatch, 
                relevantSamples,
                recentlyCreatedTables: recentlyCreatedTables
              );
              suggestedSilverTables.addAll(results['suggested_silver_tables'] as List<String>);
              suggestedGoldTables.addAll(results['suggested_gold_tables'] as List<String>);
            } catch (e) {
              dev.log("Error in smaller batch: $e");
            }
          }
        }
      }
    }
    
    return {
      'suggested_silver_tables': suggestedSilverTables.toList(),
      'suggested_gold_tables': suggestedGoldTables.toList(),
    };
  }
  
  /// Versione a batch di analyzeQueryResults
  Future<String> batchedAnalyzeQueryResults(
    String sqlQuery,
    List<Map<String, dynamic>> results,
  ) async {
    // Sanitizza i risultati per evitare errori con valori non serializzabili
    var sanitizedResults = sanitizeQueryResults(results);
    
    // Verifica se il prompt completo sta nei limiti
    final testPrompt = """
      SQL Query: $sqlQuery
      Results: ${jsonEncode(sanitizedResults)}
    """;
    
    if (!exceedsTokenLimit(testPrompt)) {
      return await analyzeQueryResults(sqlQuery, sanitizedResults);
    }
    
    dev.log("Query results too large, processing with sample");
    
    // Usa un campione dei risultati invece dell'intero set
    const maxRows = 100;
    List<Map<String, dynamic>> sampledResults;
    
    if (sanitizedResults.length > maxRows) {
      // Prendi un campione rappresentativo: inizio, metà e fine
      final startSample = sanitizedResults.take(maxRows ~/ 3).toList();
      final midStart = sanitizedResults.length ~/ 2 - (maxRows ~/ 6);
      final midSample = sanitizedResults.sublist(midStart, midStart + (maxRows ~/ 3));
      final endSample = sanitizedResults.skip(sanitizedResults.length - (maxRows ~/ 3)).toList();
      
      sampledResults = [...startSample, ...midSample, ...endSample];
    } else {
      sampledResults = sanitizedResults;
    }
    
    // Aggiungi metadati sul campionamento
    final analysisWithSamplingNote = await analyzeQueryResults(sqlQuery, sampledResults);
    return "Note: This analysis is based on a sample of ${sampledResults.length} rows from a total of ${results.length} rows.\n\n$analysisWithSamplingNote";
  }
}
