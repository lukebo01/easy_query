import 'package:flutter/material.dart';
import 'package:easy_query/services/gemini_flash_service.dart';
import 'package:easy_query/services/big_query_service.dart';
// import 'package:easy_query/pages/result_page.dart'; // se vorrai riattivare la parte dei risultati

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
      // Schema di esempio
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

      // Genera query SQL
      final sqlQuery = await widget.geminiService.generateSqlQuery(
        question,
        databaseSchema,
      );
      print('$sqlQuery');

      // Esempio: logica commentata
      /*
      final results = await widget.bigQueryService.executeQuery(sqlQuery);
      print('Generated SQL Query: $sqlQuery');
      print('Query Results: $results');

      final analysis = await widget.geminiService.analyzeQueryResults(
        sqlQuery,
        results,
      );

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ResultPage(
            question: question,
            sqlQuery: sqlQuery,
            results: results,
            analysis: analysis,
          ),
        ),
      );
      */
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
    // Scaffold senza AppBar, usiamo un background con gradiente per un tocco moderno
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black, Colors.blue.shade50],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Logo centrale
                  const Text(
                    'Welcome to',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w600,
                      fontStyle: FontStyle.italic,
                      color: Colors.white,
                      fontFamily:
                          'Serif', // Use a sophisticated font family if available
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 300,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(56), // Bordi rotondi
                      child: Image.asset(
                        'assets/favicon.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const SizedBox(height: 16),
                  // Sottotitolo
                  const Text(
                    'Ask a question about your data',
                    style: TextStyle(fontSize: 18),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  // Box in stile "card" per l'input
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    color: Colors.black87,
                    elevation: 6,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        controller: _questionController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText:
                              'e.g. "What were the top 5 selling products last month?"',
                          hintStyle: TextStyle(color: Colors.grey[400]),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                          prefixIcon: const Icon(
                            Icons.search,
                            color: Colors.white70,
                          ),
                          fillColor: Colors.grey[850],
                          filled: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 16,
                            horizontal: 20,
                          ),
                        ),
                        maxLines: 3,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _processQuestion(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Bottone
                  ElevatedButton(
                    onPressed: _isLoading ? null : _processQuestion,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        vertical: 16,
                        horizontal: 32,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      elevation: 8,
                      shadowColor: Colors.grey.shade800,
                    ),
                    child:
                        _isLoading
                            ? const CircularProgressIndicator(
                              color: Colors.white,
                            )
                            : const Text(
                              'Search',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                  ),
                  const SizedBox(height: 16),
                  // Error box
                  if (_errorMessage.isNotEmpty)
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
                  const SizedBox(height: 32),
                  // Footer
                  Text(
                    'Powered by Gemini Flash 2.0',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
