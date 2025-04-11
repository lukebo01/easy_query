import 'package:flutter/material.dart';
import 'package:easy_query/services/gemini_flash_service.dart';
import 'package:easy_query/services/big_query_service.dart';
import 'package:easy_query/pages/result_page.dart';

class SearchPage extends StatefulWidget {
  final GeminiFlashService geminiService;
  final BigQueryService bigQueryService;

  const SearchPage({
    Key? key,
    required this.geminiService,
    required this.bigQueryService,
  }) : super(key: key);

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _questionController = TextEditingController();
  bool _isLoading = false;
  String _errorMessage = '';

  @override
  void dispose() {
    _questionController.dispose();
    super.dispose();
  }

  Future<void> _processQuestion() async {
    final question = _questionController.text.trim();
    if (question.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter a question';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      // This would need to be configured with your actual dataset schema
      const databaseSchema = '''
      {
        "tables": [
          {
            "name": "sales",
            "columns": [
              {"name": "date", "type": "DATE"},
              {"name": "product_id", "type": "STRING"},
              {"name": "product_name", "type": "STRING"},
              {"name": "category", "type": "STRING"},
              {"name": "quantity", "type": "INTEGER"},
              {"name": "price", "type": "FLOAT"},
              {"name": "total", "type": "FLOAT"},
              {"name": "region", "type": "STRING"}
            ]
          }
        ]
      }
      ''';

      // Generate SQL query from natural language
      final sqlQuery = await widget.geminiService.generateSqlQuery(
        question,
        databaseSchema,
      );
      print('$sqlQuery');
      /*
      // Execute the query
      final results = await widget.bigQueryService.executeQuery(sqlQuery);

      print('Generated SQL Query: $sqlQuery');
      print('Query Results: $results');

      // Analyze the results
      final analysis = await widget.geminiService.analyzeQueryResults(
        sqlQuery,
        results,
      );

      if (!mounted) return;

      // Navigate to results page
      Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (context) => ResultPage(
                question: question,
                sqlQuery: sqlQuery,
                results: results,
                analysis: analysis,
              ),
        ),
      );*/
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EasyQuery'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            const Text(
              'Ask a question about your data',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _questionController,
              decoration: InputDecoration(
                hintText:
                    'e.g., "What were the top 5 selling products last month?"',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                prefixIcon: const Icon(Icons.search),
                fillColor: Colors.grey[100],
                filled: true,
              ),
              maxLines: 3,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _processQuestion(),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isLoading ? null : _processQuestion,
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child:
                  _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Search', style: TextStyle(fontSize: 16)),
            ),
            if (_errorMessage.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red),
                ),
                child: SelectableText(
                  _errorMessage,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            ],
            const Spacer(),
            const Center(
              child: Text(
                'Powered by Gemini Flash 2.0',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
