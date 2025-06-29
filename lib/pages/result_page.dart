import 'package:flutter/material.dart';
import 'package:easy_query/services/graphics_service.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:io' if (dart.library.html) 'dart:html';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_html/html.dart' as webhtml;
import 'package:easy_query/services/big_query_service.dart';

class ResultPage extends StatefulWidget {
  final String question;
  final String sqlQuery;
  final List<Map<String, dynamic>> results;
  final String analysis;
  // Aggiungiamo un campo per il servizio BigQuery
  final BigQueryService bigQueryService;

  const ResultPage({
    super.key,
    required this.question,
    required this.sqlQuery,
    required this.results,
    required this.analysis,
    required this.bigQueryService,
  });

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final GraphicsService _graphicsService = GraphicsService();
  final ScrollController _scrollController = ScrollController();

  // State for chart configuration
  String _selectedXAxis = '';
  String _selectedYAxis = '';
  String _selectedChartType = 'Automatic';
  
  // Advanced options
  final Map<String, dynamic> _chartOptions = {
    'showGrid': true,
    'showTitle': true,
    'rotateLabels': false,
    'showValues': false,
    'barWidth': 16.0,
    'lineWidth': 3.0,
    'showArea': false,
    'areaOpacity': 0.2,
    'curvedLines': true,
    'showDots': true,
    'decimalPlaces': 1,
    'leftAxisWidth': 50,
    'centerSpaceRadius': 40.0,
    'showPercentValues': true,
    'bins': 10,
    'showTrendline': false,
    'showAvgLine': false,
    'normalizeValues': false,
    'colorScheme': 'default',
    // Nuove opzioni per migliorare la visualizzazione
    'enhancedSpacing': true,       // Aumenta la spaziatura tra gli elementi
    'smartLabels': true,           // Etichette intelligenti per evitare sovrapposizioni
    'maxDisplayedLabels': 10,      // Numero massimo di etichette da mostrare sull'asse X
    'labelAngle': 45.0,            // Angolo di rotazione per le etichette dell'asse X
    'enableZoom': true,            // Attiva lo zoom
    'zoomLevel': 1.0,              // Livello di zoom iniziale
  };
  
  // Per lo zoom e la panoramica
  double _zoomLevel = 1.0;
  Offset _panOffset = Offset.zero;
  bool _isPanning = false;
  final TransformationController _transformController = TransformationController();
  
  // Statistics for current dataset
  Map<String, dynamic> _statistics = {};
  
  // Selected data columns for radar chart
  List<String> _selectedFields = [];
  
  // For filtering
  RangeValues? _numericFilter;
  double? _minValue;
  double? _maxValue;
  List<Map<String, dynamic>> _filteredResults = [];
  bool _isDataFiltered = false;
  
  // For data search
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // Aggiungiamo una key per catturare i grafici per l'esportazione
  final GlobalKey _chartKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_handleTabChange);
    
    // Set initial filtered results
    _filteredResults = List.from(widget.results);
    
    // Auto-select appropriate columns for chart axes based on data types
    if (widget.results.isNotEmpty) {
      final columns = widget.results.first.keys.toList();
      
      // Try to find a non-numeric column for X axis
      _selectedXAxis = columns.firstWhere(
        (col) => !_isNumeric(widget.results.first[col].toString()),
        orElse: () => columns.first,
      );
      
      // Try to find a numeric column for Y axis
      _selectedYAxis = columns.firstWhere(
        (col) => _isNumeric(widget.results.first[col].toString()) && col != _selectedXAxis,
        orElse: () => columns.length > 1 ? columns[1] : columns.first,
      );
      
      // Pre-select fields for radar chart (up to 5 numeric fields)
      _selectedFields = columns
          .where((col) => _isNumeric(_getFirstNonEmptyValue(col)))
          .take(5)
          .toList();
      
      // Calculate value range for filtering
      _calculateNumericRange();
      
      // Calculate statistics for numeric columns
      _calculateStatistics();
    }
    
    // Listen for search queries
    _searchController.addListener(_handleSearch);
  }

  void _handleTabChange() {
    // When switching to the Charts tab, recalculate stats
    if (_tabController.index == 1) {
      _calculateStatistics();
    }
  }

  void _calculateNumericRange() {
    if (_selectedYAxis.isNotEmpty && widget.results.isNotEmpty) {
      List<double> values = [];
      
      for (var row in widget.results) {
        final val = double.tryParse(row[_selectedYAxis].toString());
        if (val != null) {
          values.add(val);
        }
      }
      
      if (values.isNotEmpty) {
        values.sort();
        _minValue = values.first;
        _maxValue = values.last;
        _numericFilter = RangeValues(_minValue!, _maxValue!);
      }
    }
  }

  void _calculateStatistics() {
    if (_selectedYAxis.isNotEmpty && _filteredResults.isNotEmpty) {
      List<double> values = [];
      
      for (var row in _filteredResults) {
        final val = double.tryParse(row[_selectedYAxis].toString());
        if (val != null) {
          values.add(val);
        }
      }
      
      if (values.isNotEmpty) {
        _statistics = _graphicsService.calculateStatistics(values);
      }
    }
  }

  void _handleSearch() {
    setState(() {
      _searchQuery = _searchController.text.toLowerCase();
      _applyFilters();
    });
  }

  String _getFirstNonEmptyValue(String column) {
    for (var row in widget.results) {
      if (row[column] != null && row[column].toString().isNotEmpty) {
        return row[column].toString();
      }
    }
    return '';
  }

  bool _isNumeric(String str) {
    if (str.isEmpty) return false;
    return double.tryParse(str) != null;
  }

  void _applyFilters() {
    setState(() {
      _filteredResults = widget.results.where((row) {
        // Apply numeric filter if available
        if (_numericFilter != null && _isNumeric(row[_selectedYAxis].toString())) {
          final value = double.tryParse(row[_selectedYAxis].toString()) ?? 0;
          if (value < _numericFilter!.start || value > _numericFilter!.end) {
            return false;
          }
        }
        
        // Apply search filter if available
        if (_searchQuery.isNotEmpty) {
          bool matchesSearch = false;
          row.forEach((key, value) {
            if (value.toString().toLowerCase().contains(_searchQuery)) {
              matchesSearch = true;
            }
          });
          return matchesSearch;
        }
        
        return true;
      }).toList();
      
      _isDataFiltered = _filteredResults.length != widget.results.length;
      
      // Update statistics based on filtered data
      _calculateStatistics();
    });
  }

  void _resetFilters() {
    setState(() {
      _searchController.clear();
      _searchQuery = '';
      if (_minValue != null && _maxValue != null) {
        _numericFilter = RangeValues(_minValue!, _maxValue!);
      }
      _filteredResults = List.from(widget.results);
      _isDataFiltered = false;
      _calculateStatistics();
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    _searchController.removeListener(_handleSearch);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Analysis Results',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: 'Save to Gold Zone',
            onPressed: () => _showSaveToGoldDialog(),
          ),
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Help',
            onPressed: () => _showHelpDialog(context),
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share Results',
            onPressed: () => _showShareOptionsDialog(),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(
              icon: Icon(Icons.table_chart),
              text: 'Data',
            ),
            Tab(
              icon: Icon(Icons.insert_chart),
              text: 'Visualize',
            ),
            Tab(
              icon: Icon(Icons.analytics),
              text: 'Analysis',
            ),
          ],
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white.withOpacity(0.7),
        ),
      ),
      body: Container(
        color: const Color.fromARGB(255, 20, 20, 20),
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildDataTab(),
            _buildChartsTab(),
            _buildAnalysisTab(),
          ],
        ),
      ),
      floatingActionButton: _tabController.index == 1
          ? FloatingActionButton(
              backgroundColor: Theme.of(context).primaryColor,
              child: const Icon(Icons.download),
              onPressed: () => _showExportOptionsDialog(),
              tooltip: 'Export Chart',
            )
          : null,
    );
  }

  Widget _buildDataTab() {
    if (widget.results.isEmpty) {
      return const Center(
        child: Text(
          'No data found for this query',
          style: TextStyle(color: Colors.white),
        ),
      );
    }

    return Column(
      children: [
        // Top bar with search and filter options
        Container(
          padding: const EdgeInsets.all(16.0),
          color: Colors.grey[900],
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Search data...',
                        hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                        prefixIcon: const Icon(Icons.search, color: Colors.white),
                        filled: true,
                        fillColor: Colors.grey[800],
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton(
                    icon: const Icon(Icons.filter_list, color: Colors.white),
                    tooltip: 'Filter Data',
                    onPressed: () => _showFilterDialog(),
                  ),
                  if (_isDataFiltered)
                    IconButton(
                      icon: const Icon(Icons.clear_all, color: Colors.orange),
                      tooltip: 'Reset Filters',
                      onPressed: _resetFilters,
                    ),
                ],
              ),
              
              // Query info container
              Container(
                margin: const EdgeInsets.only(top: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[850],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[700]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.help, size: 20, color: Colors.blue),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.question,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const Divider(color: Colors.grey),
                    Row(
                      children: [
                        const Icon(Icons.code, size: 20, color: Colors.green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.sqlQuery,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.content_copy, size: 18, color: Colors.white),
                          tooltip: 'Copy SQL Query',
                          onPressed: () => _copyToClipboard(widget.sqlQuery),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              
              // Result stats
              Padding(
                padding: const EdgeInsets.only(top: 12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Showing ${_filteredResults.length} ${_isDataFiltered ? 'filtered' : ''} rows',
                      style: TextStyle(
                        color: _isDataFiltered ? Colors.orange : Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_isDataFiltered)
                      TextButton.icon(
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Reset Filters'),
                        onPressed: _resetFilters,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.orange,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        
        // Table data
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12.0),
            child: _buildDataTable(),
          ),
        ),
      ],
    );
  }

  Widget _buildDataTable() {
    // Get column names from first result
    final columnNames = widget.results.first.keys.toList();
    
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowColor: MaterialStateProperty.all(Colors.grey[850]),
        dataRowColor: MaterialStateProperty.resolveWith<Color?>(
          (Set<MaterialState> states) {
            if (states.contains(MaterialState.selected))
              return Colors.blue.withOpacity(0.3);
            return states.contains(MaterialState.hovered)
                ? Colors.grey[800]
                : Colors.grey[900];
          },
        ),
        dividerThickness: 0.2,
        columnSpacing: 24,
        showCheckboxColumn: false,
        columns: columnNames.map((name) {
          return DataColumn(
            label: Tooltip(
              message: 'Column: $name',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 4),
                  _isNumeric(_getFirstNonEmptyValue(name))
                      ? const Icon(Icons.numbers, size: 14, color: Colors.blue)
                      : const Icon(Icons.text_fields, size: 14, color: Colors.green),
                ],
              ),
            ),
            tooltip: 'Column: $name',
            onSort: (columnIndex, ascending) {
              // Could add sorting functionality here
            },
          );
        }).toList(),
        rows: _filteredResults.map((row) {
          return DataRow(
            cells: columnNames.map((col) {
              final value = row[col]?.toString() ?? '';
              return DataCell(
                Tooltip(
                  message: value,
                  child: Text(
                    value,
                    style: TextStyle(
                      color: _isNumeric(value) ? Colors.lightBlue[100] : Colors.white,
                      fontWeight: _isNumeric(value) ? FontWeight.w500 : FontWeight.normal,
                    ),
                  ),
                ),
                onTap: () => _showCellDetails(col, value),
              );
            }).toList(),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildChartsTab() {
    if (widget.results.isEmpty) {
      return const Center(
        child: Text(
          'No data available for visualization',
          style: TextStyle(color: Colors.white),
        ),
      );
    }

    return Column(
      children: [
        // Top settings panel rimane invariato
        Container(
          padding: const EdgeInsets.all(12.0),
          color: Colors.grey[900],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 4.0, bottom: 8.0),
                child: Text(
                  'Visualization Options',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              
              // Chart type and basic controls
              Row(
                children: [
                  // Chart Type Dropdown
                  Expanded(
                    child: _buildDropdown(
                      'Chart Type',
                      _selectedChartType,
                      [
                        'Automatic', 'Bar', 'Line', 'Pie', 'Scatter',
                        'Radar', 'Box Plot', 'Histogram'
                      ],
                      (value) => setState(() {
                        _selectedChartType = value!;
                        _updateFieldSelectionForChartType();
                      }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  
                  // Quick actions
                  IconButton(
                    icon: Icon(
                      _chartOptions['showGrid'] ? Icons.grid_on : Icons.grid_off,
                      color: Colors.white,
                    ),
                    tooltip: _chartOptions['showGrid'] ? 'Hide Grid' : 'Show Grid',
                    onPressed: () => setState(() {
                      _chartOptions['showGrid'] = !_chartOptions['showGrid'];
                    }),
                  ),
                  IconButton(
                    icon: Icon(
                      _chartOptions['showTitle'] ? Icons.title : Icons.offline_pin,
                      color: Colors.white,
                    ),
                    tooltip: _chartOptions['showTitle'] ? 'Hide Title' : 'Show Title',
                    onPressed: () => setState(() {
                      _chartOptions['showTitle'] = !_chartOptions['showTitle'];
                    }),
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings, color: Colors.white),
                    tooltip: 'Advanced Options',
                    onPressed: () => _showChartOptionsDialog(),
                  ),
                ],
              ),
              
              const SizedBox(height: 12),
              
              // Axis selectors
              _buildAxisSelectors(),
              
              // Statistics summary
              if (_statistics.isNotEmpty) _buildStatsSummary(),
              
              // Aggiungiamo un controllo di visibilità per scrollare orizzontalmente
              const Text(
                'Scroll horizontally if chart content is too wide',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
        
        // Guida rapida per l'utente
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          color: Colors.blue.withOpacity(0.1),
          child: Row(
            children: [
              Icon(Icons.info_outline, color: Colors.blue[200], size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Tip: Pinch/spread to zoom, drag to pan. Double-tap to reset. Tap on data points for details.',
                  style: TextStyle(color: Colors.blue[100], fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        
        // Chart display area migliorata con zoom
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(12.0),
            child: Card(
              color: Colors.grey[850],
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: InteractiveViewer(
                  transformationController: _transformController,
                  minScale: 0.5,
                  maxScale: 4.0,
                  onInteractionEnd: (details) {
                    setState(() {
                      _zoomLevel = _transformController.value.getMaxScaleOnAxis();
                      _chartOptions['zoomLevel'] = _zoomLevel;
                    });
                  },
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Calcola la larghezza minima necessaria per il grafico
                      final double minChartWidth = _calculateChartWidth();
                      final double chartWidth = math.max(minChartWidth * 1.2, constraints.maxWidth);
                      
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: chartWidth,
                          height: constraints.maxHeight,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: RepaintBoundary(
                                  key: _chartKey,
                                  child: Stack(
                                    children: [
                                      _buildChart(),
                                      if (_chartOptions['enableZoom'] == true && _zoomLevel > 1.0)
                                        Positioned(
                                          right: 16,
                                          bottom: 16,
                                          child: FloatingActionButton.small(
                                            backgroundColor: Colors.grey[800],
                                            onPressed: _resetZoom,
                                            child: const Icon(Icons.zoom_out_map, size: 18),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              
                              // Aggiungi una legenda sotto il grafico per migliorare la leggibilità
                              if (_shouldShowLegend())
                                Container(
                                  height: 50,
                                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                                  child: _buildChartLegend(),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
  
  void _resetZoom() {
    setState(() {
      _transformController.value = Matrix4.identity();
      _zoomLevel = 1.0;
      _chartOptions['zoomLevel'] = _zoomLevel;
    });
  }
  
  bool _shouldShowLegend() {
    // Mostra la legenda solo per alcuni tipi di grafici
    return ['Bar', 'Line', 'Pie', 'Radar'].contains(_selectedChartType);
  }
  
  Widget _buildChartLegend() {
    // Caso specifico per i grafici a torta
    if (_selectedChartType == 'Pie') {
      return _buildPieLegend();
    }
    
    // Legenda generica per altri tipi di grafici
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: _filteredResults.take(10).map((data) {
          final labelValue = data[_selectedXAxis]?.toString() ?? '';
          final color = _graphicsService.defaultColors[
            _filteredResults.indexOf(data) % _graphicsService.defaultColors.length
          ];
          
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  labelValue.length > 15 ? '${labelValue.substring(0, 12)}...' : labelValue,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
  
  Widget _buildPieLegend() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: _filteredResults.take(10).map((data) {
          final labelValue = data[_selectedXAxis]?.toString() ?? '';
          final numericValue = double.tryParse(data[_selectedYAxis]?.toString() ?? '0') ?? 0;
          final color = _graphicsService.defaultColors[
            _filteredResults.indexOf(data) % _graphicsService.defaultColors.length
          ];
          
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '${labelValue.length > 10 ? '${labelValue.substring(0, 7)}...' : labelValue}: ${numericValue.toStringAsFixed(1)}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
  
  Widget _buildAxisSelectors() {
    // Show appropriate input controls based on chart type
    if (_selectedChartType == 'Radar') {
      return _buildRadarFieldSelector();
    } else if (_selectedChartType == 'Histogram') {
      return _buildHistogramControls();
    } else if (_selectedChartType == 'Box Plot') {
      return _buildBoxPlotControls();
    } else if (_selectedChartType == 'Automatic') {
      return _buildStandardAxisSelectors();
    } else {
      return _buildStandardAxisSelectors();
    }
  }
  
  Widget _buildStandardAxisSelectors() {
    final columns = widget.results.first.keys.toList();
    
    return Row(
      children: [
        Expanded(
          child: _buildDropdown(
            'X Axis',
            _selectedXAxis,
            columns,
            (value) => setState(() {
              _selectedXAxis = value!;
              _calculateNumericRange();
            }),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildDropdown(
            'Y Axis',
            _selectedYAxis,
            columns,
            (value) => setState(() {
              _selectedYAxis = value!;
              _calculateNumericRange();
              _calculateStatistics();
            }),
          ),
        ),
      ],
    );
  }
  
  Widget _buildRadarFieldSelector() {
    final columns = widget.results.first.keys.toList();
    final numericColumns = columns.where((col) => 
      _isNumeric(_getFirstNonEmptyValue(col))).toList();
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Select Fields for Radar Chart (3-7 recommended):',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: numericColumns.map((col) {
            final selected = _selectedFields.contains(col);
            return FilterChip(
              label: Text(col),
              selected: selected,
              checkmarkColor: Colors.black,
              selectedColor: Colors.blue,
              backgroundColor: Colors.grey[800],
              labelStyle: TextStyle(
                color: selected ? Colors.white : Colors.white70,
              ),
              onSelected: (value) {
                setState(() {
                  if (value) {
                    _selectedFields.add(col);
                  } else {
                    _selectedFields.remove(col);
                  }
                });
              },
            );
          }).toList(),
        ),
      ],
    );
  }
  
  Widget _buildHistogramControls() {
    final columns = widget.results.first.keys.toList();
    final numericColumns = columns.where((col) => 
      _isNumeric(_getFirstNonEmptyValue(col))).toList();
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _buildDropdown(
                'Value Field',
                _selectedYAxis,
                numericColumns,
                (value) => setState(() {
                  _selectedYAxis = value!;
                  _calculateStatistics();
                }),
              ),
            ),
            const SizedBox(width: 12),
            const Text('Bins:', style: TextStyle(color: Colors.white70)),
            const SizedBox(width: 8),
            SizedBox(
              width: 60,
              child: TextField(
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: Color(0xFF424242),
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  border: OutlineInputBorder(),
                ),
                controller: TextEditingController(text: _chartOptions['bins'].toString()),
                onChanged: (value) {
                  if (value.isNotEmpty) {
                    setState(() {
                      _chartOptions['bins'] = int.tryParse(value) ?? 10;
                    });
                  }
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
  
  Widget _buildBoxPlotControls() {
    final columns = widget.results.first.keys.toList();
    final nonNumericColumns = columns.where((col) => 
      !_isNumeric(_getFirstNonEmptyValue(col))).toList();
    final numericColumns = columns.where((col) => 
      _isNumeric(_getFirstNonEmptyValue(col))).toList();
    
    return Row(
      children: [
        Expanded(
          child: _buildDropdown(
            'Category Field',
            _selectedXAxis,
            nonNumericColumns,
            (value) => setState(() {
              _selectedXAxis = value!;
            }),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildDropdown(
            'Value Field',
            _selectedYAxis,
            numericColumns,
            (value) => setState(() {
              _selectedYAxis = value!;
              _calculateStatistics();
            }),
          ),
        ),
      ],
    );
  }
  
  Widget _buildStatsSummary() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey[850],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[700]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Statistics Summary',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.info_outline, size: 16, color: Colors.white70),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Show detailed statistics',
                onPressed: () => _showStatisticsDialog(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _statItem('Count', _statistics['count']?.toString() ?? '0'),
              _statItem('Min', _formatNumber(_statistics['min'])),
              _statItem('Max', _formatNumber(_statistics['max'])),
              _statItem('Mean', _formatNumber(_statistics['mean'])),
              _statItem('Median', _formatNumber(_statistics['median'])),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _statItem(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.blue[200],
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
  
  String _formatNumber(dynamic number) {
    if (number == null) return 'N/A';
    if (number is double) {
      return number.toStringAsFixed(_chartOptions['decimalPlaces'] ?? 1);
    }
    return number.toString();
  }

  Widget _buildChart() {
    try {
      // For special chart types with different parameters
      if (_selectedChartType == 'Radar' && _selectedFields.isNotEmpty) {
        return RadarChart(
          _graphicsService.generateRadarChart(
            _filteredResults,
            _selectedFields,
            titleField: _selectedXAxis,
            customOptions: _chartOptions,
          ),
        );
      } else if (_selectedChartType == 'Histogram') {
        return BarChart(
          _graphicsService.generateHistogram(
            _filteredResults,
            _selectedYAxis,
            bins: _chartOptions['bins'],
            customOptions: _chartOptions,
          ),
        );
      } else if (_selectedChartType == 'Box Plot') {
        return LineChart(
          _graphicsService.generateBoxPlotChart(
            _filteredResults,
            _selectedXAxis,
            _selectedYAxis,
            customOptions: _chartOptions,
          ),
        );
      }
      
      // Handle standard chart types
      switch (_selectedChartType) {
        case 'Bar':
          return BarChart(
            _graphicsService.generateBarChart(
              _filteredResults,
              _selectedXAxis,
              _selectedYAxis,
              customOptions: _chartOptions,
            ),
          );
        case 'Line':
          return LineChart(
            _graphicsService.generateLineChart(
              _filteredResults,
              _selectedXAxis,
              _selectedYAxis,
              customOptions: _chartOptions,
            ),
          );
        case 'Pie':
          return PieChart(
            _graphicsService.generatePieChart(
              _filteredResults,
              _selectedXAxis,
              _selectedYAxis,
              customOptions: _chartOptions,
            ),
          );
        case 'Scatter':
          return ScatterChart(
            _graphicsService.generateScatterChart(
              _filteredResults,
              _selectedXAxis,
              _selectedYAxis,
              customOptions: _chartOptions,
            ),
          );
        case 'Automatic':
        default:
          return _graphicsService.suggestChartType(
            _filteredResults,
            _selectedXAxis,
            _selectedYAxis,
            customOptions: _chartOptions,
          );
      }
    } catch (e) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.orange, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Could not generate chart',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              e.toString(),
              style: const TextStyle(color: Colors.orange),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Try Different Options'),
              onPressed: () => _showChartOptionsDialog(),
            ),
          ],
        ),
      );
    }
  }
  
  Widget _buildAnalysisTab() {
    return Container(
      color: Colors.grey[900],
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16.0),
            color: Colors.grey[850],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.analytics, color: Colors.blue),
                    SizedBox(width: 8),
                    Text(
                      'AI-Generated Analysis',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Summary based on ${widget.results.length} rows of data',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                // Aggiungiamo azioni per l'analisi
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.copy, color: Colors.white70),
                      tooltip: 'Copy Analysis',
                      onPressed: () => _copyToClipboard(widget.analysis),
                    ),
                    IconButton(
                      icon: const Icon(Icons.download, color: Colors.white70),
                      tooltip: 'Export Analysis',
                      onPressed: () => _exportAnalysis(),
                    ),
                    IconButton(
                      icon: const Icon(Icons.share, color: Colors.white70),
                      tooltip: 'Share Analysis',
                      onPressed: () => _shareAnalysis(),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Card(
                color: Colors.grey[850],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 8,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _formatAnalysisText(widget.analysis),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _formatAnalysisText(String analysis) {
    final lines = analysis.split('\n');
    List<Widget> widgets = [];
    
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      
      if (line.startsWith('# ') || line.startsWith('## ')) {
        // Heading
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Text(
              line.replaceFirst(RegExp(r'^#+\s+'), ''),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: line.startsWith('# ') ? 20 : 18,
                color: Colors.blue[200],
              ),
            ),
          ),
        );
      } else if (line.startsWith('**') && line.endsWith('**')) {
        // Bold text
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Text(
              line.replaceAll('**', ''),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Colors.white,
              ),
            ),
          ),
        );
      } else if (line.startsWith('* ') || line.startsWith('- ')) {
        // Bullet point
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 8.0, top: 4.0, bottom: 4.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '• ',
                  style: TextStyle(color: Colors.orange, fontSize: 16),
                ),
                Expanded(
                  child: Text(
                    line.substring(2),
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        );
      } else if (line.contains(': ')) {
        // Key-value pair
        final parts = line.split(': ');
        if (parts.length == 2) {
          widgets.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${parts[0]}: ',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      parts[1],
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          );
        } else {
          widgets.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4.0),
              child: Text(
                line,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          );
        }
      } else if (line.trim().isEmpty && i > 0 && i < lines.length - 1) {
        // Paragraph break
        widgets.add(const SizedBox(height: 8));
      } else {
        // Regular paragraph
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4.0),
            child: Text(
              line,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        );
      }
    }
    
    return widgets;
  }
  
  // Helper methods for building UI components
  
  Widget _buildDropdown(
    String label,
    String value,
    List<String> items,
    Function(String?) onChanged,
  ) {
    return DropdownButtonFormField<String>(
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70, fontSize: 12),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        filled: true,
        fillColor: Colors.grey[800],
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
      dropdownColor: Colors.grey[800],
      value: value,
      items: items.map((item) {
        return DropdownMenuItem<String>(
          value: item,
          child: Text(
            item,
            style: const TextStyle(color: Colors.white),
            overflow: TextOverflow.ellipsis,
          ),
        );
      }).toList(),
      onChanged: (String? newValue) {
        if (newValue != null) {
          onChanged(newValue);
        }
      },
    );
  }
  
  // Dialog methods
  
  void _showFilterDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, StateSetter setState) {
            return AlertDialog(
              backgroundColor: Colors.grey[900],
              title: const Text(
                'Filter Data',
                style: TextStyle(color: Colors.white),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_minValue != null && _maxValue != null) ...[
                    Text(
                      'Filter range for $_selectedYAxis:',
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _numericFilter!.start.toStringAsFixed(1),
                          style: const TextStyle(color: Colors.white70),
                        ),
                        Text(
                          _numericFilter!.end.toStringAsFixed(1),
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                    RangeSlider(
                      values: _numericFilter!,
                      min: _minValue!,
                      max: _maxValue!,
                      divisions: 100,
                      labels: RangeLabels(
                        _numericFilter!.start.toStringAsFixed(1),
                        _numericFilter!.end.toStringAsFixed(1),
                      ),
                      onChanged: (RangeValues values) {
                        setState(() {
                          _numericFilter = values;
                        });
                      },
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  child: const Text('Cancel'),
                  onPressed: () => Navigator.pop(context),
                ),
                ElevatedButton(
                  child: const Text('Apply'),
                  onPressed: () {
                    Navigator.pop(context);
                    _applyFilters();
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }
  
  void _showChartOptionsDialog() {
    final map = Map<String, dynamic>.from(_chartOptions);
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, StateSetter setState) {
            return AlertDialog(
              backgroundColor: Colors.grey[900],
              title: const Text(
                'Chart Options',
                style: TextStyle(color: Colors.white),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildOptionSwitch(
                      'Show Grid',
                      map['showGrid'],
                      (value) => setState(() => map['showGrid'] = value),
                    ),
                    _buildOptionSwitch(
                      'Show Title',
                      map['showTitle'],
                      (value) => setState(() => map['showTitle'] = value),
                    ),
                    _buildOptionSwitch(
                      'Rotate Labels',
                      map['rotateLabels'],
                      (value) => setState(() => map['rotateLabels'] = value),
                    ),
                    _buildOptionSwitch(
                      'Show Values',
                      map['showValues'],
                      (value) => setState(() => map['showValues'] = value),
                    ),
                    
                    const Divider(color: Colors.grey),
                    
                    // Options specific to line charts
                    if (_selectedChartType == 'Line') ...[
                      _buildOptionSwitch(
                        'Curved Lines',
                        map['curvedLines'],
                        (value) => setState(() => map['curvedLines'] = value),
                      ),
                      _buildOptionSwitch(
                        'Show Dots',
                        map['showDots'],
                        (value) => setState(() => map['showDots'] = value),
                      ),
                      _buildOptionSwitch(
                        'Show Area',
                        map['showArea'],
                        (value) => setState(() => map['showArea'] = value),
                      ),
                      _buildOptionSwitch(
                        'Show Trendline',
                        map['showTrendline'],
                        (value) => setState(() => map['showTrendline'] = value),
                      ),
                      _buildOptionSwitch(
                        'Show Average Line',
                        map['showAvgLine'],
                        (value) => setState(() => map['showAvgLine'] = value),
                      ),
                      _buildOptionSlider(
                        'Line Width',
                        map['lineWidth'],
                        1.0,
                        5.0,
                        (value) => setState(() => map['lineWidth'] = value),
                      ),
                      if (map['showArea'])
                        _buildOptionSlider(
                          'Area Opacity',
                          map['areaOpacity'],
                          0.1,
                          0.5,
                          (value) => setState(() => map['areaOpacity'] = value),
                        ),
                    ],
                    
                    // Options specific to bar charts
                    if (_selectedChartType == 'Bar') ...[
                      _buildOptionSlider(
                        'Bar Width',
                        map['barWidth'],
                        8.0,
                        30.0,
                        (value) => setState(() => map['barWidth'] = value),
                      ),
                    ],
                    
                    // Options specific to pie charts
                    if (_selectedChartType == 'Pie') ...[
                      _buildOptionSwitch(
                        'Show Percent Values',
                        map['showPercentValues'],
                        (value) => setState(() => map['showPercentValues'] = value),
                      ),
                      _buildOptionSlider(
                        'Center Space Radius',
                        map['centerSpaceRadius'],
                        0.0,
                        80.0,
                        (value) => setState(() => map['centerSpaceRadius'] = value),
                      ),
                    ],
                    
                    // Common options
                    const Divider(color: Colors.grey),
                    
                    _buildOptionSlider(
                      'Decimal Places',
                      map['decimalPlaces'].toDouble(),
                      0.0,
                      3.0,
                      (value) => setState(() => map['decimalPlaces'] = value.round()),
                      divisions: 3,
                    ),
                    
                    _buildOptionSlider(
                      'Left Axis Width',
                      map['leftAxisWidth'],
                      30.0,
                      100.0,
                      (value) => setState(() => map['leftAxisWidth'] = value),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  child: const Text('Cancel'),
                  onPressed: () => Navigator.pop(context),
                ),
                ElevatedButton(
                  child: const Text('Apply'),
                  onPressed: () {
                    _chartOptions.clear();
                    _chartOptions.addAll(map);
                    Navigator.pop(context);
                    setState(() {});
                  },
                ),
              ],
            );
          }
        );
      },
    );
  }
  
  Widget _buildOptionSwitch(String label, bool value, Function(bool) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white)),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: Colors.blue,
          ),
        ],
      ),
    );
  }
  
  Widget _buildOptionSlider(
    String label,
    double value,
    double min,
    double max,
    Function(double) onChanged, {
    int? divisions,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(color: Colors.white)),
              Text(
                value.toStringAsFixed(1),
                style: const TextStyle(color: Colors.blue),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions ?? ((max - min).round() * 2),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
  
  void _showStatisticsDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text(
            'Statistical Analysis',
            style: TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Statistics for $_selectedYAxis',
                    style: TextStyle(
                      color: Colors.blue[200],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildStatRow('Count', _statistics['count']?.toString() ?? '0'),
                  _buildStatRow('Min', _formatNumber(_statistics['min'])),
                  _buildStatRow('Max', _formatNumber(_statistics['max'])),
                  _buildStatRow('Mean', _formatNumber(_statistics['mean'])),
                  _buildStatRow('Median', _formatNumber(_statistics['median'])),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              child: const Text('Close'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }
  
  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ],
      ),
    );
  }
  
  // Metodi per la condivisione e l'esportazione dei risultati
  
  void _showShareOptionsDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text(
            'Share Results',
            style: TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: const Icon(Icons.share, color: Colors.white),
                title: const Text('Share via App', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _shareResults();
                },
              ),
              ListTile(
                leading: const Icon(Icons.file_download, color: Colors.white),
                title: const Text('Export as File', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _showExportOptionsDialog();
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text('Close', style: TextStyle(color: Colors.white)),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }
  
  void _shareResults() {
    // Condividi i risultati filtrati come testo
    final filteredData = _filteredResults
        .map((row) => row.values.map((v) => v.toString()).join(','))
        .join('\n');
    
    Share.share(
      'Query: ${widget.question}\n\nResults:\n$filteredData',
      subject: 'Query Results',
    );
  }
  
  void _showExportOptionsDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text(
            'Export Options',
            style: TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: const Icon(Icons.image, color: Colors.white),
                title: const Text('Chart as Image', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _exportChartAsImage();
                },
              ),
              ListTile(
                leading: const Icon(Icons.table_chart, color: Colors.white),
                title: const Text('Data as CSV', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _exportDataAsCsv();
                },
              ),
              ListTile(
                // Sostituisci Icons.json con un'icona esistente
                leading: const Icon(Icons.code, color: Colors.white),
                title: const Text('Data as JSON', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _exportDataAsJson();
                },
              ),
              ListTile(
                leading: const Icon(Icons.analytics, color: Colors.white),
                title: const Text('Analysis as Text', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _exportAnalysis();
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text('Close', style: TextStyle(color: Colors.white)),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  // Esportazione del grafico come immagine con permessi
  Future<void> _exportChartAsImage() async {
    try {
      final imageData = await _captureChartAsImage();
      if (imageData == null) {
        _showSnackBar('Impossibile catturare l\'immagine');
        return;
      }
      
      final fileName = 'easy_query_chart_${DateTime.now().millisecondsSinceEpoch}.png';
      
      // Per web, usa downloadFile per il download
      _downloadData(imageData, fileName, 'image/png');
      _showSnackBar('Immagine salvata come $fileName');
    } catch (e) {
      _showSnackBar('Errore durante l\'esportazione: $e');
    }
  }

  // Versione corretta per web di _exportDataAsCsv
  Future<void> _exportDataAsCsv() async {
    try {
      final rows = _filteredResults;
      if (rows.isEmpty) {
        _showSnackBar('Nessun dato da esportare');
        return;
      }
      
      final fileName = 'easy_query_data_${DateTime.now().millisecondsSinceEpoch}.csv';
      final header = rows.first.keys.join(',');
      final dataRows = rows.map((row) => 
        row.values.map((v) => '"${v.toString().replaceAll('"', '""')}"').join(',')
      ).join('\n');
      
      final csvData = '$header\n$dataRows';
      
      // Per web, usa downloadFile per il download
      _downloadData(utf8.encode(csvData), fileName, 'text/csv');
      _showSnackBar('Dati salvati come $fileName');
    } catch (e) {
      _showSnackBar('Errore durante l\'esportazione: $e');
    }
  }

  // Versione corretta per web di _exportDataAsJson
  Future<void> _exportDataAsJson() async {
    try {
      if (_filteredResults.isEmpty) {
        _showSnackBar('Nessun dato da esportare');
        return;
      }
      
      final fileName = 'easy_query_data_${DateTime.now().millisecondsSinceEpoch}.json';
      final jsonData = jsonEncode(_filteredResults);
      
      // Per web, usa downloadFile per il download
      _downloadData(utf8.encode(jsonData), fileName, 'application/json');
      _showSnackBar('Dati JSON salvati come $fileName');
    } catch (e) {
      _showSnackBar('Errore durante l\'esportazione: $e');
    }
  }

  // Versione corretta per web di _exportAnalysis
  Future<void> _exportAnalysis() async {
    try {
      final fileName = 'easy_query_analysis_${DateTime.now().millisecondsSinceEpoch}.txt';
      final analysisText = 'Query: ${widget.question}\n\n'
          'SQL: ${widget.sqlQuery}\n\n'
          'Analysis:\n${widget.analysis}';
      
      // Per web, usa downloadFile per il download
      _downloadData(utf8.encode(analysisText), fileName, 'text/plain');
      _showSnackBar('Analisi salvata come $fileName');
    } catch (e) {
      _showSnackBar('Errore durante l\'esportazione: $e');
    }
  }

  // Nuovo metodo unificato per download (sostituisce _downloadStringForWeb e _downloadBytesForWeb)
  void _downloadData(List<int> bytes, String fileName, String mimeType) {
    // Usa universal_html per maggiore compatibilità
    final blob = webhtml.Blob([bytes], mimeType);
    final url = webhtml.Url.createObjectUrlFromBlob(blob);
    
    // Crea un elemento <a> invisibile per scaricare il file
    final anchor = webhtml.AnchorElement(href: url)
      ..setAttribute('download', fileName)
      ..style.display = 'none';
    
    // Aggiungi alla pagina, clicca e rimuovi
    webhtml.document.body?.children.add(anchor);
    anchor.click();
    
    // Pulizia
    webhtml.document.body?.children.remove(anchor);
    webhtml.Url.revokeObjectUrl(url);
  }

  // Implementazione di _showHelpDialog
  void _showHelpDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text(
            'Visualization Help',
            style: TextStyle(color: Colors.white),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _helpSection(
                  'Chart Types',
                  [
                    'Automatic: Our AI selects the best visualization for your data',
                    'Bar: Compare values across categories',
                    'Line: Show trends over time or ordered categories',
                    'Pie: Display composition or proportions of a whole',
                    'Scatter: Examine correlation between two variables',
                    'Radar: Compare multiple variables for multiple items',
                    'Box Plot: View statistical distribution by category',
                    'Histogram: See the distribution of a single variable',
                  ],
                ),
                const SizedBox(height: 16),
                _helpSection(
                  'Interacting with Charts',
                  [
                    'Pinch or use mousewheel to zoom in/out',
                    'Drag to pan across the chart',
                    'Double-tap to reset the view',
                    'Tap data points to see detailed values',
                    'Use the filter panel to focus on specific ranges',
                  ],
                ),
                const SizedBox(height: 16),
                _helpSection(
                  'Tips',
                  [
                    'Use line charts for time series data',
                    'Bar charts work best for category comparisons',
                    'Scatter plots help identify correlations',
                    'Pie charts are ideal for showing proportions',
                    'Try the Automatic mode to get AI recommendations',
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              child: const Text('Close'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  // Implementazione di _helpSection (usato da _showHelpDialog)
  Widget _helpSection(String title, List<String> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: Colors.blue[200],
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 8),
        ...items.map((item) => Padding(
          padding: const EdgeInsets.only(left: 8.0, bottom: 4.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('• ', style: TextStyle(color: Colors.white)),
              Expanded(
                child: Text(
                  item,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        )).toList(),
      ],
    );
  }

  // Implementazione di _copyToClipboard
  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Copied to clipboard'),
        duration: const Duration(seconds: 2),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // Implementazione di _showCellDetails
  void _showCellDetails(String column, String value) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Text(
            column,
            style: const TextStyle(color: Colors.white),
          ),
          content: SelectableText(
            value,
            style: const TextStyle(color: Colors.white),
          ),
          actions: [
            TextButton(
              child: const Text('Close'),
              onPressed: () => Navigator.pop(context),
            ),
            TextButton(
              child: const Text('Copy'),
              onPressed: () {
                _copyToClipboard(value);
                Navigator.pop(context);
              },
            ),
          ],
        );
      },
    );
  }

  // Implementazione di _updateFieldSelectionForChartType
  void _updateFieldSelectionForChartType() {
    if (_selectedChartType == 'Radar') {
      // Pre-select numeric fields for radar chart
      final columns = widget.results.first.keys.toList();
      _selectedFields = columns
          .where((col) => _isNumeric(_getFirstNonEmptyValue(col)))
          .take(5)
          .toList();
    } else if (_selectedChartType == 'Histogram') {
      // Find a numeric column for histogram
      final columns = widget.results.first.keys.toList();
      _selectedYAxis = columns.firstWhere(
        (col) => _isNumeric(_getFirstNonEmptyValue(col)),
        orElse: () => _selectedYAxis,
      );
    } else if (_selectedChartType == 'Scatter') {
      // Find two numeric columns for scatter plot
      final columns = widget.results.first.keys.toList();
      final numericColumns = columns.where(
        (col) => _isNumeric(_getFirstNonEmptyValue(col))
      ).toList();
      
      if (numericColumns.length >= 2) {
        _selectedXAxis = numericColumns[0];
        _selectedYAxis = numericColumns[1];
      }
    }
  }

  // Implementazione di _calculateChartWidth
  double _calculateChartWidth() {
    // Aumenta la larghezza minima del grafico per tipi che richiedono più spazio
    switch (_selectedChartType) {
      case 'Bar':
        // Più categorie = più larghezza
        return math.max(500.0, _filteredResults.length * 40.0);
      case 'Line':
        // Punti più numerosi richiedono più spazio
        return math.max(500.0, _filteredResults.length * 15.0);
      case 'Pie':
        // Grafico a torta necessita di spazio standard
        return 500.0;
      case 'Scatter':
        return 500.0;
      case 'Radar':
        return 500.0;
      case 'Box Plot':
        // Box plot con molte categorie richiedono più spazio
        return math.max(500.0, _filteredResults.length * 80.0);
      case 'Histogram':
        // Dipende dal numero di bin
        return math.max(500.0, (_chartOptions['bins'] as int) * 30.0);
      default: // Automatic
        if (_filteredResults.length > 8) {
          return math.max(500.0, _filteredResults.length * 35.0);
        }
        return 500.0;
    }
  }

  // Implementazione di _captureChartAsImage
  Future<Uint8List?> _captureChartAsImage() async {
    try {
      final boundary = _chartKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      
      if (byteData != null) {
        return byteData.buffer.asUint8List();
      }
      return null;
    } catch (e) {
      _showSnackBar('Failed to capture chart: $e');
      return null;
    }
  }

  // Implementazione di _shareAnalysis
  Future<void> _shareAnalysis() async {
    final analysisText = 'Query: ${widget.question}\n\n'
        'SQL: ${widget.sqlQuery}\n\n'
        'Analysis:\n${widget.analysis}';
    
    try {
      await Share.share(
        analysisText,
        subject: 'Data Analysis Results',
      );
    } catch (e) {
      _showSnackBar('Error sharing analysis: $e');
    }
  }

  // Helper per mostrare uno snackbar con un messaggio
  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.grey[800],
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  // Implementazione di _showOpenFileDialog per le piattaforme web
  void _showOpenFileDialog(String filePath, String title) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Text(title, style: const TextStyle(color: Colors.white)),
          content: Text('File generato con successo!', style: const TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              child: const Text('Chiudi'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  // Metodo per mostrare il popup di salvataggio in Gold Zone
  void _showSaveToGoldDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Row(
            children: [
              const Icon(Icons.save, color: Colors.amber),
              const SizedBox(width: 10),
              const Text(
                'Save to Gold Zone',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Would you like to save these results in GOLD format?',
                style: TextStyle(color: Colors.white),
              ),
              SizedBox(height: 10),
              Text(
                'This will make future queries for this data much faster.',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text('No'),
              onPressed: () => Navigator.pop(context),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
              ),
              child: const Text('Yes'),
              onPressed: () {
                Navigator.pop(context);
                _showTableNameInputDialog();
              },
            ),
          ],
        );
      },
    );
  }

  // Metodo per mostrare il popup di inserimento nome tabella
  void _showTableNameInputDialog() {
    final TextEditingController tableNameController = TextEditingController();
    bool isCheckingName = false;
    String errorMessage = '';
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, StateSetter setState) {
            return AlertDialog(
              backgroundColor: Colors.grey[900],
              title: const Text(
                'Name your Gold Table',
                style: TextStyle(color: Colors.white),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Choose a name for your Gold table (lowercase letters and underscores only)',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: tableNameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Table Name',
                      hintText: 'e.g. monthly_sales',
                      labelStyle: const TextStyle(color: Colors.amber),
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                      filled: true,
                      fillColor: Colors.grey[800],
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Colors.amber),
                      ),
                      errorText: errorMessage.isNotEmpty ? errorMessage : null,
                      errorStyle: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  child: const Text('Cancel'),
                  onPressed: () => Navigator.pop(context),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    foregroundColor: Colors.black,
                  ),
                  child: isCheckingName
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            color: Colors.black,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text('Confirm'),
                  onPressed: isCheckingName
                      ? null
                      : () async {
                          final tableName = tableNameController.text.trim();
                          
                          // Verifica che il nome della tabella rispetti il formato richiesto
                          final RegExp validNameRegex = RegExp(r'^[a-z][a-z0-9_]*$');
                          if (!validNameRegex.hasMatch(tableName)) {
                            setState(() {
                              errorMessage = 'Invalid name format. Use only lowercase letters, numbers and underscores. Must start with a letter.';
                            });
                            return;
                          }
                          
                          setState(() {
                            isCheckingName = true;
                            errorMessage = '';
                          });
                          
                          try {
                            // Controlla se il nome della tabella esiste già nel dataset gold_layer_dataset
                            final tableExists = await _checkIfTableExists(tableName);
                            
                            if (tableExists) {
                              setState(() {
                                errorMessage = 'A table with this name already exists in Gold Zone';
                                isCheckingName = false;
                              });
                            } else {
                              // Chiudi il popup e mostra un indicatore di caricamento
                              Navigator.pop(context);
                              _saveToGoldZone(tableName);
                            }
                          } catch (e) {
                            setState(() {
                              errorMessage = 'Error checking table name: ${e.toString()}';
                              isCheckingName = false;
                            });
                          }
                        },
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Controlla se una tabella con questo nome esiste già nel dataset gold_layer_dataset
  Future<bool> _checkIfTableExists(String tableName) async {
    try {
      // Nota: in un'implementazione reale, dovresti chiamare un servizio BigQuery
      // Per semplicità, questa è una simulazione
      
      // Simula una chiamata a BigQuery con un ritardo
      await Future.delayed(const Duration(seconds: 1));
      
      // In un'implementazione reale, dovresti usare qualcosa come:
      // final exists = await bigQueryService.tableExists('gold_layer_dataset', tableName);
      
      // Per ora simuliamo che il nome 'test_table' esista già
      return tableName == 'test_table';
    } catch (e) {
      print('Error checking if table exists: $e');
      rethrow;
    }
  }

  // Salva i risultati in Gold Zone
  void _saveToGoldZone(String tableName) async {
    // Mostra un dialog di caricamento
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.amber),
              const SizedBox(height: 20),
              Text(
                'Saving query results to Gold Zone as "$tableName"...',
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
        );
      },
    );

    try {
    
      //qui invoco la funzione per salvare i risultati in Gold Zone
      bool success = await widget.bigQueryService.saveResultsToGoldZone(
        tableName,
        widget.results,
        widget.sqlQuery,
      );

      if (!success) {
        throw Exception('Failed to save results to Gold Zone');
      }
      
      // Chiudi il dialog di caricamento
      Navigator.pop(context);
      
      // Mostra un dialog di successo
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            backgroundColor: Colors.grey[900],
            title: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green),
                const SizedBox(width: 10),
                const Text('Success', style: TextStyle(color: Colors.white)),
              ],
            ),
            content: Text(
              'Your query results have been successfully saved to Gold Zone as "$tableName".',
              style: const TextStyle(color: Colors.white),
            ),
            actions: [
              TextButton(
                child: const Text('OK'),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          );
        },
      );
    } catch (e) {
      // Chiudi il dialog di caricamento
      Navigator.pop(context);
      
      // Mostra un dialog di errore
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            backgroundColor: Colors.grey[900],
            title: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.red),
                const SizedBox(width: 10),
                const Text('Error', style: TextStyle(color: Colors.white)),
              ],
            ),
            content: Text(
              'Failed to save to Gold Zone: ${e.toString()}',
              style: const TextStyle(color: Colors.white),
            ),
            actions: [
              TextButton(
                child: const Text('OK'),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          );
        },
      );
    }
  }
}