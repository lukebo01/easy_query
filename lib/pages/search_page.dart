import 'dart:convert';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:easy_query/services/gemini_flash_service.dart';
import 'package:easy_query/services/big_query_service.dart';
import 'package:easy_query/pages/result_page.dart';
import 'package:easy_query/services/cloud_storage_service.dart';

class SearchPage extends StatefulWidget {
  final GeminiFlashService geminiService;
  final BigQueryService bigQueryService;
  final CloudStorageService cloudStorageService;

  const SearchPage({
    super.key,
    required this.geminiService,
    required this.bigQueryService,
    required this.cloudStorageService,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _questionController = TextEditingController();
  bool _isLoading = false;
  String _errorMessage = '';
  String? _currentExecutingQuery;

  // --- State for Upload Dialog ---
  final TextEditingController _fileNameController = TextEditingController();
  bool _isUploading = false;
  bool _isAnalyzing = false;
  String _uploadErrorMessage = '';
  PlatformFile? _selectedFile;
  String? _suggestedPath;
  String _bucketStructure = '';
  
  // Metadati aggiuntivi per l'LLM
  Map<String, String> _additionalMetadata = {};
  final List<String> _availableTags = [
    'HR Data',
    'Financial',
    'Marketing',
    'Sales',
    'Customer',
    'Operational',
    'Transactional',
    'Product',
    'Inventory'
  ];
  final List<String> _availableDataCategories = [
    'Raw',
    'Processed',
    'Aggregated',
    'Reporting',
    'External',
    'Internal',
    'Reference',
    'Master'
  ];
  final List<String> _selectedTags = [];
  String? _selectedDataCategory;
  String? _dataDescription;
  final TextEditingController _dataDescriptionController = TextEditingController();
  // --- End State for Upload Dialog ---

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
    _fileNameController.dispose();
    _dataDescriptionController.dispose();
    super.dispose();
  }

  Future<void> _processQuestion(String question) async {
    if (question.trim().isEmpty) {
      setState(() {
        _errorMessage = 'Please enter a question';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _currentExecutingQuery = 'Translating request to english...';
    });

    try {
      // Recupera il nome del progetto
      final projectId = widget.bigQueryService.projectId;

      // Recupera la lista dei dataset
      final datasets = await widget.bigQueryService.getDatasets();

      log('List of datasets: $datasets');
      if (datasets.isEmpty) {
        throw Exception("No datasets found in the project. Cannot proceed.");
      }

      final targetDataset = datasets[0];
      final tables = await widget.bigQueryService.getTables(targetDataset);

      log('List of tables in $targetDataset: $tables');

      // Recupera lo schema delle tabelle
      List schemas = [];
      List<String> tableNames = []; // Store fully qualified names here
      Map<String, List<Map<String, dynamic>>> sampleData = {};

      for (var table in tables) {
        try {
          final schema = await widget.bigQueryService.getTableSchema(
            targetDataset, // Nome del dataset
            table, // Nome della tabella
          );
          schemas.add(schema);

          // Formato nome tabella completo
          final fullTableName = '$projectId.$targetDataset.$table';
          tableNames.add(fullTableName);

          print(
            'Schema for table $fullTableName: ${jsonEncode(schema).toString()}',
          );

          // Ottieni un campione di dati da ogni tabella (limitato a 15 record casuali)
          try {
            final sampleQuery =
                "SELECT * FROM `$fullTableName` TABLESAMPLE SYSTEM (1 PERCENT) LIMIT 15";
            final tableSample = await widget.bigQueryService.executeQuery(
              sampleQuery,
            );
            sampleData[fullTableName] = tableSample;
          } catch (e) {
            log(
              'Warning: Failed to get sample data from $fullTableName. Error: $e',
            );
          }
        } catch (e) {
          log(
            'Warning: Failed to get schema for table $targetDataset.$table. Skipping. Error: $e',
          );
        }
      }

      log('Table schemas fetched: ${schemas.length}');
      log('Sample data fetched from ${sampleData.length} tables');

      // Analisi del contesto per identificare tabelle rilevanti
      setState(() {
        _currentExecutingQuery = 'Analyzing dataset context...';
      });

      final contextAnalysis = await widget.geminiService.analyzeQueryContext(
        question,
        jsonEncode(schemas),
        tableNames,
        sampleData,
      );

      log('Context analysis: ${jsonEncode(contextAnalysis)}');

      // Genera query SQL con contesto arricchito
      setState(() {
        _currentExecutingQuery = 'Building optimized query...';
      });

      final sqlQuery = await widget.geminiService.generateSqlQuery(
        question,
        jsonEncode(schemas),
        jsonEncode(tableNames),
        sampleData: sampleData,
        contextAnalysis: contextAnalysis,
      );

      final cleanedSqlQuery =
          sqlQuery
              .replaceAll('sql', ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .replaceAll(RegExp(r'\n'), ' ')
              .replaceAll('```', '')
              .replaceAll(RegExp(r'^\s*SELECT', caseSensitive: false), 'SELECT')
              .trim();

      log('Executing SQL query: $cleanedSqlQuery');

      // Set the query string to display the banner
      setState(() {
        _currentExecutingQuery = cleanedSqlQuery;
      });

      final results = await widget.bigQueryService.executeQuery(
        cleanedSqlQuery,
      );
      log('Query Results: ${jsonEncode(results)}');

      final analysis = await widget.geminiService.analyzeQueryResults(
        cleanedSqlQuery,
        results,
      );

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ResultPage(
            question: question,
            sqlQuery: cleanedSqlQuery,
            results: results,
            analysis: analysis,
          ),
        ),
      );
    } catch (e) {
      log('Error processing question: ${e.toString()}', error: e);
      setState(() {
        if (e is Exception) {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        } else {
          _errorMessage = 'An unexpected error occurred: ${e.toString()}';
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _currentExecutingQuery = null;
        });
      }
    }
  }

  // --- Intelligent File Upload Methods ---

  Future<void> _pickFile(StateSetter dialogSetState) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.any, // Accetta qualsiasi tipo di file
        withData: true,
      );

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        if (file.bytes != null && file.bytes!.isNotEmpty) {
          dialogSetState(() {
            _selectedFile = file;
            _uploadErrorMessage = '';
            _suggestedPath = null; // Reset il percorso suggerito
            // Popoliamo il nome del file con il nome originale
            _fileNameController.text = file.name;
            log('File selezionato: ${file.name}, dimensione: ${file.size} bytes, tipo: ${file.extension}');
          });
          
          // Dopo aver selezionato il file, analizza il bucket e suggerisci un percorso
          await _analyzeAndSuggestPath(dialogSetState);
        } else {
          dialogSetState(() {
            _uploadErrorMessage = 'File non valido. Assicurati che il file contenga dati.';
            _selectedFile = null;
          });
        }
      } else {
        log('Selezione file annullata');
      }
    } catch (e) {
      log('Errore nella selezione del file: $e');
      dialogSetState(() {
        _uploadErrorMessage = 'Errore nella selezione del file: ${e.toString()}';
        _selectedFile = null;
      });
    }
  }

  Future<void> _analyzeAndSuggestPath(StateSetter dialogSetState) async {
    if (_selectedFile == null) return;
    
    dialogSetState(() {
      _isAnalyzing = true;
      _uploadErrorMessage = '';
    });
    
    try {
      // 1. Ottieni la struttura del bucket
      final bucketHierarchy = await widget.cloudStorageService.listFolderHierarchy();
      _bucketStructure = _formatBucketHierarchy(bucketHierarchy);
      
      // 2. Analizza il contenuto del file (per i file testuali/CSV)
      String fileContent = '';
      if (_selectedFile!.extension?.toLowerCase() == 'csv' || 
          _selectedFile!.extension?.toLowerCase() == 'txt' || 
          _selectedFile!.extension?.toLowerCase() == 'json') {
        // Per file di testo, convertiamo i bytes in string
        if (_selectedFile!.bytes != null) {
          try {
            fileContent = String.fromCharCodes(_selectedFile!.bytes!);
            // Limita la quantità di contenuto da analizzare
            if (fileContent.length > 2000) {
              fileContent = fileContent.substring(0, 2000) + '...';
            }
          } catch (e) {
            log('Impossibile convertire il file in testo: $e');
            fileContent = 'Contenuto binario non analizzabile';
          }
        }
      } else {
        fileContent = 'File binario di tipo ${_selectedFile!.extension}';
      }
      
      // 3. Prepara i metadati per l'LLM
      final metadataForLLM = {
        'fileName': _selectedFile!.name,
        'fileType': _selectedFile!.extension ?? 'unknown',
        'fileSize': '${(_selectedFile!.size / 1024).toStringAsFixed(2)} KB',
        'tags': _selectedTags.isEmpty ? 'nessuno' : _selectedTags.join(', '),
        'category': _selectedDataCategory ?? 'non specificato',
        'description': _dataDescription ?? 'non specificata',
      };
      
      // 4. Richiedi all'LLM di suggerire un percorso
      final prompt = '''
Analizza la seguente struttura del bucket e i metadati del file da caricare. 
Suggerisci il percorso di archiviazione più appropriato nel formato /cartella/sottocartella/ basandoti su:
1. La struttura esistente del bucket
2. Il tipo e il contenuto del file
3. I tag e i metadati associati

STRUTTURA DEL BUCKET:
$_bucketStructure

METADATI DEL FILE:
${metadataForLLM.entries.map((e) => '${e.key}: ${e.value}').join('\n')}

CONTENUTO DEL FILE (esempio):
$fileContent

Rispondi SOLO con il percorso consigliato nel formato /cartella/sottocartella/ senza aggiungere il nome del file.
Se è necessario creare nuove cartelle, spiegane brevemente il motivo.
''';
      
      final llmResponse = await widget.geminiService.generateText(prompt);
      
      // 5. Estrai il percorso dalla risposta dell'LLM
      final suggestedPath = _extractPathFromLLMResponse(llmResponse);
      
      dialogSetState(() {
        _suggestedPath = suggestedPath;
        _isAnalyzing = false;
      });
      
      log('Percorso suggerito dall\'LLM: $_suggestedPath');
      
    } catch (e) {
      log('Errore nell\'analisi del file: $e');
      dialogSetState(() {
        _uploadErrorMessage = 'Errore nell\'analisi del file: ${e.toString()}';
        _isAnalyzing = false;
      });
    }
  }
  
  String _formatBucketHierarchy(Map<String, List<String>> hierarchy) {
    StringBuffer buffer = StringBuffer();
    
    hierarchy.forEach((folder, files) {
      buffer.writeln('/$folder/');
      for (var file in files) {
        buffer.writeln('  - $file');
      }
    });
    
    return buffer.toString();
  }
  
  String _extractPathFromLLMResponse(String response) {
    // Cerca un pattern che assomigli a un percorso
    final RegExp pathRegex = RegExp(r'\/[a-zA-Z0-9_\-\/]+\/?');
    final match = pathRegex.firstMatch(response);
    
    if (match != null) {
      String path = match.group(0) ?? '';
      
      // Assicurati che il percorso inizi con / e termini con /
      if (!path.startsWith('/')) {
        path = '/$path';
      }
      if (!path.endsWith('/')) {
        path = '$path/';
      }
      
      return path;
    }
    
    // In caso non riesca a trovare un percorso, estrai la prima riga come suggerimento
    final firstLine = response.split('\n').first.trim();
    if (firstLine.isNotEmpty) {
      return firstLine.startsWith('/') ? firstLine : '/$firstLine';
    }
    
    return '/'; // Default: root del bucket
  }

  Future<void> _uploadFile(
    StateSetter dialogSetState,
    BuildContext dialogContext,
  ) async {
    if (_selectedFile == null) {
      dialogSetState(() {
        _uploadErrorMessage = 'Seleziona un file prima di procedere.';
      });
      return;
    }

    if (_selectedFile!.bytes == null) {
      dialogSetState(() {
        _uploadErrorMessage = 'Dati del file mancanti. Riseleziona il file.';
      });
      return;
    }
    
    // Se non è stato suggerito un percorso, richiedilo
    if (_suggestedPath == null) {
      await _analyzeAndSuggestPath(dialogSetState);
      if (_suggestedPath == null) {
        dialogSetState(() {
          _uploadErrorMessage = 'Impossibile determinare un percorso appropriato.';
        });
        return;
      }
    }

    dialogSetState(() {
      _isUploading = true;
      _uploadErrorMessage = '';
    });

    try {
      // Utilizza il nome fornito o quello originale
      final fileName = _fileNameController.text.isEmpty ? 
                       _selectedFile!.name : 
                       _fileNameController.text;
      
      // Assicurati che il nome del file includa l'estensione originale
      String finalFileName = fileName;
      if (_selectedFile!.extension != null && !finalFileName.toLowerCase().endsWith('.${_selectedFile!.extension!.toLowerCase()}')) {
        finalFileName = '$finalFileName.${_selectedFile!.extension}';
      }
      
      // Il percorso completo è il percorso suggerito + nome file
      String fullPath = _suggestedPath!;
      final fileBytes = _selectedFile!.bytes!;
      
      // Determina il content type basato sull'estensione
      String? contentType = _getContentTypeFromExtension(_selectedFile!.extension);

      log('Tentativo di upload di ${_selectedFile!.name} nel bucket bronze al percorso: $fullPath$finalFileName');

      final url = await widget.cloudStorageService.uploadFile(
        fileName: '$fullPath$finalFileName',
        fileBytes: fileBytes,
        contentType: contentType,
      );

      log('Upload completato con successo nel bucket bronze. File disponibile a: $url');

      if (Navigator.canPop(dialogContext)) {
        Navigator.pop(dialogContext);
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'File "${_selectedFile!.name}" caricato con successo nel bucket bronze!\nPercorso: $fullPath$finalFileName\nURL: $url',
            style: const TextStyle(color: Colors.black),
          ),
          backgroundColor: Colors.green[100],
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10.0),
          ),
          margin: const EdgeInsets.all(10),
          duration: const Duration(seconds: 8),
        ),
      );

      setState(() {
        _selectedFile = null;
        _fileNameController.clear();
        _dataDescriptionController.clear();
        _suggestedPath = null;
        _uploadErrorMessage = '';
        _selectedTags.clear();
        _selectedDataCategory = null;
        _dataDescription = null;
      });
    } catch (e) {
      log('Errore durante il caricamento del file: $e', error: e);
      dialogSetState(() {
        _uploadErrorMessage = 'Upload fallito: ${e.toString().replaceFirst('Exception: ', '')}';
      });
    } finally {
      if (mounted) {
        dialogSetState(() {
          _isUploading = false;
        });
      }
    }
  }
  
  String? _getContentTypeFromExtension(String? extension) {
    if (extension == null) return null;
    
    final Map<String, String> contentTypes = {
      'csv': 'text/csv',
      'txt': 'text/plain',
      'json': 'application/json',
      'pdf': 'application/pdf',
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'zip': 'application/zip',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    };
    
    return contentTypes[extension.toLowerCase()] ?? 'application/octet-stream';
  }

  void _showUploadDialog() async {
    _selectedFile = null;
    _fileNameController.clear();
    _dataDescriptionController.clear();
    _uploadErrorMessage = '';
    _isUploading = false;
    _isAnalyzing = false;
    _suggestedPath = null;
    _selectedTags.clear();
    _selectedDataCategory = null;
    _dataDescription = null;

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: !_isUploading && !_isAnalyzing,
      builder: (BuildContext dialogContext) {
        // Define dark theme colors
        const dialogBackgroundColor = Color.fromARGB(255, 30, 30, 30);
        const textColor = Colors.white;
        const hintColor = Colors.grey;
        const inputFillColor = Color.fromARGB(255, 50, 50, 50);
        const inputBorderColor = Colors.white54;
        final errorColor = Colors.redAccent[100];
        const buttonTextColor = Colors.black;
        const primaryButtonColor = Colors.white;
        const secondaryButtonColor = Color.fromARGB(255, 80, 80, 80);
        const accentColor = Colors.white;
        const chipBackgroundColor = Color.fromARGB(255, 60, 60, 60);

        return StatefulBuilder(
          builder: (context, StateSetter dialogSetState) {
            return AlertDialog(
              backgroundColor: dialogBackgroundColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: [
                  const Icon(Icons.cloud_upload, color: accentColor),
                  const SizedBox(width: 10),
                  const Text(
                    'Upload Intelligente nel Bronze Bucket',
                    style: TextStyle(color: textColor),
                  ),
                  const Spacer(),
                  if (_isAnalyzing)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accentColor,
                      ),
                    ),
                ],
              ),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 500, // Larghezza fissa per contenere tutti i controlli
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      // File Picker Button & Display
                      Row(
                        children: [
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: secondaryButtonColor,
                              foregroundColor: textColor,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            icon: const Icon(Icons.attach_file, size: 18),
                            label: const Text('Seleziona File'),
                            onPressed: (_isUploading || _isAnalyzing)
                                ? null
                                : () async {
                                    await _pickFile(dialogSetState);
                                  },
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _selectedFile?.name ?? 'Nessun file selezionato',
                              style: const TextStyle(color: hintColor),
                              overflow: TextOverflow.fade,
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      
                      // File Name Input (opzionale)
                      TextField(
                        controller: _fileNameController,
                        enabled: !_isUploading && !_isAnalyzing,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Nome File (opzionale)',
                          hintText: 'Lascia vuoto per usare il nome originale',
                          labelStyle: const TextStyle(color: hintColor),
                          hintStyle: const TextStyle(color: hintColor),
                          filled: true,
                          fillColor: inputFillColor,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: inputBorderColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: accentColor),
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                      const SizedBox(height: 15),
                      
                      // Metadata Section Title
                      const Text(
                        'Metadati Opzionali',
                        style: TextStyle(
                          color: textColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 10),
                      
                      // Categoria Dropdown
                      DropdownButtonFormField<String>(
                        decoration: InputDecoration(
                          labelText: 'Categoria',
                          labelStyle: const TextStyle(color: hintColor),
                          filled: true,
                          fillColor: inputFillColor,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: inputBorderColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: accentColor),
                          ),
                        ),
                        dropdownColor: inputFillColor,
                        value: _selectedDataCategory,
                        onChanged: (_isUploading || _isAnalyzing) 
                            ? null 
                            : (String? newValue) {
                                dialogSetState(() {
                                  _selectedDataCategory = newValue;
                                  // Rianalizza dopo aver cambiato i metadati
                                  if (_selectedFile != null) {
                                    _analyzeAndSuggestPath(dialogSetState);
                                  }
                                });
                              },
                        items: [null, ..._availableDataCategories]
                            .map<DropdownMenuItem<String>>((String? value) {
                          return DropdownMenuItem<String>(
                            value: value,
                            child: Text(
                              value ?? 'Seleziona una categoria',
                              style: TextStyle(
                                color: value == null ? hintColor : textColor,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 15),
                      
                      // Description TextField
                      TextField(
                        controller: _dataDescriptionController,
                        enabled: !_isUploading && !_isAnalyzing,
                        style: const TextStyle(color: Colors.white),
                        maxLines: 2,
                        onChanged: (value) {
                          _dataDescription = value;
                          // Rianalizza se cambia la descrizione
                          if (_selectedFile != null && value.isNotEmpty) {
                            _analyzeAndSuggestPath(dialogSetState);
                          }
                        },
                        decoration: InputDecoration(
                          labelText: 'Descrizione',
                          hintText: 'Descrivi il contenuto del file',
                          labelStyle: const TextStyle(color: hintColor),
                          hintStyle: const TextStyle(color: hintColor),
                          filled: true,
                          fillColor: inputFillColor,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: inputBorderColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: accentColor),
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                      const SizedBox(height: 15),
                      
                      // Tags
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Tag (seleziona uno o più)',
                            style: TextStyle(color: hintColor),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _availableTags.map((tag) {
                              final isSelected = _selectedTags.contains(tag);
                              return FilterChip(
                                label: Text(
                                  tag,
                                  style: TextStyle(
                                    color: isSelected ? Colors.black : textColor,
                                  ),
                                ),
                                selected: isSelected,
                                onSelected: (_isUploading || _isAnalyzing)
                                    ? null
                                    : (bool selected) {
                                        dialogSetState(() {
                                          if (selected) {
                                            _selectedTags.add(tag);
                                          } else {
                                            _selectedTags.remove(tag);
                                          }
                                          // Rianalizza dopo aver cambiato i tag
                                          if (_selectedFile != null) {
                                            _analyzeAndSuggestPath(dialogSetState);
                                          }
                                        });
                                      },
                                backgroundColor: chipBackgroundColor,
                                selectedColor: accentColor,
                                checkmarkColor: Colors.black,
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      
                      // Suggested Path Display
                      if (_suggestedPath != null)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Colors.green.withOpacity(0.5),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Percorso suggerito:',
                                style: TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                _suggestedPath!,
                                style: const TextStyle(color: Colors.green),
                              ),
                            ],
                          ),
                        ),
                      
                      // Progress & Error Indicators
                      if (_isUploading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10.0),
                          child: Center(
                            child: Column(
                              children: [
                                CircularProgressIndicator(color: accentColor),
                                SizedBox(height: 8),
                                Text(
                                  'Caricamento in corso...',
                                  style: TextStyle(color: textColor),
                                ),
                              ],
                            ),
                          ),
                        ),

                      if (_uploadErrorMessage.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 10.0),
                          child: Text(
                            _uploadErrorMessage,
                            style: TextStyle(color: errorColor),
                            textAlign: TextAlign.center,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: hintColor),
                  child: const Text('Annulla'),
                  onPressed: (_isUploading || _isAnalyzing)
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryButtonColor,
                    foregroundColor: buttonTextColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    disabledBackgroundColor: secondaryButtonColor,
                  ),
                  onPressed: (_isUploading || _isAnalyzing || _selectedFile == null)
                      ? null
                      : () async {
                          await _uploadFile(
                            dialogSetState,
                            dialogContext,
                          );
                        },
                  child: _isUploading
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: buttonTextColor,
                          ),
                        )
                      : const Text('Carica'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // --- End Intelligent File Upload Methods ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: const Color.fromARGB(255, 20, 20, 20),
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
                      borderRadius: BorderRadius.circular(56),
                      child: Image.asset(
                        'assets/eq_logo.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Ask any question about your data',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontFamily: 'Serif',
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  
                  // Card with search box
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      color: const Color.fromARGB(221, 10, 10, 10),
                      elevation: 6,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
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
                              minLines: 1,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _processQuestion(
                                _questionController.text,
                              ),
                            ),
                            const SizedBox(height: 12),
                            
                            // Row for Buttons
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                // Upload Button
                                IconButton(
                                  icon: const Icon(Icons.upload_file),
                                  color: Colors.white70,
                                  tooltip: 'Upload CSV to BigQuery',
                                  onPressed: _isLoading
                                      ? null
                                      : _showUploadDialog,
                                ),
                                // Send Button
                                ElevatedButton(
                                  onPressed: _isLoading ||
                                          _questionController.text.isEmpty
                                      ? null
                                      : () => _processQuestion(
                                            _questionController.text,
                                          ),
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                      horizontal: 24,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    backgroundColor:
                                        _questionController.text.isEmpty
                                            ? Colors.grey[600]
                                            : Colors.white,
                                    foregroundColor: Colors.black,
                                    elevation: 8,
                                    shadowColor: Colors.white.withOpacity(0.5),
                                    disabledBackgroundColor:
                                        Colors.grey.shade800,
                                  ),
                                  child: _isLoading &&
                                          _currentExecutingQuery == null
                                      ? const SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            color: Colors.black,
                                            strokeWidth: 3,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.send,
                                          size: 20,
                                          color: Colors.black,
                                        ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Loading/Executing Query Banner
                  if (_isLoading && _currentExecutingQuery != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.green.shade300.withOpacity(0.5),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.hourglass_bottom,
                              color: Colors.green.shade100,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SelectableText(
                                'Now processing: $_currentExecutingQuery',
                                style: TextStyle(color: Colors.green.shade100),
                                maxLines: 2,
                                minLines: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Error box for Query Execution
                  if (_errorMessage.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.redAccent.shade100.withOpacity(0.5),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.error_outline,
                              color: Colors.redAccent.shade100,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SelectableText(
                                _errorMessage,
                                style: TextStyle(
                                  color: Colors.redAccent.shade100,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  const SizedBox(height: 16),
                  // Footer
                  Text(
                    'Powered by Gemini Flash & Google Cloud',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'This open-source project was developed for the Big Data exam by Luca Borrelli and Davide Mariani.',
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
