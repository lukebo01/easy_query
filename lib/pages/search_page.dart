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

  // Additional metadata for LLM
  final List<String> _availableTags = [
    'HR Data',
    'Financial',
    'Marketing',
    'Sales',
    'Customer',
    'Operational',
    'Transactional',
    'Product',
    'Inventory',
  ];

  final List<String> _availableDataCategories = [
    'Raw',
    'Processed',
    'Aggregated',
    'Reporting',
    'External',
    'Internal',
    'Reference',
    'Master',
  ];

  final List<String> _selectedTags = [];
  String? _selectedDataCategory;
  String? _dataDescription;
  final TextEditingController _dataDescriptionController =
      TextEditingController();
  bool _needsRefresh = false;
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

      // Recupera tutte le tabelle dei dataset di destinazione (bigquery e silver)
      final Map<String, List<String>> datasetTablesMap = {};
      for (var dataset in datasets) {
        if (dataset != 'metadata_store') {
          // Escludi il dataset "metadata_store"
          final tables = await widget.bigQueryService.getTables(dataset);
          datasetTablesMap[dataset] = tables;
        }
      }

      log('Dataset to tables mapping: $datasetTablesMap');

      // Recupera lo schema delle tabelle
      List schemas = [];
      List<String> tableNames = []; // Store fully qualified names here
      Map<String, List<Map<String, dynamic>>> sampleData = {};

      await Future.forEach(datasetTablesMap.entries, (entry) async {
        final targetDataset = entry.key;
        final tables = entry.value;
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
      });

      log('Table schemas fetched: ${schemas.length}');
      log('Sample data fetched from ${sampleData.length} tables');

      // Recupera i file caricati nel bucket bronze
      final cloudFilesMetadata =
          await widget.bigQueryService.getBronzeMetadata();

      log('Cloud files metadata: ${jsonEncode(cloudFilesMetadata)}');

      // Analisi del contesto per identificare tabelle rilevanti
      setState(() {
        _currentExecutingQuery = 'Analyzing dataset context...';
      });

      final contextAnalysis = await widget.geminiService.analyzeQueryContext(
        question,
        jsonEncode(schemas),
        jsonEncode(cloudFilesMetadata),
        tableNames,
        sampleData,
      );

      log('Context analysis: ${jsonEncode(contextAnalysis)}');

      // Verifica se sono stati trovati file bronze da trasformare
      if (contextAnalysis['suggested_files'] != null &&
          contextAnalysis['suggested_files'].isNotEmpty) {
        log(
          "Suggested files for transformation: ${contextAnalysis['suggested_files']}",
        );
        // TODO: Trasforma i file suggeriti
      }

      // Aggiungi i file bronze trasformati al contesto
      // TODO: bisogna aggiungere le tabelle trasformate in 'tableNames' (con nome completo) e i rispettivi schemas in 'schemas'

      // Genera query SQL con contesto arricchito
      setState(() {
        _currentExecutingQuery = 'Building optimized query...';
      });

      // Rimuovi i suggested files dal contesto in quanto sono stati già trasformati
      contextAnalysis.remove('suggested_files');

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
          builder:
              (context) => ResultPage(
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
        type: FileType.any, // Accept any file type
        withData: true,
      );

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        if (file.bytes != null && file.bytes!.isNotEmpty) {
          dialogSetState(() {
            _selectedFile = file;
            _uploadErrorMessage = '';
            _suggestedPath = null; // Reset suggested path
            // Populate file name with original name
            _fileNameController.text = file.name;
            log(
              'File selected: ${file.name}, size: ${file.size} bytes, type: ${file.extension}',
            );
          });

          // After selecting a file, analyze the bucket and suggest a path
          await _analyzeAndSuggestPath(dialogSetState);
        } else {
          dialogSetState(() {
            _uploadErrorMessage =
                'Invalid file. Please ensure the file contains data.';
            _selectedFile = null;
          });
        }
      } else {
        log('File selection canceled');
      }
    } catch (e) {
      log('Error selecting file: $e');
      dialogSetState(() {
        _uploadErrorMessage = 'Error selecting file: ${e.toString()}';
        _selectedFile = null;
      });
    }
  }

  Future<void> _analyzeAndSuggestPath(StateSetter dialogSetState) async {
    if (_selectedFile == null) return;

    dialogSetState(() {
      _isAnalyzing = true;
      _uploadErrorMessage = '';
      _needsRefresh = false;
    });

    try {
      // 1. Get bucket structure
      final bucketHierarchy =
          await widget.cloudStorageService.listFolderHierarchy();
      _bucketStructure = _formatBucketHierarchy(bucketHierarchy);

      // 2. Analyze file content (for text/CSV files)
      String fileContent = '';
      if (_selectedFile!.extension?.toLowerCase() == 'csv' ||
          _selectedFile!.extension?.toLowerCase() == 'txt' ||
          _selectedFile!.extension?.toLowerCase() == 'json') {
        // For text files, convert bytes to string
        if (_selectedFile!.bytes != null) {
          try {
            fileContent = String.fromCharCodes(_selectedFile!.bytes!);
            // Limit the amount of content to analyze
            if (fileContent.length > 2000) {
              fileContent = fileContent.substring(0, 2000) + '...';
            }
          } catch (e) {
            log('Unable to convert file to text: $e');
            fileContent = 'Binary content not analyzable';
          }
        }
      } else {
        fileContent = 'Binary file of type ${_selectedFile!.extension}';
      }

      // 3. Prepare metadata for LLM
      final metadataForLLM = {
        'fileName': _selectedFile!.name,
        'fileType': _selectedFile!.extension ?? 'unknown',
        'fileSize': '${(_selectedFile!.size / 1024).toStringAsFixed(2)} KB',
        'tags': _selectedTags.isEmpty ? 'none' : _selectedTags.join(', '),
        'category': _selectedDataCategory ?? 'not specified',
        'description': _dataDescription ?? 'not specified',
      };

      // 4. Request path suggestion from GeminiFlashService
      final suggestedPath = await widget.geminiService.suggestFilePath(
        _bucketStructure,
        metadataForLLM,
        fileContent,
      );

      dialogSetState(() {
        _suggestedPath = suggestedPath;
        _isAnalyzing = false;
      });

      log('Path suggested by LLM: $_suggestedPath');
    } catch (e) {
      log('Error analyzing file: $e');
      dialogSetState(() {
        _uploadErrorMessage = 'Error analyzing file: ${e.toString()}';
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

  Future<void> _uploadFile(
    StateSetter dialogSetState,
    BuildContext dialogContext,
  ) async {
    if (_selectedFile == null) {
      dialogSetState(() {
        _uploadErrorMessage = 'Please select a file first.';
      });
      return;
    }

    if (_selectedFile!.bytes == null) {
      dialogSetState(() {
        _uploadErrorMessage = 'Missing file data. Please reselect the file.';
      });
      return;
    }

    // If no path suggested, request one
    if (_suggestedPath == null) {
      await _analyzeAndSuggestPath(dialogSetState);
      if (_suggestedPath == null) {
        dialogSetState(() {
          _uploadErrorMessage = 'Unable to determine an appropriate path.';
        });
        return;
      }
    }

    dialogSetState(() {
      _isUploading = true;
      _uploadErrorMessage = '';
    });

    try {
      // Use provided name or original name
      final fileName =
          _fileNameController.text.isEmpty
              ? _selectedFile!.name
              : _fileNameController.text;

      // Ensure filename includes original extension
      String finalFileName = fileName;
      if (_selectedFile!.extension != null &&
          !finalFileName.toLowerCase().endsWith(
            '.${_selectedFile!.extension!.toLowerCase()}',
          )) {
        finalFileName = '$finalFileName.${_selectedFile!.extension}';
      }

      // Complete path is suggested path + filename
      String fullPath = _suggestedPath!;
      final fileBytes = _selectedFile!.bytes!;

      // Determine content type based on extension
      String? contentType = _getContentTypeFromExtension(
        _selectedFile!.extension,
      );

      log(
        'Attempting to upload ${_selectedFile!.name} to bronze bucket at path: $fullPath$finalFileName',
      );

      final url = await widget.cloudStorageService.uploadFile(
        fileName: '$fullPath$finalFileName',
        fileBytes: fileBytes,
        contentType: contentType,
      );

      log(
        'Upload completed successfully to bronze bucket. File available at: $url',
      );

      if (Navigator.canPop(dialogContext)) {
        Navigator.pop(dialogContext);
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'File "${_selectedFile!.name}" uploaded successfully to bronze bucket!\nPath: $fullPath$finalFileName\nURL: $url',
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
      log('Error uploading file: $e', error: e);
      dialogSetState(() {
        _uploadErrorMessage =
            'Upload failed: ${e.toString().replaceFirst('Exception: ', '')}';
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
      'docx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx':
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    };

    return contentTypes[extension.toLowerCase()] ?? 'application/octet-stream';
  }

  void _markMetadataChanged(StateSetter dialogSetState) {
    dialogSetState(() {
      _needsRefresh = true;
      _suggestedPath = null; // Clear the suggested path when metadata changes
    });
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
    _needsRefresh = false;

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
                    'Intelligent Upload to Google Cloud Storage',
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
                  width: 500, // Fixed width to contain all controls
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
                            label: const Text('Select File'),
                            onPressed:
                                (_isUploading || _isAnalyzing)
                                    ? null
                                    : () async {
                                      await _pickFile(dialogSetState);
                                    },
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _selectedFile?.name ?? 'No file selected',
                              style: const TextStyle(color: hintColor),
                              overflow: TextOverflow.fade,
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // File Name Input (optional)
                      TextField(
                        controller: _fileNameController,
                        enabled: !_isUploading && !_isAnalyzing,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'File Name (optional)',
                          hintText: 'Leave empty to use original name',
                          labelStyle: const TextStyle(color: hintColor),
                          hintStyle: const TextStyle(color: hintColor),
                          filled: true,
                          fillColor: inputFillColor,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                              color: inputBorderColor,
                            ),
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
                        'Additional Information',
                        style: TextStyle(
                          color: textColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'These details are used only to suggest a more accurate file path and will not be stored',
                        style: TextStyle(
                          color: hintColor,
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Category Dropdown
                      DropdownButtonFormField<String>(
                        decoration: InputDecoration(
                          labelText: 'Category',
                          labelStyle: const TextStyle(color: hintColor),
                          filled: true,
                          fillColor: inputFillColor,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                              color: inputBorderColor,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: accentColor),
                          ),
                        ),
                        dropdownColor: inputFillColor,
                        value: _selectedDataCategory,
                        onChanged:
                            (_isUploading || _isAnalyzing)
                                ? null
                                : (String? newValue) {
                                  dialogSetState(() {
                                    _selectedDataCategory = newValue;
                                    _markMetadataChanged(dialogSetState);
                                  });
                                },
                        items:
                            [
                              null,
                              ..._availableDataCategories,
                            ].map<DropdownMenuItem<String>>((String? value) {
                              return DropdownMenuItem<String>(
                                value: value,
                                child: Text(
                                  value ?? 'Select a category',
                                  style: TextStyle(
                                    color:
                                        value == null ? hintColor : textColor,
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
                          _markMetadataChanged(dialogSetState);
                        },
                        decoration: InputDecoration(
                          labelText: 'Description',
                          hintText: 'Describe the file content',
                          labelStyle: const TextStyle(color: hintColor),
                          hintStyle: const TextStyle(color: hintColor),
                          filled: true,
                          fillColor: inputFillColor,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                              color: inputBorderColor,
                            ),
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
                            'Tags (select one or more)',
                            style: TextStyle(color: hintColor),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children:
                                _availableTags.map((tag) {
                                  final isSelected = _selectedTags.contains(
                                    tag,
                                  );
                                  return FilterChip(
                                    label: Text(
                                      tag,
                                      style: TextStyle(
                                        color:
                                            isSelected
                                                ? Colors.black
                                                : textColor,
                                      ),
                                    ),
                                    selected: isSelected,
                                    onSelected:
                                        (_isUploading || _isAnalyzing)
                                            ? null
                                            : (bool selected) {
                                              dialogSetState(() {
                                                if (selected) {
                                                  _selectedTags.add(tag);
                                                } else {
                                                  _selectedTags.remove(tag);
                                                }
                                                _markMetadataChanged(
                                                  dialogSetState,
                                                );
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
                                'Suggested path:',
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
                                  'Upload in progress...',
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
                  child: const Text('Cancel'),
                  onPressed:
                      (_isUploading || _isAnalyzing)
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
                  onPressed:
                      (_isUploading || _isAnalyzing || _selectedFile == null)
                          ? null
                          : () async {
                            if (_needsRefresh) {
                              await _analyzeAndSuggestPath(dialogSetState);
                            } else {
                              await _uploadFile(dialogSetState, dialogContext);
                            }
                          },
                  child:
                      _isUploading
                          ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: buttonTextColor,
                            ),
                          )
                          : Text(_needsRefresh ? 'Refresh' : 'Upload'),
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
                              onSubmitted:
                                  (_) => _processQuestion(
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
                                  tooltip: 'Upload to GCS',
                                  onPressed:
                                      _isLoading ? null : _showUploadDialog,
                                ),
                                // Send Button
                                ElevatedButton(
                                  onPressed:
                                      _isLoading ||
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
                                  child:
                                      _isLoading &&
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
