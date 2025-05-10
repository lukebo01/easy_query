import 'package:flutter/material.dart';
import 'package:easy_query/services/graphics_service.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

class ResultPage extends StatefulWidget {
  final String question;
  final String sqlQuery;
  final List<Map<String, dynamic>> results;
  final String analysis;

  const ResultPage({
    super.key,
    required this.question,
    required this.sqlQuery,
    required this.results,
    required this.analysis,
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
  };
  
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
        // Top settings panel
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
        
        // Chart display area - MIGLIORATO PER SCROLLING ORIZZONTALE
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
                padding: const EdgeInsets.all(16.0),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Calcola la larghezza minima necessaria per il grafico
                    final double minChartWidth = _calculateChartWidth();
                    final double chartWidth = math.max(minChartWidth, constraints.maxWidth);
                    
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: chartWidth,
                        height: constraints.maxHeight,
                        child: RepaintBoundary(
                          key: _chartKey,
                          child: _buildChart(),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
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
                  _buildStatRow('Minimum', _formatNumber(_statistics['min'])),
                  _buildStatRow('Maximum', _formatNumber(_statistics['max'])),
                  _buildStatRow('Range', _formatNumber(_statistics['range'])),
                  _buildStatRow('Mean', _formatNumber(_statistics['mean'])),
                  _buildStatRow('Median', _formatNumber(_statistics['median'])),
                  _buildStatRow('Standard Deviation', _formatNumber(_statistics['stdDev'])),
                  _buildStatRow('Lower Quartile (Q1)', _formatNumber(_statistics['lowerQuartile'])),
                  _buildStatRow('Upper Quartile (Q3)', _formatNumber(_statistics['upperQuartile'])),
                  
                  const SizedBox(height: 24),
                  
                  // Add a mini histogram or box plot here if desired
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
            style: const TextStyle(color: Colors.white),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
  
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
                    'Hover or tap data points to see detailed values',
                    'Use the filter panel to focus on specific ranges',
                    'Try different chart types for new insights',
                    'Adjust chart options for better visualization',
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
  
  // Helper methods
  
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

  // Cattura il grafico come immagine
  Future<Uint8List?> _captureChartAsImage() async {
    try {
      RenderRepaintBoundary boundary = _chartKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      
      if (byteData != null) {
        return byteData.buffer.asUint8List();
      }
      return null;
    } catch (e) {
      _showSnackBar('Failed to capture chart: $e');
      return null;
    }
  }

  // Esportazione del grafico come immagine
  Future<void> _exportChartAsImage() async {
    final imageData = await _captureChartAsImage();
    if (imageData == null) {
      _showSnackBar('Failed to capture chart image');
      return;
    }
    
    try {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/chart_${DateTime.now().millisecondsSinceEpoch}.png');
      await tempFile.writeAsBytes(imageData);
      
      _showSnackBar('Chart exported to: ${tempFile.path}');
      
      // Su un dispositivo reale, potremmo voler aprire il file con un intent
      // o salvarlo nella galleria
    } catch (e) {
      _showSnackBar('Error saving image: $e');
    }
  }

  // Esportazione dei dati come CSV
  Future<void> _exportDataAsCsv() async {
    try {
      final rows = _filteredResults;
      if (rows.isEmpty) {
        _showSnackBar('No data to export');
        return;
      }
      
      final header = rows.first.keys.join(',');
      final dataRows = rows.map((row) => 
        row.values.map((v) => '"${v.toString().replaceAll('"', '""')}"').join(',')
      ).join('\n');
      
      final csvData = '$header\n$dataRows';
      
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/data_${DateTime.now().millisecondsSinceEpoch}.csv');
      await tempFile.writeAsString(csvData);
      
      _showSnackBar('Data exported to: ${tempFile.path}');
    } catch (e) {
      _showSnackBar('Error exporting data: $e');
    }
  }

  // Nuovo metodo per esportare i dati in formato JSON
  Future<void> _exportDataAsJson() async {
    try {
      if (_filteredResults.isEmpty) {
        _showSnackBar('No data to export');
        return;
      }
      
      // Converti i dati in formato JSON
      final jsonString = '[';
      final rows = _filteredResults.map((row) {
        final entries = row.entries.map((e) => '"${e.key}": "${e.value.toString().replaceAll('"', '\\"')}"').join(', ');
        return '{$entries}';
      }).join(',\n');
      final jsonData = '$jsonString\n$rows\n]';
      
      // Salva il file JSON
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/data_${DateTime.now().millisecondsSinceEpoch}.json');
      await tempFile.writeAsString(jsonData);
      
      _showSnackBar('Data exported as JSON to: ${tempFile.path}');
    } catch (e) {
      _showSnackBar('Error exporting data: $e');
    }
  }

  // Nuovo metodo per esportare un report completo
  Future<void> _exportCompleteReport() async {
    try {
      // Prepara il testo del report
      final report = StringBuffer();
      report.writeln('# DATA ANALYSIS REPORT');
      report.writeln('## Question');
      report.writeln(widget.question);
      report.writeln('\n## SQL Query');
      report.writeln(widget.sqlQuery);
      report.writeln('\n## Analysis');
      report.writeln(widget.analysis);
      report.writeln('\n## Data Summary');
      report.writeln('Total rows: ${_filteredResults.length}');
      
      if (_statistics.isNotEmpty) {
        report.writeln('\n## Statistics');
        _statistics.forEach((key, value) {
          report.writeln('$key: ${_formatNumber(value)}');
        });
      }
      
      // Salva il report come file di testo
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/report_${DateTime.now().millisecondsSinceEpoch}.txt');
      await tempFile.writeAsString(report.toString());
      
      // Salva anche l'immagine del grafico se siamo nella tab del grafico
      String? imageFilePath;
      if (_tabController.index == 1) {
        final imageData = await _captureChartAsImage();
        if (imageData != null) {
          final imageFile = File('${tempDir.path}/chart_${DateTime.now().millisecondsSinceEpoch}.png');
          await imageFile.writeAsBytes(imageData);
          imageFilePath = imageFile.path;
        }
      }
      
      _showSnackBar('Report exported to: ${tempFile.path}');
      
      // Opzione per condividere il report completo
      if (imageFilePath != null) {
        await Share.shareXFiles(
          [XFile(tempFile.path), XFile(imageFilePath)],
          text: 'Data Analysis Report',
        );
      } else {
        await Share.shareXFiles(
          [XFile(tempFile.path)],
          text: 'Data Analysis Report',
        );
      }
    } catch (e) {
      _showSnackBar('Error creating complete report: $e');
    }
  }

  // Funzione per condividere il grafico
  Future<void> _shareChart() async {
    final imageData = await _captureChartAsImage();
    if (imageData == null) {
      _showSnackBar('Failed to capture chart image');
      return;
    }
    
    try {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/chart_${DateTime.now().millisecondsSinceEpoch}.png');
      await tempFile.writeAsBytes(imageData);
      
      // Condividi usando share_plus
      await Share.shareXFiles(
        [XFile(tempFile.path)],
        text: 'Chart for query: ${widget.question}',
        subject: 'Data Analysis Chart',
      );
    } catch (e) {
      _showSnackBar('Error sharing chart: $e');
    }
  }

  // Funzione per condividere l'analisi
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

  // Funzione per condividere i risultati dei dati
  Future<void> _shareDataResults() async {
    try {
      final rows = _filteredResults;
      if (rows.isEmpty) {
        _showSnackBar('No data to share');
        return;
      }
      
      final header = rows.first.keys.join(',');
      final dataRows = rows.map((row) => 
        row.values.map((v) => '"${v.toString().replaceAll('"', '""')}"').join(',')
      ).join('\n');
      
      final csvData = '$header\n$dataRows';
      
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/data_${DateTime.now().millisecondsSinceEpoch}.csv');
      await tempFile.writeAsString(csvData);
      
      // Condividi usando share_plus
      await Share.shareXFiles(
        [XFile(tempFile.path)],
        text: 'Data results for query: ${widget.question}',
        subject: 'Data Analysis Results',
      );
    } catch (e) {
      _showSnackBar('Error sharing data: $e');
    }
  }

  // Funzione per esportare l'analisi
  Future<void> _exportAnalysis() async {
    final analysisText = 'Query: ${widget.question}\n\n'
        'SQL: ${widget.sqlQuery}\n\n'
        'Analysis:\n${widget.analysis}';
        
    try {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/analysis_${DateTime.now().millisecondsSinceEpoch}.txt');
      await tempFile.writeAsString(analysisText);
      
      _showSnackBar('Analysis exported to: ${tempFile.path}');
    } catch (e) {
      _showSnackBar('Error exporting analysis: $e');
    }
  }

  // Funzioni helper
  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _showSnackBar('Copied to clipboard');
  }
  
  // Calcola la larghezza necessaria in base al tipo di grafico e ai dati
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

  // Aggiungiamo l'implementazione della funzione mancante
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
            children: [
              // Opzione per esportare il grafico (solo se nella tab corrispondente)
              if (_tabController.index == 1)
                ListTile(
                  leading: const Icon(Icons.image, color: Colors.blue),
                  title: const Text('Export Chart as Image', style: TextStyle(color: Colors.white)),
                  subtitle: const Text('Save as PNG file', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  onTap: () {
                    Navigator.pop(context);
                    _exportChartAsImage();
                  },
                ),
              
              // Opzioni per esportare i dati
              ListTile(
                leading: const Icon(Icons.table_chart, color: Colors.green),
                title: const Text('Export Data as CSV', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Compatible with Excel, Sheets', style: TextStyle(color: Colors.white70, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  _exportDataAsCsv();
                },
              ),
              
              ListTile(
                leading: const Icon(Icons.code, color: Colors.amber),
                title: const Text('Export Data as JSON', style: TextStyle(color: Colors.white)),
                subtitle: const Text('For developers and APIs', style: TextStyle(color: Colors.white70, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  _exportDataAsJson();
                },
              ),
              
              // Opzioni per esportare l'analisi
              ListTile(
                leading: const Icon(Icons.analytics, color: Colors.purple),
                title: const Text('Export Analysis', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Text file with insights', style: TextStyle(color: Colors.white70, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  _exportAnalysis();
                },
              ),
              
              // Opzione per esportare tutto
              ListTile(
                leading: const Icon(Icons.download_done, color: Colors.orange),
                title: const Text('Export Complete Report', style: TextStyle(color: Colors.white)),
                subtitle: const Text('All data, charts and analysis', style: TextStyle(color: Colors.white70, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  _exportCompleteReport();
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  void _showShareOptionsDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text(
            'Share Options',
            style: TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Opzione per condividere l'analisi
              ListTile(
                leading: const Icon(Icons.analytics, color: Colors.orange),
                title: const Text('Share Analysis', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Share AI insights and findings', style: TextStyle(color: Colors.white70, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  _shareAnalysis();
                },
              ),
              
              // Opzione per condividere i dati
              ListTile(
                leading: const Icon(Icons.data_object, color: Colors.green),
                title: const Text('Share Data Results', style: TextStyle(color: Colors.white)),
                subtitle: const Text('CSV format with query results', style: TextStyle(color: Colors.white70, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  _shareDataResults();
                },
              ),
              
              // Opzione per condividere il grafico (visibile solo nella tab del grafico)
              if (_tabController.index == 1)
                ListTile(
                  leading: const Icon(Icons.insert_chart, color: Colors.blue),
                  title: const Text('Share Current Chart', style: TextStyle(color: Colors.white)),
                  subtitle: const Text('Image of the visualization', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  onTap: () {
                    Navigator.pop(context);
                    _shareChart();
                  },
                ),
              
              // Opzione per condividere la query SQL
              ListTile(
                leading: const Icon(Icons.code, color: Colors.purple),
                title: const Text('Share SQL Query', style: TextStyle(color: Colors.white)),
                subtitle: const Text('The database query used', style: TextStyle(color: Colors.white70, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  Share.share(
                    widget.sqlQuery,
                    subject: 'SQL Query',
                  );
                },
              ),
              
              // Opzione per condividere la domanda originale
              ListTile(
                leading: const Icon(Icons.help_outline, color: Colors.amber),
                title: const Text('Share Question', style: TextStyle(color: Colors.white)),
                subtitle: const Text('The original data question', style: TextStyle(color: Colors.white70, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  Share.share(
                    widget.question,
                    subject: 'Data Question',
                  );
                },
              ),
              
              // Opzione per condividere il report completo
              ListTile(
                leading: const Icon(Icons.description, color: Colors.cyan),
                title: const Text('Share Complete Report', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Question, data, analysis and charts', style: TextStyle(color: Colors.white70, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  _exportCompleteReport();
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }
}
