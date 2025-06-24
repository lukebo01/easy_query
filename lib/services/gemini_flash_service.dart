import 'dart:convert';
import 'dart:developer' as dev;
import 'package:easy_query/services/rest_service.dart';

class GeminiFlashService {
  final RestService restService;
  final String apiKey;
  // Proprietà per memorizzare l'ultima analisi di contesto
  Map<String, dynamic>? _lastContextAnalysis;

  GeminiFlashService({required this.restService, required this.apiKey});

  // Metodo per accedere all'ultima analisi di contesto
  Map<String, dynamic>? getLastContextAnalysis() {
    return _lastContextAnalysis;
  }

  Future<Map<String, dynamic>> analyzeQueryContext(
    String userQuestion,
    String databaseSchema,
    String cloudFilesAndMetadata,
    List<String> tableNames,
    Map<String, List<Map<String, dynamic>>> sampleData,
  ) async {
    // Converti sampleData in una stringa JSON leggibile
    String sampleDataStr = '';
    sampleData.forEach((table, data) {
      if (data.isNotEmpty) {
        sampleDataStr += 'Table: $table\n';
        sampleDataStr += 'Sample rows (${data.length}):\n';
        sampleDataStr +=
            '${data.take(5).map((row) => row.toString()).join('\n')}\n\n';
      }
    });

    final payload = {
      'contents': [
        {
          'parts': [
            {
              'text': """
              Analize this question:
              
              $userQuestion
              
              Cloud files and their metadata: $cloudFilesAndMetadata
              
              Database schemas: $databaseSchema
              
              Sample data from tables: $sampleDataStr
              
              Analyze the question, database schemas, cloud files and sample data thoroughly, then:
              1. Identify ALL tables that could be relevant to the user's question (be inclusive rather than exclusive)
              2. For each relevant table, identify the key columns that should be included
              3. Look for semantic connections between columns by examining both column names AND actual data values
              4. For join conditions, don't rely only on column names but analyze the actual data to find potential foreign key relationships
              5. Consider fuzzy matching between similar values in different tables (e.g., "Electronics" in one table might correspond to "Electronic Devices" in another)
              6. Determine precise join conditions based on the actual data values, not just schema similarities
              7. Evaluate if cloud files are needed for the query considering their name, path, date and metadata; they will be trasformed in tables so suggest them ONLY IF NEEDED
              8. Cloud file names should be written with full and correct path, including the folder structure
              9. NEVER include file names form cloud files into the relevant tables list, use only the table names from the schemas for that scope
              
              ATTENTION:
              You must evaluate which bronze cloud files are needed for the query before analyzing the silver and gold tables.

              IMPORTANT: For join conditions, you MUST examine the actual sample data values to determine true relationships between tables, not just column names.
              
              Return your analysis as a JSON object with this structure:
              {
                "suggested_files": ["file1", "file2", "file3"],
                "relevant_tables": ["table1", "table2", "table3"],
                "relevant_columns": {
                  "table1": ["col1", "col2"],
                  "table2": ["col1", "col3"],
                  "table3": ["col1", "col4"]
                },
                "joins": [
                  {
                    "table1": "table1",
                    "column1": "id",
                    "table2": "table2",
                    "column2": "table1_id",
                    "join_type": "LEFT",
                    "matching_logic": "exact/fuzzy/substring",
                  }
                ]
              }
              """,
            },
          ],
        },
      ],
    };

    final response = await restService.post(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$apiKey',
      payload,
    );

    final text = response['candidates'][0]['content']['parts'][0]['text'];

    // Estrai il JSON dalla risposta
    final jsonStartIndex = text.indexOf('{');
    final jsonEndIndex = text.lastIndexOf('}') + 1;

    if (jsonStartIndex < 0 || jsonEndIndex <= jsonStartIndex) {
      throw Exception('Risposta non valida: impossibile estrarre JSON');
    }

    final jsonStr = text.substring(jsonStartIndex, jsonEndIndex);
    final contextAnalysis = json.decode(jsonStr);

    // Memorizza l'ultima analisi per uso futuro
    _lastContextAnalysis = contextAnalysis as Map<String, dynamic>;

    return contextAnalysis as Map<String, dynamic>;
  }

  Future<String> generateSqlQuery(
    String userQuestion,
    String schemas,
    String tableNames, {
    Map<String, List<Map<String, dynamic>>>? sampleData,
    Map<String, dynamic>? contextAnalysis,
  }) async {
    final payload = {
      'contents': [
        {
          'parts': [
            {
              'text': '''
            You are a SQL expert tasked with generating a BigQuery SQL query based on a user question.
            
            User question: $userQuestion

            Database schemas: $schemas
            
            Table names: $tableNames
            
            ${sampleData != null ? 'Sample data: ${jsonEncode(sampleData)}' : ''}
            
            ${contextAnalysis != null ? 'Context analysis: ${jsonEncode(contextAnalysis)}' : ''}
            
            IMPORTANT INSTRUCTIONS FOR SQL GENERATION (MANDATORY FOR ALL QUERIES):

            1. NON-PARTITIONED DATA STRUCTURE:
               All tables in the system are NOT Hive-partitioned. The date_partition column is a regular 
               string column in the format 'YYYY/MM/DD', not a partition key.
               
               When querying any table, especially those in 'silver_zone' dataset, avoid using any syntax
               that would treat date_partition as a partition key.
               
               ALWAYS treat date_partition as a regular string column that happens to contain date information.

            2. DATE FILTERING BEST PRACTICES:
               When filtering data by date, use TABLESAMPLE or limit your results if needed.
               
               For date comparison with 'date_partition' column:
               - Use PARSE_DATE('%Y/%m/%d', date_partition) to convert to DATE type
               - Example: WHERE PARSE_DATE('%Y/%m/%d', date_partition) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
               
               If a specific date range isn't provided in the user question, use a reasonable default like:
               "WHERE PARSE_DATE('%Y/%m/%d', date_partition) BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY) AND CURRENT_DATE()"
              
            Generate a single SQL query that answers the user's question.
            Ensure that your query:
            1. Uses standard BigQuery SQL syntax
            2. Includes all necessary JOINs based on the schema
            3. Applies appropriate filters based on the user's question
            4. Formats dates and timestamps properly
            5. Handles any aggregations or grouping required
            6. Uses appropriate column aliases for readability
            7. Sorts results in a logical order
            8. Limits the result with LIMIT 50 !
            9. Uses appropriate functions for text manipulation, date handling, etc.
            10. Does not include any comments or explanations in the SQL itself
            
            Return only the SQL query without any additional text or explanations.
              ''',
            },
          ],
        },
      ],
      'generationConfig': {'temperature': 0.2, 'topP': 0.8, 'topK': 40},
    };

    final response = await restService.post(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$apiKey',
      payload,
    );

    if (response['candidates'] != null && response['candidates'].isNotEmpty) {
      final sqlQuery =
          response['candidates'][0]['content']['parts'][0]['text'].trim();
      // Clean up any markdown code blocks if present
      return sqlQuery.replaceAll('```sql', '').replaceAll('```', '').trim();
    }

    throw Exception('Failed to generate SQL query');
  }

  /* NEW CODE + REFACTORED CODE below */

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

  /* -- AI AGENTS PIPELINE FOR QUERY GENERATION -- */

  /// Analyze user intent from a natural language question
  Future<Map<String, dynamic>> analyzeIntent(String userQuestion) async {
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
    String bronzeMetadata,
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
  Future<Map<String, dynamic>> goldAndSilverDiscovery(
    String userIntent,
    String silverSchemas,
    String goldSchemas,
  ) async {
    try {
      // Build prompt for the LLM
      final prompt = '''
      Sei un esperto di Big Data e data lineage. Ti sono state suggerite delle tabelle (con schemas e prime ennuple) da valutare,
      il tuo compito è individuare quali tabelle sono utili per soddisfare gli intenti dell'utente. Prima di suggerire una tabella Silver
      controlla se questa abbia versioni più recenti o versioni Gold, in quel caso preferisci le altre versioni.

      Rispondi solo con un output strutturato contenente i nomi delle tabelle suggerite nella forma:

      output: {suggested_silver_tables:['table1','table2', ...]
               , suggested_gold_tables:['table1','table2', ...]}

      User Intent: $userIntent

      Silver Schemas: $silverSchemas

      Gold Schemas: $goldSchemas
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
    String selectedSilverSchemas,
    String selectedGoldSchemas,
  ) async {
    try {
      // Build prompt for the LLM
      final prompt = '''
      Sei un architetto dati. Ricevi gli intenti utente e una lista di tabelle Silver e Gold rilevanti con i loro schemi.
      Definisci un piano per una query SQL BigQuery: quali tabelle usare, join logici, filtri, e aggregazioni.

      Rispondi solo con una spiegazione chiara in linguaggio naturale.

      User Intent: $userIntent

      Selected Silver Schemas: $selectedSilverSchemas

      Selected Gold Schemas: $selectedGoldSchemas
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
    String selectedSilverSchemas,
    String selectedGoldSchemas,
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
  Future<Map<String, dynamic>> validateSchemasAndCorrectQuery(
    String sqlQuery,
    String selectedDatabaseSchemas,
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
      Sei un esperto di SQL e di BigQuery. Ricevi una query SQL e il tuo compito è quello di correggere eventuali errori di sintassi.

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
