import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class GraphicsService {
  // Generate a bar chart based on query results
  BarChartData generateBarChart(
    List<Map<String, dynamic>> data,
    String xAxisField,
    String yAxisField, {
    String title = '',
  }) {
    // Sort data to ensure consistent display
    data.sort(
      (a, b) => a[xAxisField].toString().compareTo(b[xAxisField].toString()),
    );

    // Extract x values (categories) and y values (numeric data)
    final xValues = data.map((item) => item[xAxisField].toString()).toList();
    final yValues =
        data
            .map((item) => double.tryParse(item[yAxisField].toString()) ?? 0.0)
            .toList();

    // Create bar chart rods
    final barGroups = List.generate(
      xValues.length,
      (index) => BarChartGroupData(
        x: index,
        barRods: [
          BarChartRodData(
            toY: yValues[index],
            color: Colors.blue,
            width: 16,
            borderRadius: BorderRadius.circular(4),
          ),
        ],
      ),
    );

    return BarChartData(
      barGroups: barGroups,
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(showTitles: true, reservedSize: 40),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (value, _) {
              if (value >= 0 && value < xValues.length) {
                // Truncate long labels
                final label = xValues[value.toInt()];
                return Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    label.length > 10 ? '${label.substring(0, 7)}...' : label,
                    style: const TextStyle(fontSize: 10),
                  ),
                );
              }
              return const Text('');
            },
            reservedSize: 40,
          ),
        ),
        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      borderData: FlBorderData(show: false),
      gridData: FlGridData(show: true),
    );
  }

  // Generate a line chart based on query results
  LineChartData generateLineChart(
    List<Map<String, dynamic>> data,
    String xAxisField,
    String yAxisField, {
    String title = '',
  }) {
    // Sort data by x-axis (typically time-based)
    data.sort(
      (a, b) => a[xAxisField].toString().compareTo(b[xAxisField].toString()),
    );

    // Create line chart spots
    final spots = List.generate(
      data.length,
      (index) => FlSpot(
        index.toDouble(),
        double.tryParse(data[index][yAxisField].toString()) ?? 0.0,
      ),
    );

    return LineChartData(
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          color: Colors.blue,
          barWidth: 3,
          dotData: FlDotData(show: true),
        ),
      ],
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(showTitles: true, reservedSize: 40),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (value, _) {
              if (value >= 0 &&
                  value < data.length &&
                  value.toInt() % (data.length ~/ 5 + 1) == 0) {
                final label = data[value.toInt()][xAxisField].toString();
                return Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    label.length > 10 ? '${label.substring(0, 7)}...' : label,
                    style: const TextStyle(fontSize: 10),
                  ),
                );
              }
              return const Text('');
            },
            reservedSize: 40,
          ),
        ),
        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      gridData: FlGridData(show: true),
      borderData: FlBorderData(show: true),
    );
  }

  // Generate a pie chart based on query results
  PieChartData generatePieChart(
    List<Map<String, dynamic>> data,
    String categoryField,
    String valueField, {
    String title = '',
  }) {
    final totalValue = data.fold<double>(
      0,
      (sum, item) =>
          sum + (double.tryParse(item[valueField].toString()) ?? 0.0),
    );

    final colors = [
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.yellow,
      Colors.purple,
      Colors.orange,
      Colors.teal,
      Colors.pink,
      Colors.amber,
      Colors.indigo,
    ];

    return PieChartData(
      sections: List.generate(data.length, (index) {
        final value =
            double.tryParse(data[index][valueField].toString()) ?? 0.0;
        final percentage = totalValue > 0 ? (value / totalValue) * 100 : 0.0;

        return PieChartSectionData(
          color: colors[index % colors.length],
          value: value,
          title: '${percentage.toStringAsFixed(1)}%',
          radius: 100,
          titleStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        );
      }),
      sectionsSpace: 2,
      centerSpaceRadius: 40,
    );
  }

  // Determine best chart type based on data
  Widget suggestChartType(
    List<Map<String, dynamic>> data,
    String xField,
    String yField,
  ) {
    // Simple heuristic: if few categories (<=10), use bar chart
    // If more data points and potentially time-related, use line chart
    if (data.length <= 10) {
      return BarChart(generateBarChart(data, xField, yField));
    } else {
      // Check if xField seems like a date/time
      final firstValue = data.first[xField].toString();
      if (firstValue.contains('-') &&
          (firstValue.contains(':') || firstValue.length == 10)) {
        return LineChart(generateLineChart(data, xField, yField));
      } else {
        // For percentage/distribution data, pie chart might be better
        final totalValue = data.fold<double>(
          0,
          (sum, item) =>
              sum + (double.tryParse(item[yField].toString()) ?? 0.0),
        );

        if (data.length <= 7 && totalValue > 0) {
          return PieChart(generatePieChart(data, xField, yField));
        } else {
          return LineChart(generateLineChart(data, xField, yField));
        }
      }
    }
  }
}
