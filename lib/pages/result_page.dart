import 'package:flutter/material.dart';
import 'package:easy_query/services/graphics_service.dart';
import 'package:fl_chart/fl_chart.dart';

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

  String _selectedXAxis = '';
  String _selectedYAxis = '';
  String _selectedChartType = 'Bar';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    // Auto-select first numeric and non-numeric columns for chart axes
    if (widget.results.isNotEmpty) {
      final columns = widget.results.first.keys.toList();

      // Try to find a non-numeric column for X axis
      _selectedXAxis = columns.firstWhere(
        (col) => !_isNumeric(widget.results.first[col].toString()),
        orElse: () => columns.first,
      );

      // Try to find a numeric column for Y axis
      _selectedYAxis = columns.firstWhere(
        (col) =>
            _isNumeric(widget.results.first[col].toString()) &&
            col != _selectedXAxis,
        orElse: () => columns.length > 1 ? columns[1] : columns.first,
      );
    }
  }

  bool _isNumeric(String str) {
    return double.tryParse(str) != null;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Query Results'),
        backgroundColor: const Color.fromARGB(
          255,
          20,
          20,
          20,
        ), // Consistent background color
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Data'),
            Tab(text: 'Charts'),
            Tab(text: 'Analysis'),
          ],
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
        ),
      ),
      body: Container(
        color: const Color.fromARGB(
          255,
          20,
          20,
          20,
        ), // Consistent background color
        child: TabBarView(
          controller: _tabController,
          children: [_buildDataTab(), _buildChartsTab(), _buildAnalysisTab()],
        ),
      ),
    );
  }

  Widget _buildDataTab() {
    if (widget.results.isEmpty) {
      return const Center(
        child: Text(
          'No data found for this query',
          style: TextStyle(color: Colors.white), // Consistent text color
        ),
      );
    }

    // Get column names from first result
    final columnNames = widget.results.first.keys.toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Question: ${widget.question}',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: Colors.white, // Consistent text color
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey[850], // Consistent card color
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'SQL: ${widget.sqlQuery}',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Colors.white, // Consistent text color
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Results (${widget.results.length} rows):',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: Colors.white, // Consistent text color
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns:
                  columnNames
                      .map(
                        (name) => DataColumn(
                          label: Text(
                            name,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.white, // Consistent text color
                            ),
                          ),
                        ),
                      )
                      .toList(),
              rows:
                  widget.results
                      .map(
                        (row) => DataRow(
                          cells:
                              columnNames
                                  .map(
                                    (col) => DataCell(
                                      Text(
                                        row[col].toString(),
                                        style: const TextStyle(
                                          color:
                                              Colors
                                                  .white, // Consistent text color
                                        ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                        ),
                      )
                      .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChartsTab() {
    if (widget.results.isEmpty) {
      return const Center(
        child: Text(
          'No data available for charts',
          style: TextStyle(color: Colors.white), // Consistent text color
        ),
      );
    }

    final columnNames = widget.results.first.keys.toList();

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          // Chart type and axis selection
          Card(
            color: Colors.grey[850], // Consistent card color
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Chart Configuration',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.white, // Consistent text color
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          decoration: const InputDecoration(
                            labelText: 'Chart Type',
                            labelStyle: TextStyle(
                              color: Colors.white,
                            ), // White text
                            border: OutlineInputBorder(),
                          ),
                          dropdownColor:
                              Colors.grey[850], // Consistent dropdown color
                          value: _selectedChartType,
                          items:
                              ['Bar', 'Line', 'Pie']
                                  .map(
                                    (type) => DropdownMenuItem<String>(
                                      value: type,
                                      child: Text(
                                        type,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ), // White text
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (value) {
                            setState(() {
                              _selectedChartType = value!;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          decoration: const InputDecoration(
                            labelText: 'X Axis',
                            labelStyle: TextStyle(
                              color: Colors.white,
                            ), // White text
                            border: OutlineInputBorder(),
                          ),
                          dropdownColor:
                              Colors.grey[850], // Consistent dropdown color
                          value: _selectedXAxis,
                          items:
                              columnNames
                                  .map(
                                    (col) => DropdownMenuItem<String>(
                                      value: col,
                                      child: Text(
                                        col,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ), // White text
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (value) {
                            setState(() {
                              _selectedXAxis = value!;
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          decoration: const InputDecoration(
                            labelText: 'Y Axis',
                            labelStyle: TextStyle(
                              color: Colors.white,
                            ), // White text
                            border: OutlineInputBorder(),
                          ),
                          dropdownColor:
                              Colors.grey[850], // Consistent dropdown color
                          value: _selectedYAxis,
                          items:
                              columnNames
                                  .map(
                                    (col) => DropdownMenuItem<String>(
                                      value: col,
                                      child: Text(
                                        col,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ), // White text
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (value) {
                            setState(() {
                              _selectedYAxis = value!;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Chart display
          Expanded(
            child: Card(
              color: Colors.grey[850], // Consistent card color
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: _buildChart(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChart() {
    try {
      switch (_selectedChartType) {
        case 'Bar':
          return BarChart(
            _graphicsService.generateBarChart(
              widget.results,
              _selectedXAxis,
              _selectedYAxis,
            ),
          );
        case 'Line':
          return LineChart(
            _graphicsService.generateLineChart(
              widget.results,
              _selectedXAxis,
              _selectedYAxis,
            ),
          );
        case 'Pie':
          return PieChart(
            _graphicsService.generatePieChart(
              widget.results,
              _selectedXAxis,
              _selectedYAxis,
            ),
          );
        default:
          return _graphicsService.suggestChartType(
            widget.results,
            _selectedXAxis,
            _selectedYAxis,
          );
      }
    } catch (e) {
      return Center(child: Text('Could not generate chart: ${e.toString()}'));
    }
  }

  Widget _buildAnalysisTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Analysis',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 20,
              color: Colors.white, // Consistent text color
            ),
          ),
          const SizedBox(height: 16),
          ..._formatAnalysisText(widget.analysis),
        ],
      ),
    );
  }

  List<Widget> _formatAnalysisText(String analysis) {
    final lines = analysis.split('\n');
    return lines.map((line) {
      if (line.startsWith('**') && line.endsWith('**')) {
        return Text(
          line.replaceAll('**', ''),
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
            color: Colors.white,
          ),
        );
      } else if (line.startsWith('* ')) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '• ',
              style: TextStyle(color: Colors.white),
            ),
            Expanded(
              child: Text(
                line.substring(2),
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        );
      } else {
        return Text(
          line,
          style: const TextStyle(color: Colors.white),
        );
      }
    }).toList();
  }
}
