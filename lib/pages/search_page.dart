import 'dart:convert';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:easy_query/services/gemini_flash_service.dart';
import 'package:easy_query/services/big_query_service.dart';
import 'package:easy_query/pages/result_page.dart';
import 'package:easy_query/services/cloud_storage_service.dart';
import 'package:easy_query/services/data_orchestration_service.dart';

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

  Future<String> _getLatestAvailablePartition(
    String datasetId, 
    String tableId,
    List<Map<String, dynamic>> bronzeMetadata // Passa i metadati bronze
  ) async {
    // Strategia 1: Prova a derivare dall'ultimo file bronze processato
    if (bronzeMetadata.isNotEmpty) {
      try {
        // Ordina i metadata per metadata_ingestion_time se non già ordinati
        // (La tua query li ordina già DESC)
        final latestBronzeFile = bronzeMetadata.first;
        final String? eventTimeString = latestBronzeFile['event_time'] as String?; // o metadata_ingestion_time
        
        if (eventTimeString != null) {
          // Il formato dai log è "2025-05-11T20:53:20.%fZ"
          // Dobbiamo normalizzarlo per DateTime.parse
          final normalizedEventTime = eventTimeString.replaceFirstMapped(
            RegExp(r'\.%f(Z?)$'), // Gestisce %f o %fZ
            (match) => ".000${match.group(1) ?? 'Z'}" // Sostituisci con millisecondi fissi
          );

          final DateTime eventDate = DateTime.parse(normalizedEventTime);
          final String derivedPartition = "${eventDate.year}/${eventDate.month.toString().padLeft(2, '0')}/${eventDate.day.toString().padLeft(2, '0')}";
          log('Derived latest partition for sampling: $derivedPartition from bronze metadata');
          return derivedPartition;
        }
      } catch (e) {
        log('Could not derive partition from bronze metadata: $e');
      }
    }

    // Strategia 2: Prova a interrogare INFORMATION_SCHEMA.PARTITIONS (più complesso, richiede permessi)
    // Per ora, usiamo un fallback se la strategia 1 fallisce
    // TODO: Implementare una logica di fallback migliore se necessario, 
    //       come interrogare INFORMATION_SCHEMA.PARTITIONS per la partizione MAX.
    //       SELECT MAX(partition_id) FROM `progetto.dataset.INFORMATION_SCHEMA.PARTITIONS` WHERE table_name = 'nome_tabella'

    log('Falling back to a default recent partition for sampling (adjust if needed).');
    // Fallback a una data recente (ESEMPIO! Adatta o rendi più dinamico)
    final now = DateTime.now().toUtc(); // Usa UTC per coerenza con le partizioni GCS
    return "${now.year}/${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')}";
  }


  Future<void> _processQuestion(String question) async {
    if (question.trim().isEmpty) {
      if (mounted) {
        setState(() { _errorMessage = 'Please enter a question'; });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = '';
        _currentExecutingQuery = 'Translating request to English...';
      });
    }

    List<Map<String, dynamic>> cloudFilesMetadata = []; // Inizializza per il blocco finally

    try {
      final projectId = widget.bigQueryService.projectId;
      final datasets = await widget.bigQueryService.getDatasets();
      log('List of datasets: $datasets');
      if (datasets.isEmpty) throw Exception("No datasets found in the project.");

      final Map<String, List<String>> datasetTablesMap = {};
      for (var datasetId in datasets) {
        if (datasetId.toLowerCase() != 'metadata_store') {
          final tables = await widget.bigQueryService.getTables(datasetId);
          datasetTablesMap[datasetId] = tables;
        }
      }
      log('Dataset to tables mapping: $datasetTablesMap');

      List<Map<String, dynamic>> schemas = [];
      List<String> tableNames = [];
      Map<String, List<Map<String, dynamic>>> sampleData = {};

      // Recupera prima i metadati bronze, potrebbero servire per derivare partizioni campione
      cloudFilesMetadata = await widget.bigQueryService.getBronzeMetadata();
      log('Cloud files metadata (bronze): ${jsonEncode(cloudFilesMetadata)}');


      for (var entry in datasetTablesMap.entries) {
        final targetDataset = entry.key;
        final tablesInDataset = entry.value;
        for (var tableIdInDataset in tablesInDataset) {
          final fullTableName = '$projectId.$targetDataset.$tableIdInDataset';
          try {
            final schemaJson = await widget.bigQueryService.getTableSchema(targetDataset, tableIdInDataset);
            final Map<String, dynamic> schemaMap = jsonDecode(schemaJson);
            schemas.add(schemaMap); // schemaMap è già un Map<String, dynamic>
            tableNames.add(fullTableName);

            // MODIFICA: Usa TABLESAMPLE invece di filtri di partizione per tutte le tabelle
            // per evitare completamente problemi con partizioni Hive
            String sampleQuery;
            
            if (targetDataset == 'silver_zone') {
              // Per tabelle silver_zone, usa LIMIT senza filtri di partizione
              sampleQuery = "SELECT * FROM `$fullTableName` LIMIT 15";
              log("Using simple LIMIT query for silver_zone table $fullTableName to avoid partition issues");
            } else {
              // Per altre tabelle usa TABLESAMPLE
              sampleQuery = "SELECT * FROM `$fullTableName` TABLESAMPLE SYSTEM (1 PERCENT) LIMIT 15";
            }
            
            try {
              final tableSample = await widget.bigQueryService.executeQuery(sampleQuery);
              sampleData[fullTableName] = tableSample;
            } catch (e) {
              log('Warning: Failed to get sample data from $fullTableName (Query: $sampleQuery). Error: $e');
              
              // Se fallisce con la query principale, prova un fallback con solo LIMIT
              if (targetDataset == 'silver_zone') {
                try {
                  final fallbackQuery = "SELECT * FROM `$fullTableName` LIMIT 5";
                  log("Trying fallback query for $fullTableName: $fallbackQuery");
                  final fallbackSample = await widget.bigQueryService.executeQuery(fallbackQuery);
                  sampleData[fullTableName] = fallbackSample;
                  log("Fallback query successful for $fullTableName");
                } catch (fallbackError) {
                  log('Failed fallback query for $fullTableName: $fallbackError');
                  sampleData[fullTableName] = []; // Inizializza a lista vuota in caso di errore
                }
              } else {
                sampleData[fullTableName] = []; // Inizializza a lista vuota in caso di errore
              }
            }
          } catch (e) {
            log('Warning: Failed to get schema for table $fullTableName. Skipping. Error: $e');
          }
        }
      }
      log('Table schemas fetched: ${schemas.length}');
      log('Sample data fetched for ${sampleData.keys.length} tables');
      
      if (mounted) {
        setState(() { _currentExecutingQuery = 'Orchestrating data transformations...'; });
      }
      
      final dataOrchestrationService = DataOrchestrationService(
        geminiService: widget.geminiService,
        bigQueryService: widget.bigQueryService,
        cloudStorageService: widget.cloudStorageService,
        bronzeToSilverUrl: 'https://europe-central2-soy-transducer-456512-t0.cloudfunctions.net/bronze-to-silver',
        silverToGoldUrl: 'https://europe-central2-soy-transducer-456512-t0.cloudfunctions.net/silver-to-gold',
      );
      
      final orchestrationResult = await dataOrchestrationService.analyzeQueryAndPrepareData(
        question, schemas, tableNames, sampleData, cloudFilesMetadata,
      );
      
      final contextAnalysis = orchestrationResult['contextAnalysis'];
      // Assicurati che updatedSchemas e updatedTableNames siano del tipo corretto
      List<Map<String, dynamic>> updatedSchemas = (orchestrationResult['updatedSchemas'] as List?)
          ?.map((item) => item as Map<String, dynamic>)
          ?.toList() ?? [];
      final List<String> updatedTableNames = (orchestrationResult['updatedTableNames'] as List?)
          ?.map((item) => item.toString())
          ?.toList() ?? [];
      
      if (mounted) {
        setState(() { _currentExecutingQuery = 'Refreshing schemas...'; });
      }
      
      // NUOVA PARTE: Aggiorna tutti gli schemi delle tabelle in silver_zone
      updatedSchemas = await _refreshSilverZoneSchemas(updatedTableNames, updatedSchemas);
      
      if (mounted) {
        setState(() { _currentExecutingQuery = 'Building optimized query...'; });
      }

      final sqlQuery = await widget.geminiService.generateSqlQuery(
        question,
        jsonEncode(updatedSchemas), 
        jsonEncode(updatedTableNames), 
        sampleData: sampleData,
        contextAnalysis: contextAnalysis,
      );

      final cleanedSqlQuery = sqlQuery.replaceAll('sql', ' ').replaceAll(RegExp(r'\s+'), ' ')
                                  .replaceAll(RegExp(r'\n'), ' ').replaceAll('```', '')
                                  .replaceAll(RegExp(r'^\s*SELECT', caseSensitive: false), 'SELECT').trim();
      log('Executing SQL query from Gemini: $cleanedSqlQuery');

      if (mounted) {
        setState(() { _currentExecutingQuery = cleanedSqlQuery; });
      }

      final results = await widget.bigQueryService.executeQuery(cleanedSqlQuery);
      log('Query Results from BQ: ${results.length} rows.'); // Evita di loggare tutti i risultati se grandi

      if (mounted) {
        setState(() { _currentExecutingQuery = 'Analyzing query results...'; });
      }

      final analysis = await widget.geminiService.analyzeQueryResults(cleanedSqlQuery, results);

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => ResultPage(
          question: question, sqlQuery: cleanedSqlQuery, results: results, analysis: analysis,
        )),
      );
    } catch (e, stackTrace) { // Aggiunto stackTrace
      log('Error processing question: ${e.toString()}', error: e, stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _currentExecutingQuery = null;
        });
      }
    }
  }

  /// Aggiorna gli schemi di tutte le tabelle nel dataset silver_zone
  Future<List<Map<String, dynamic>>> _refreshSilverZoneSchemas(
      List<String> tableNames, 
      List<Map<String, dynamic>> currentSchemas) async {
    final List<Map<String, dynamic>> refreshedSchemas = List.from(currentSchemas);
    final String projectId = widget.bigQueryService.projectId;
    const String silverZoneDataset = 'silver_zone';
    
    try {
      // Ottieni l'elenco completo delle tabelle in silver_zone
      final silverZoneTables = await widget.bigQueryService.getTables(silverZoneDataset);
      log('Retrieved ${silverZoneTables.length} tables from silver_zone dataset');
      
      // Per ogni tabella in silverZoneTables
      for (var tableId in silverZoneTables) {
        final fullTableName = '$projectId.$silverZoneDataset.$tableId';
        
        // Se la tabella è tra quelle che ci interessano
        if (tableNames.contains(fullTableName)) {
          try {
            log('Refreshing schema for: $fullTableName');
            final schemaJson = await widget.bigQueryService.getTableSchema(silverZoneDataset, tableId);
            final Map<String, dynamic> updatedSchema = jsonDecode(schemaJson);
            
            // NUOVA PARTE: Controlla se esiste un campo date_partition nello schema e impostalo
            // esplicitamente come STRING non-Hive (per evitare che BigQuery lo interpreti come partizione)
            if (updatedSchema.containsKey('schema') && 
                updatedSchema['schema'].containsKey('fields')) {
              List<dynamic> fields = updatedSchema['schema']['fields'];
              bool hasDatePartition = fields.any((field) => 
                  field is Map<String, dynamic> && 
                  field.containsKey('name') && 
                  field['name'] == 'date_partition');
              
              if (hasDatePartition) {
                log('Found date_partition field in schema for $fullTableName, ensuring it\'s properly typed as STRING');
                // Potremmo ulteriormente modificare i metadati dello schema qui per assicurarci
                // che BigQuery non lo interpreti come partizione...
              }
            }
            
            // Trova l'indice dello schema corrente per questa tabella (se esiste)
            final existingIndex = refreshedSchemas.indexWhere((schema) {
              final tableRef = schema['tableReference'];
              return tableRef != null && 
                     tableRef['projectId'] == projectId &&
                     tableRef['datasetId'] == silverZoneDataset &&
                     tableRef['tableId'] == tableId;
            });
            
            if (existingIndex >= 0) {
              // Sostituisci lo schema esistente
              refreshedSchemas[existingIndex] = updatedSchema;
              log('Updated existing schema for $fullTableName');
            } else {
              // Aggiungi il nuovo schema
              refreshedSchemas.add(updatedSchema);
              log('Added new schema for $fullTableName');
            }
          } catch (e) {
            log('Warning: Failed to refresh schema for $fullTableName: $e');
          }
        }
      }
      
      return refreshedSchemas;
    } catch (e) {
      log('Error refreshing silver_zone schemas: $e');
      return currentSchemas; // Ritorna gli schemi originali in caso di errore
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
