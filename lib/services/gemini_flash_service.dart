import 'dart:convert';
import 'dart:developer' as dev;
import 'package:easy_query/services/rest_service.dart';

class GeminiFlashService {
  final RestService _restService;
  final String _apiKey;

  GeminiFlashService({required RestService restService, required String apiKey})
    : _restService = restService,
      _apiKey = apiKey;

  /// Translate user question to English if needed
  Future<String> translateToEnglish(String userQuestion) async {
    final payload = {
      'contents': [
        {
          'parts': [
            {
              'text': '''
                If the following text is not in English, translate it to English. If it's already in English, return it unchanged.
                Text: $userQuestion
                Return only the translated or original text without any explanations.
              ''',
            },
          ],
        },
      ],
      'generationConfig': {'temperature': 0.1},
    };

    final response = await _restService.post(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$_apiKey',
      payload,
    );

    if (response['candidates'] != null && response['candidates'].isNotEmpty) {
      return response['candidates'][0]['content']['parts'][0]['text'].trim();
    }

    // If translation fails, return original text
    return userQuestion;
  }

  /// Analyze schemas and sample data to identify relevant tables for the query
  Future<Map<String, dynamic>> analyzeQueryContext(
    String userQuestion,
    String databaseSchema,
    String cloudFilesAndMetadata,
    List<String> tableNames,
    Map<String, List<Map<String, dynamic>>> sampleData,
  ) async {
    // Convert sample data to a string format
    final sampleDataStr = jsonEncode(sampleData);

    final payload = {
      'contents': [
        {
          'parts': [
            {
              'text': '''
            You are a data analyst tasked with identifying ALL relevant tables for a query and their precise relationships. You'll analyze the user's question, database schemas from tabels in BigQuery, files in Google Cloud Storage and sample data to provide a comprehensive analysis.
            
            User question: $userQuestion

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
                  "data_example": "Sample values that match between these columns"
                }
              ],
              "unions": [
                {
                  "tables": ["table1", "table3"],
                  "mapping": {
                    "table1.col1": "table3.col4",
                    "table1.col2": "table3.col1"
                  },
                  "data_examples": ["Example of semantically matching values"]
                }
              ],
              "domain_context": "comprehensive description of what this data represents",
              "value_transformations": [
                {
                  "table": "table1",
                  "column": "column1",
                  "transformation": "CAST as STRING/NUMERIC/etc or other preprocessing needed"
                }
              ]
            }
          ''',
            },
          ],
        },
      ],
      'generationConfig': {'temperature': 0.3, 'topP': 0.9, 'topK': 40},
    };

    final response = await _restService.post(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$_apiKey',
      payload,
    );

    if (response['candidates'] != null && response['candidates'].isNotEmpty) {
      final analysisText =
          response['candidates'][0]['content']['parts'][0]['text'];
      // Extract the JSON part from the response
      final jsonStartIndex = analysisText.indexOf('{');
      final jsonEndIndex = analysisText.lastIndexOf('}') + 1;
      if (jsonStartIndex >= 0 && jsonEndIndex > jsonStartIndex) {
        final jsonStr = analysisText.substring(jsonStartIndex, jsonEndIndex);
        try {
          return jsonDecode(jsonStr);
        } catch (e) {
          throw Exception('Failed to parse context analysis: $e');
        }
      }
    }

    throw Exception('Failed to analyze query context');
  }

  Future<String> generateSqlQuery(
    String userQuestion,
    String databaseSchema,
    String tableName, {
    Map<String, List<Map<String, dynamic>>>? sampleData,
    Map<String, dynamic>? contextAnalysis,
  }) async {
    // -- 1: First translate question to English if needed --
    final englishQuestion = await translateToEnglish(userQuestion);

    // -- 2: Build a more comprehensive prompt with context information --
    String contextInfo = '';
    String sampleDataInfo = '';

    if (sampleData != null) {
      // Provide a small sample of data from each table to help with join logic
      final sampleDataPreview = <String, List<Map<String, dynamic>>>{};
      sampleData.forEach((key, value) {
        sampleDataPreview[key] = value.length > 3 ? value.sublist(0, 3) : value;
      });
      sampleDataInfo = '''
      Sample data preview: ${jsonEncode(sampleDataPreview)}
    ''';
    }

    if (contextAnalysis != null) {
      final relevantTables =
          contextAnalysis['relevant_tables']?.join(', ') ?? '';
      final relevantColumnsJson = jsonEncode(
        contextAnalysis['relevant_columns'] ?? {},
      );
      final joinsJson = jsonEncode(contextAnalysis['joins'] ?? []);
      final unionsJson = jsonEncode(contextAnalysis['unions'] ?? []);
      final valueTransformations = jsonEncode(
        contextAnalysis['value_transformations'] ?? [],
      );
      final domainContext = contextAnalysis['domain_context'] ?? '';

      contextInfo = '''
      Domain context: $domainContext
      
      Most relevant tables for this query: $relevantTables
      
      Relevant columns per table: $relevantColumnsJson
      
      Suggested joins: $joinsJson
      
      Suggested unions: $unionsJson
      
      Value transformations: $valueTransformations

      IMPORTANT:
      - If querying a table that you know is partitioned by a column (e.g., 'date_partition'),
        you MUST include a filter on that partition column in the WHERE clause to ensure query efficiency.
        For example: WHERE date_partition = '2025/05/12' OR date_partition >= '2025/01/01'.
        If the user query implies a date range, use it. Otherwise, consider a recent range or ask for clarification.
    ''';
    }
    // -- 3: Build the final prompt for SQL generation --
    final payload = {
      'contents': [
        {
          'parts': [
            {
              'text': '''
                You are an advanced SQL expert specializing in BigQuery Standard SQL. Generate a comprehensive SQL query that fully answers the user's question by combining data from multiple tables when needed.

                User question: $englishQuestion

                Database schemas: $databaseSchema

                Tables names: $tableName

                $contextInfo
                
                $sampleDataInfo

                Use the following guidelines:
                1. Generate only the SQL query without any explanations.
                2. Use backticks (`) around column names with spaces to avoid errors (even in aggregating operations eg., SELECT AVG(`gross income`)).
                3. Use `SELECT *` only when necessary.
                4. Join tables when needed to retrieve all relevant data in a single query.
                5. Use UNION operations when appropriate to combine similar data from different tables.
                6. Never use DELETE, INSERT, or UPDATE statements.
                7. If columns with similar meaning appear in multiple tables with different names, use aliases to standardize column names in the result set.
                8. If a table has no direct connection to others but contains relevant data, include it in a separate subquery or use UNION.
                9. Ensure output columns are consistently named to simplify visualization and analysis.
                10. For date or time-related questions, use appropriate BigQuery date functions.
                11. If possible, include simple aggregations that will be useful for visualization.
                12. For time series data, consider including granularity that makes visualization meaningful.
                13. Before joining tables, apply TRIM, UPPER/LOWER, or CAST functions as needed to normalize join keys.
                14. When dealing with potentially NULL columns in joins, consider using COALESCE or IFNULL functions aggressively.
                15. If standard joins fail to produce results, consider fuzzy matching strategies like SOUNDEX, LEVENSHTEIN distance, or substring matching.
                16. When working with text data in joins, normalize the strings by removing special characters or converting case.
                17. When converting string values to numeric types, always use a SAFE_CAST or a combination of REGEXP_EXTRACT and CAST to extract only numeric parts.
                18. For rating fields, assume they may contain non-numeric characters. Use REGEXP_EXTRACT and SAFE_CAST combination.
                19. For date fields, use DATE or TIMESTAMP functions to ensure proper formatting.
                20. Always use backticks (`) around SQL reserved words when used as column names (e.g., `end`, `start`, `date`, `timestamp`, `time`, `user`, etc.) to avoid syntax errors, even operations like (end - start) should be (`end` - `start`).
                
                IMPORTANT: 
                - Find the most effective way to join tables based on semantic relationships, not just exact key matches
                - Always limit the number of rows returned to avoid performance issues, use LIMIT clause selecting an appropriate number of rows with an upper bound of 500 rows
                - Use CASE statements or other conditional logic in JOIN conditions when necessary
                - For columns that appear to have NULL values after joining, use creative approaches to extract meaningful data
                - Focus on producing a complete, non-NULL result set even if it requires sophisticated SQL techniques
                - For numeric conversions, use SAFE_CAST and REGEXP_EXTRACT to handle potential formatting issues
                - For rating fields in particular, use a pattern like: AVG(SAFE_CAST(REGEXP_REPLACE(field, r'[^0-9.]', '') AS NUMERIC)) where the field might contain non-numeric characters
              ''',
            },
          ],
        },
      ],
      'generationConfig': {'temperature': 0.3, 'topP': 0.9, 'topK': 40},
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
              'text': '''
                Analyze these query results and provide insights.
                
                Query: $query
                
                Results (${resultsPreview.length} of $totalResults rows): $resultsStr
                
                Provide a comprehensive analysis including:
                
                1. Summary of findings: Describe the overall patterns, trends, and key metrics from the data
                2. Key insights: Identify at least 3 specific insights that can be drawn from the data
                3. Recommended visualizations: Suggest 2-3 specific chart types that would best represent this data
                   - For each visualization, explain what columns to use and why this visualization is appropriate
                   - Consider charts like line charts for time series, bar charts for comparisons, scatter plots for relationships, etc.
                4. Data quality observations: Note any potential issues with the data (missing values, outliers, etc.)
              ''',
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

  /// Genera una risposta di testo generica con Gemini
  Future<String> generateText(String prompt) async {
    try {
      final payload = {
        'contents': [
          {
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'generationConfig': {'temperature': 0.2, 'topP': 0.8, 'topK': 40},
      };

      // Utilizza gemini-2.0-flash invece di gemini-pro per mantenere coerenza con gli altri metodi
      final response = await _restService.post(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$_apiKey',
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

  /// Analyze file content and metadata to suggest an appropriate storage path
  Future<String> suggestFilePath(
    String bucketStructure,
    Map<String, dynamic> fileMetadata,
    String? fileContent,
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
      dev.log('Error suggesting file path: $e', error: e);
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
