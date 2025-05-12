import 'dart:convert';
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

  /// Generate a SQL query based on the user's question and database schema
  Future<String> generateSqlQuery(
    String userQuestion,
    String databaseSchema,
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

            Database schemas: $databaseSchema
            
            Table names: $tableNames
            
            ${sampleData != null ? 'Sample data: ${jsonEncode(sampleData)}' : ''}
            
            ${contextAnalysis != null ? 'Context analysis: ${jsonEncode(contextAnalysis)}' : ''}
            
            IMPORTANT INSTRUCTIONS FOR DATE HANDLING:
            1. When filtering on a date_partition field that is stored as STRING in format 'YYYY/MM/DD', 
               ALWAYS use PARSE_DATE('%Y/%m/%d', date_partition) to convert it to a DATE before comparison.
            2. NEVER compare STRING date_partition directly with DATE functions like CURRENT_DATE() or DATE_SUB().
            3. CORRECT EXAMPLE: WHERE PARSE_DATE('%Y/%m/%d', date_partition) >= DATE_SUB(CURRENT_DATE(), INTERVAL 3 MONTH)
            4. INCORRECT EXAMPLE: WHERE date_partition >= DATE_SUB(CURRENT_DATE(), INTERVAL 3 MONTH)
            
            Generate a single SQL query that answers the user's question.
            Ensure that your query:
            1. Uses only tables that exist in the provided schema
            2. References columns that are present in those tables
            3. Follows best practices for performance, including limiting result size when appropriate
            4. Uses proper table name qualification with project and dataset IDs
            5. Uses LEFT JOINs when appropriate to avoid losing data
            6. Uses the proper syntax for BigQuery SQL
            7. Applies appropriate filtering conditions based on the user's question
            8. ALWAYS use PARSE_DATE('%Y/%m/%d', date_partition) when comparing date_partition fields with DATE types
            
            Return only the SQL query without any additional explanation or markdown formatting.


            IMPORTANT INSTRUCTIONS FOR SQL GENERATION (MANDATORY FOR ALL QUERIES):

            1.  MANDATORY PARTITION FILTER:
                IF you query any table that includes 'date_partition' in its schema 
                (like `soy-transducer-456512-t0.silver_zone.silver_data_files_it_document_text_file` 
                or any table in the `silver_zone` dataset that is similarly structured),
                YOU ABSOLUTELY MUST INCLUDE A WHERE CLAUSE THAT FILTERS THE 'date_partition' COLUMN.
                If the user's question does not provide a specific date or date range, 
                you MUST query a recent and relevant range (e.g., the last 30 days from the current date) 
                OR the latest available partition if known.
                DO NOT generate a query for these partitioned tables without a 'date_partition' filter.

            2.  DATE COMPARISON FOR 'date_partition' COLUMN (WHICH IS A STRING 'YYYY/MM/DD'):
                If you filter 'date_partition' by comparing it to a DATE type value 
                (e.g., from CURRENT_DATE(), DATE_SUB(), or a DATE literal like DATE('2023-01-01')),
                YOU MUST EXPLICITLY CONVERT THE 'date_partition' STRING to a DATE type before the comparison.
                USE THE FUNCTION: PARSE_DATE('%Y/%m/%d', date_partition)
                CORRECT EXAMPLE: WHERE PARSE_DATE('%Y/%m/%d', date_partition) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
                INCORRECT EXAMPLE (THIS WILL FAIL): WHERE date_partition >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
                ALWAYS PERFORM THIS CONVERSION for date comparisons involving the 'date_partition' STRING column.
            '''
            },
          ],
        },
      ]
    };

    final response = await _restService.post(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$_apiKey',
      payload,
    );

    if (response['candidates'] != null && response['candidates'].isNotEmpty) {
      return response['candidates'][0]['content']['parts'][0]['text'].trim();
    }

    throw Exception('Failed to generate SQL query');
  }
  
  /// Analyze query results to generate insights
  Future<String> analyzeQueryResults(String sqlQuery, List<Map<String, dynamic>> results) async {
    final payload = {
      'contents': [
        {
          'parts': [
            {
              'text': '''
            You are a data analysis expert tasked with analyzing the results of a SQL query.
            
            SQL Query: $sqlQuery
            
            Results: ${jsonEncode(results)}
            
            Please provide a detailed analysis of these results, including:
            
            1. A summary of the key findings
            2. Interpretation of any trends, patterns, or anomalies
            3. Actionable insights or recommendations based on the data
            4. Any limitations of the data or analysis
            
            Format your analysis with clear headings and bullet points where appropriate.
            '''
            },
          ],
        },
      ]
    };

    final response = await _restService.post(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$_apiKey',
      payload,
    );

    if (response['candidates'] != null && response['candidates'].isNotEmpty) {
      return response['candidates'][0]['content']['parts'][0]['text'].trim();
    }

    throw Exception('Failed to analyze query results');
  }
  
  /// Generate general text based on a prompt 
  Future<String> generateText(String prompt) async {
    final payload = {
      'contents': [
        {
          'parts': [
            {
              'text': prompt,
            },
          ],
        },
      ]
    };

    final response = await _restService.post(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$_apiKey',
      payload,
    );

    if (response['candidates'] != null && response['candidates'].isNotEmpty) {
      return response['candidates'][0]['content']['parts'][0]['text'].trim();
    }

    throw Exception('Failed to generate text');
  }
  
  /// Suggest a file path based on content analysis
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
