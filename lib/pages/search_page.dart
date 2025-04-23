import 'package:flutter/material.dart';
import 'package:easy_query/services/gemini_flash_service.dart';
import 'package:easy_query/services/big_query_service.dart';
import 'package:easy_query/pages/result_page.dart'; // se vorrai riattivare la parte dei risultati

class SearchPage extends StatefulWidget {
  final GeminiFlashService geminiService;
  final BigQueryService bigQueryService;

  const SearchPage({
    super.key,
    required this.geminiService,
    required this.bigQueryService,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _questionController = TextEditingController();
  bool _isLoading = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _questionController.addListener(() {
      setState(() {}); // Update the UI when the text field changes
    });
  }

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
      // Recupera il nome del progetto
      final projectId = widget.bigQueryService.projectId;

      // Recupera la lista dei dataset
      final datasets = await widget.bigQueryService.getDatasets();

      print('List of datasets: $datasets');

      // Recupera la lista delle tabelle
      final tables = await widget.bigQueryService.getTables(
        // PER ORA UTILIZZIAMO UN SOLO DATASET
        datasets[0], // Nome del dataset
      );

      print('List of tables: $tables');

      // Recupera lo schema delle tabelle
      List schemas = [];

      for (var table in tables) {
        schemas.add(await widget.bigQueryService.getTableSchema(
          datasets[0], // Nome del dataset
          table, // Nome della tabella
        ));
      }

      print(schemas);

      // Prendi i nomi completi di tutte le tabelle
      final tableNames = tables.map((table) => '$projectId.${datasets[0]}.$table').toList();



      // Genera query SQL
      final sqlQuery = await widget.geminiService.generateSqlQuery(
        question,
        schemas.toString(), // Elenco degli schemas
        tableNames.toString(), // Elenco dei nomi delle tabelle
      );

      final cleanedSqlQuery =
          sqlQuery
              .replaceAll('sql', ' ') // Rimuove caratteri indesiderati
              .replaceAll(RegExp(r'\s+'), ' ') // Rimuove spazi multipli
              .replaceAll(RegExp(r'\n'), ' ') // Rimuove newline
              .replaceAll('```', '') // Rimuove virgolette triple
              .trim(); // Rimuove spazi iniziali e finali

      print('Generated query: $cleanedSqlQuery');

      // Esempio: logica commentata

      final results = await widget.bigQueryService.executeQuery(
        cleanedSqlQuery,
      );
      print('Query Results: $results');

      final analysis = await widget.geminiService.analyzeQueryResults(
        sqlQuery,
        results,
      );

      if (!mounted) return;
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
      );
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
    // Scaffold senza AppBar, usiamo un background con tinta unita
    return Scaffold(
      body: Container(
        color: const Color.fromARGB(255, 20, 20, 20), // Background color
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Logo centrale
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 300,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(56), // Bordi rotondi
                      child: Image.asset(
                        'assets/eq_logo.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const Text(
                    'Ask any question about your data',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontFamily:
                          'Serif', // Use a sophisticated font family if available
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  const SizedBox(height: 16),
                  const SizedBox(height: 32),
                  // Box in stile "card" per l'input
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    color: const Color.fromARGB(221, 10, 10, 10),
                    elevation: 6,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          TextField(
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
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.bottomRight,
                            child: ElevatedButton(
                              onPressed:
                                  _isLoading ||
                                          _questionController.text
                                              .trim()
                                              .isEmpty
                                      ? null
                                      : _processQuestion,
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                  horizontal: 24,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                backgroundColor:
                                    _questionController.text.trim().isEmpty
                                        ? Colors.grey
                                        : Colors.white,
                                foregroundColor: Colors.black,
                                elevation: 8,
                                shadowColor: Colors.white,
                              ),
                              child:
                                  _isLoading
                                      ? const CircularProgressIndicator(
                                        color: Colors.white,
                                      )
                                      : const Icon(
                                        Icons.send,
                                        size: 20,
                                        color: Colors.black, // Always visible
                                      ),
                            ),
                          ),
                        ],
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
