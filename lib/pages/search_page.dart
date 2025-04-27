import 'dart:convert';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart'; // Added
import 'package:easy_query/services/gemini_flash_service.dart';
import 'package:easy_query/services/big_query_service.dart';
import 'package:easy_query/pages/result_page.dart';

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
  bool _isLoading = false; // Loading state for query execution
  String _errorMessage = '';
  String? _currentExecutingQuery;

  // --- State for Upload Dialog ---
  final TextEditingController _tableNameController = TextEditingController();
  bool _isUploading = false; // Loading state for file upload
  String _uploadErrorMessage = '';
  PlatformFile? _selectedFile;
  // List<String> _availableDatasets = []; // Moved local to dialog fetch
  String? _selectedDataset;
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
    _tableNameController.dispose(); // Dispose the new controller
    // Consider calling widget.bigQueryService.dispose() here or in the parent widget
    super.dispose();
  }

  // Modifiche al metodo _processQuestion

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

  // --- CSV Upload Methods ---

  Future<void> _pickFile(StateSetter dialogSetState) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true, // Important to get file bytes
      );

      if (result != null && result.files.first.bytes != null) {
        dialogSetState(() {
          _selectedFile = result.files.first;
          _uploadErrorMessage = ''; // Clear previous error
        });
      } else if (result != null && result.files.first.bytes == null) {
        // Handle web case where bytes might not be loaded automatically
        log(
          'File selected, but bytes are null. This might happen on web without withData=true.',
        );
        dialogSetState(() {
          _uploadErrorMessage = 'Could not load file data. Please try again.';
          _selectedFile = null;
        });
      } else {
        // User canceled the picker
        log('User cancelled file picker');
      }
    } catch (e) {
      log('Error picking file: $e');
      dialogSetState(() {
        _uploadErrorMessage = 'Error picking file: ${e.toString()}';
        _selectedFile = null;
      });
    }
  }

  Future<void> _uploadCsvFile(
    StateSetter dialogSetState,
    BuildContext dialogContext,
  ) async {
    if (_selectedFile == null ||
        _selectedDataset == null ||
        _tableNameController.text.trim().isEmpty) {
      dialogSetState(() {
        _uploadErrorMessage =
            'Please select a file, dataset, and enter a table name.';
      });
      return;
    }
    // Double check bytes are loaded (especially for web)
    if (_selectedFile!.bytes == null) {
      dialogSetState(() {
        _uploadErrorMessage =
            'File data is missing. Please re-select the file.';
      });
      return;
    }

    dialogSetState(() {
      _isUploading = true;
      _uploadErrorMessage = '';
    });

    try {
      final tableName = _tableNameController.text.trim();
      final datasetId = _selectedDataset!;
      final csvBytes =
          _selectedFile!.bytes!; // Non-null asserted due to checks above

      log(
        'Attempting to upload ${_selectedFile!.name} to $datasetId.$tableName (${csvBytes.lengthInBytes} bytes)',
      );
      await widget.bigQueryService.uploadCsvToTable(
        datasetId,
        tableName,
        csvBytes,
      );
      log('Upload successful for ${_selectedFile!.name}');

      // Close dialog on success
      if (Navigator.canPop(dialogContext)) {
        Navigator.pop(dialogContext);
      }
      // Show success message using ScaffoldMessenger
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'File "${_selectedFile!.name}" uploaded successfully to $datasetId.$tableName!',
            style: const TextStyle(color: Colors.black),
          ), // Black text for contrast
          backgroundColor: Colors.green[100], // Lighter green
          behavior: SnackBarBehavior.floating, // Optional: makes it float
          shape: RoundedRectangleBorder(
            // Optional: rounded corners
            borderRadius: BorderRadius.circular(10.0),
          ),
          margin: const EdgeInsets.all(10), // Add margin for floating snackbar
        ),
      );
      // Clear state variables after successful upload
      setState(() {
        _selectedFile = null;
        _selectedDataset = null;
        _tableNameController.clear();
        _uploadErrorMessage = '';
        // _availableDatasets = []; // No need to clear here, fetched in dialog
      });
    } catch (e) {
      log('Error uploading file: $e', error: e);
      String friendlyErrorMessage;
      if (e is Exception) {
        friendlyErrorMessage = e.toString().replaceFirst(
          'Exception: ',
          '',
        ); // Cleaner message
      } else {
        friendlyErrorMessage = 'An unexpected error occurred during upload.';
      }
      dialogSetState(() {
        // Make error more specific if possible (e.g., check for common BQ errors)
        _uploadErrorMessage = 'Upload failed: $friendlyErrorMessage';
      });
    } finally {
      // Ensure isUploading is set to false even if dialog closing fails
      if (mounted) {
        // Check if the widget is still in the tree
        dialogSetState(() {
          _isUploading = false;
        });
      }
    }
  }

  void _showUploadDialog() async {
    // Reset state for the dialog each time it opens
    // No need for global setState here, StatefulBuilder manages dialog state
    _selectedFile = null;
    String? localSelectedDataset = null; // Use local var for initial state
    _tableNameController.clear();
    _uploadErrorMessage = '';
    _isUploading = false;
    List<String> datasets = []; // Local variable for datasets in dialog scope
    String initialError = '';

    // Fetch datasets *before* showing the dialog or show loading inside
    try {
      datasets = await widget.bigQueryService.getDatasets();
      // If only one dataset, pre-select it
      if (datasets.length == 1) {
        localSelectedDataset = datasets.first;
      }
    } catch (e) {
      log('Error fetching datasets for dialog: $e');
      initialError =
          'Could not load datasets: ${e.toString().replaceFirst('Exception: ', '')}';
      // This error will be shown inside the dialog
    }

    if (!mounted)
      return; // Check if widget is still mounted before showing dialog

    // Show the dialog
    showDialog(
      context: context,
      barrierDismissible: !_isUploading, // Prevent closing while uploading
      builder: (BuildContext dialogContext) {
        // Define dark theme colors (adjust as needed to match your exact theme)
        const dialogBackgroundColor = Color.fromARGB(255, 30, 30, 30);
        const textColor = Colors.white;
        const hintColor = Colors.grey;
        const inputFillColor = Color.fromARGB(255, 50, 50, 50);
        const inputBorderColor = Colors.white54;
        final errorColor = Colors.redAccent[100]; // Brighter red for dark bg
        const buttonTextColor = Colors.black;
        const primaryButtonColor = Colors.white;
        const secondaryButtonColor = Color.fromARGB(255, 80, 80, 80);
        const accentColor = Colors.white; // For progress indicator

        // Use StatefulBuilder to manage the dialog's internal state independently
        return StatefulBuilder(
          builder: (context, StateSetter dialogSetState) {
            // Use the locally fetched dataset state within the builder
            _selectedDataset = localSelectedDataset;

            // Function to update state within the dialog
            void updateDialogState(VoidCallback fn) {
              dialogSetState(fn);
            }

            return AlertDialog(
              backgroundColor: dialogBackgroundColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Text(
                'Upload CSV to BigQuery',
                style: TextStyle(color: textColor),
              ),
              content: SingleChildScrollView(
                child: ListBody(
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
                          label: const Text('Select CSV'),
                          onPressed:
                              _isUploading
                                  ? null
                                  : () async {
                                    await _pickFile(
                                      updateDialogState,
                                    ); // Use local state update
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

                    // Dataset Dropdown or Loading/Error
                    if (initialError.isNotEmpty)
                      Text(initialError, style: TextStyle(color: errorColor))
                    else if (datasets.isEmpty && initialError.isEmpty)
                      const Center(
                        child: CircularProgressIndicator(color: accentColor),
                      ) // Loading datasets
                    else
                      DropdownButtonFormField<String>(
                        value: _selectedDataset,
                        dropdownColor:
                            dialogBackgroundColor, // Match background
                        style: const TextStyle(color: textColor),
                        hint: const Text(
                          'Select Dataset',
                          style: TextStyle(color: hintColor),
                        ),
                        iconEnabledColor: textColor,
                        onChanged:
                            _isUploading
                                ? null
                                : (String? newValue) {
                                  updateDialogState(() {
                                    // Use local state update
                                    localSelectedDataset =
                                        newValue; // Update local variable
                                    _selectedDataset =
                                        newValue; // Update state variable if needed elsewhere
                                  });
                                },
                        items:
                            datasets.map<DropdownMenuItem<String>>((
                              String value,
                            ) {
                              return DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              );
                            }).toList(),
                        decoration: InputDecoration(
                          labelText: 'Target Dataset',
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
                            borderSide: const BorderSide(
                              color: accentColor,
                            ), // Highlight focus
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),

                    const SizedBox(height: 15),

                    // Table Name Input
                    TextField(
                      controller: _tableNameController,
                      enabled: !_isUploading,
                      style: const TextStyle(
                        color: textColor,
                      ), // Input text color
                      decoration: InputDecoration(
                        labelText: 'New Table Name',
                        labelStyle: const TextStyle(color: hintColor),
                        hintText: 'Enter name for the new table',
                        hintStyle: const TextStyle(color: hintColor),
                        filled: true,
                        fillColor: inputFillColor,
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: inputBorderColor),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: accentColor,
                          ), // Highlight focus
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        // Make counter text white if needed (usually inherits)
                        counterStyle: const TextStyle(color: hintColor),
                      ),
                      maxLength: 1024, // BigQuery max table name length
                    ),
                    const SizedBox(
                      height: 10,
                    ), // Reduced space before indicator/error
                    // Upload Progress Indicator
                    if (_isUploading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10.0),
                        child: Center(
                          child: CircularProgressIndicator(color: accentColor),
                        ),
                      ),

                    // Upload Error Message
                    if (_uploadErrorMessage.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10.0),
                        child: Text(
                          _uploadErrorMessage,
                          style: TextStyle(
                            color: errorColor,
                          ), // Use brighter red
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: hintColor),
                  child: const Text('Cancel'),
                  onPressed:
                      _isUploading
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
                    disabledBackgroundColor:
                        secondaryButtonColor, // Indicate disabled state
                  ),
                  // Update condition to use localSelectedDataset for initial check if needed
                  onPressed:
                      (_selectedFile == null ||
                              localSelectedDataset == null ||
                              _tableNameController.text.trim().isEmpty ||
                              _isUploading)
                          ? null // Disable if conditions not met or already uploading
                          : () async {
                            // Ensure _selectedDataset is correctly set before calling upload
                            _selectedDataset = localSelectedDataset;
                            await _uploadCsvFile(
                              updateDialogState,
                              dialogContext,
                            ); // Use local state update
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
                          : const Text('Upload'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // --- End CSV Upload Methods ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: const Color.fromARGB(
          255,
          20,
          20,
          20,
        ), // Your original Background color
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
                  const SizedBox(height: 16), // Added spacing after logo
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
                  const SizedBox(height: 32), // Increased spacing before card
                  // *** Wrap Card with ConstrainedBox ***
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 900,
                    ), // Limit max width
                    child: Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      color: const Color.fromARGB(
                        221,
                        10,
                        10,
                        10,
                      ), // Dark card color
                      elevation: 6,
                      child: Padding(
                        padding: const EdgeInsets.all(
                          16,
                        ), // Increased padding slightly
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
                                  borderSide:
                                      BorderSide
                                          .none, // No border needed with fill
                                ),
                                prefixIcon: const Icon(
                                  Icons.search,
                                  color: Colors.white70,
                                ),
                                fillColor: Colors.grey[850], // Dark fill
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
                            // --- Row for Buttons ---
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment
                                      .spaceBetween, // Align buttons
                              children: [
                                // Upload Button - styled consistently
                                IconButton(
                                  icon: const Icon(Icons.upload_file),
                                  color:
                                      Colors.white70, // Consistent icon color
                                  tooltip: 'Upload CSV to BigQuery',
                                  onPressed:
                                      _isLoading
                                          ? null
                                          : _showUploadDialog, // Disable during query load
                                ),
                                // Send Button (existing - style is already good)
                                ElevatedButton(
                                  onPressed:
                                      _isLoading ||
                                              _questionController.text
                                                  .trim()
                                                  .isEmpty
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
                                        _questionController.text.trim().isEmpty
                                            ? Colors
                                                .grey[600] // Darker grey when disabled
                                            : Colors
                                                .white, // Primary action color
                                    foregroundColor: Colors.black,
                                    elevation: 8,
                                    shadowColor: Colors.white.withOpacity(
                                      0.5,
                                    ), // Subtle shadow
                                    disabledBackgroundColor:
                                        Colors
                                            .grey
                                            .shade800, // Explicit disabled color
                                  ),
                                  child:
                                      _isLoading &&
                                              _currentExecutingQuery == null
                                          ? const SizedBox(
                                            // Consistent size
                                            height: 20,
                                            width: 20,
                                            child: CircularProgressIndicator(
                                              color:
                                                  Colors
                                                      .black, // Match foreground
                                              strokeWidth: 3,
                                            ),
                                          )
                                          : const Icon(
                                            Icons.send,
                                            size: 20,
                                            color:
                                                Colors.black, // Always visible
                                          ),
                                ),
                              ],
                            ),
                            // --- End Row for Buttons ---
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Loading/Executing Query Banner - Constrained width as well
                  if (_isLoading && _currentExecutingQuery != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: Container(
                        margin: const EdgeInsets.only(
                          bottom: 16,
                        ), // Space below banner
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ), // Adjusted padding
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(
                            0.15,
                          ), // More subtle green
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.green.shade300.withOpacity(0.5),
                          ),
                        ),
                        child: Row(
                          // Add icon for visual cue
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
                                style: TextStyle(
                                  color: Colors.green.shade100,
                                ), // Lighter green text
                                maxLines: 2, // Allow wrap slightly
                                minLines: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Error box for Query Execution - Constrained width as well
                  if (_errorMessage.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: Container(
                        margin: const EdgeInsets.only(
                          bottom: 16,
                        ), // Space below banner
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ), // Adjusted padding
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(
                            0.15,
                          ), // More subtle red
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.redAccent.shade100.withOpacity(0.5),
                          ),
                        ),
                        child: Row(
                          // Add icon for visual cue
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
                                //'Query Error: $_errorMessage', // Already includes 'Error:'
                                _errorMessage,
                                style: TextStyle(
                                  color: Colors.redAccent.shade100,
                                ), // Brighter red text
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  const SizedBox(height: 16), // Adjusted spacing
                  // Footer
                  Text(
                    'Powered by Gemini Flash & Google Cloud', // Updated text slightly
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                  const SizedBox(height: 16), // Space at the bottom
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
