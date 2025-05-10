import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'dart:math' as math;

class GraphicsService {
  // Palette di colori predefiniti per i grafici
  final List<Color> defaultColors = [
    Colors.blue,
    Colors.red,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.teal,
    Colors.pink,
    Colors.amber,
    Colors.indigo,
    Colors.cyan,
    Colors.lime,
    Colors.deepOrange,
  ];

  // Analisi statistica di base sui dati
  Map<String, dynamic> calculateStatistics(List<double> values) {
    if (values.isEmpty) return {};
    
    // Ordina i valori per calcolare mediana e quartili
    final sortedValues = List<double>.from(values)..sort();
    
    // Calcola media
    final sum = values.reduce((a, b) => a + b);
    final mean = sum / values.length;
    
    // Calcola deviazione standard
    final sumSquaredDiffs = values.fold<double>(
      0, 
      (sum, value) => sum + math.pow(value - mean, 2)
    );
    final stdDev = math.sqrt(sumSquaredDiffs / values.length);
    
    // Calcola mediana
    final median = values.length.isOdd 
        ? sortedValues[values.length ~/ 2] 
        : (sortedValues[values.length ~/ 2 - 1] + sortedValues[values.length ~/ 2]) / 2;
    
    // Calcola quartili
    final lowerQuartileIndex = (values.length / 4).round() - 1;
    final upperQuartileIndex = (3 * values.length / 4).round() - 1;
    final lowerQuartile = lowerQuartileIndex >= 0 ? sortedValues[lowerQuartileIndex] : sortedValues.first;
    final upperQuartile = upperQuartileIndex < sortedValues.length ? sortedValues[upperQuartileIndex] : sortedValues.last;
    
    // Calcola min, max
    final min = sortedValues.first;
    final max = sortedValues.last;
    
    return {
      'mean': mean,
      'median': median,
      'stdDev': stdDev,
      'min': min,
      'max': max,
      'lowerQuartile': lowerQuartile,
      'upperQuartile': upperQuartile,
      'range': max - min,
      'count': values.length,
    };
  }

  // Generate a bar chart based on query results
  BarChartData generateBarChart(
    List<Map<String, dynamic>> data,
    String xAxisField,
    String yAxisField, {
    String title = '',
    Map<String, dynamic>? customOptions,
  }) {
    // Applica opzioni personalizzate o usa valori predefiniti
    final options = customOptions ?? {};
    final barColor = options['barColor'] ?? defaultColors[0];
    final gridColor = options['showGrid'] == false ? Colors.transparent : Colors.white24;
    final barWidth = options['barWidth'] ?? 16.0;
    final bool showValues = options['showValues'] ?? false;
    final rotateLabels = options['rotateLabels'] ?? false;
    final groupedBars = options['groupedBars'] ?? false;
    
    // Sort data to ensure consistent display
    data.sort(
      (a, b) => a[xAxisField].toString().compareTo(b[xAxisField].toString()),
    );

    // Extract x values (categories) and y values (numeric data)
    final xValues = data.map((item) => item[xAxisField].toString()).toList();
    
    // Gestisci i casi in cui si hanno più serie di dati per barre raggruppate
    List<String> yFields = [yAxisField];
    if (groupedBars && options['yFields'] != null) {
      yFields = List<String>.from(options['yFields']);
    }
    
    // Crea bar chart rods per ogni gruppo
    final barGroups = List.generate(
      xValues.length,
      (index) {
        // Se abbiamo barre raggruppate, crea più rod per ciascun gruppo
        if (groupedBars) {
          List<BarChartRodData> rods = [];
          
          for (int i = 0; i < yFields.length; i++) {
            final field = yFields[i];
            final value = double.tryParse(data[index][field].toString()) ?? 0.0;
            
            rods.add(
              BarChartRodData(
                toY: value,
                color: defaultColors[i % defaultColors.length],
                width: barWidth / yFields.length,
                borderRadius: BorderRadius.circular(4),
                backDrawRodData: BackgroundBarChartRodData(
                  show: true,
                  color: Colors.transparent,
                ),
              ),
            );
          }
          
          return BarChartGroupData(
            x: index,
            barRods: rods,
            showingTooltipIndicators: [0],
          );
        } else {
          // Barre singole standard
          final yValue = double.tryParse(data[index][yAxisField].toString()) ?? 0.0;
          
          return BarChartGroupData(
            x: index,
            barRods: [
              BarChartRodData(
                toY: yValue,
                color: barColor is List ? defaultColors[index % defaultColors.length] : barColor,
                width: barWidth,
                borderRadius: BorderRadius.circular(4),
                backDrawRodData: BackgroundBarChartRodData(
                  show: true,
                  color: Colors.transparent,
                ),
                // Mostra valori sopra le barre se richiesto
                rodStackItems: showValues ? [
                  BarChartRodStackItem(
                    0, 
                    0, 
                    Colors.transparent,
                    BorderSide.none
                  )
                ] : [],
              ),
            ],
            showingTooltipIndicators: [0],
          );
        }
      },
    );

    return BarChartData(
      barGroups: barGroups,
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: options['leftAxisWidth'] ?? 50,
            getTitlesWidget: (value, _) {
              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: Text(
                  value.toStringAsFixed(options['decimalPlaces'] ?? 1),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                  ),
                  textAlign: TextAlign.right,
                ),
              );
            },
          ),
          axisNameWidget: options['yAxisTitle'] != null ? 
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                options['yAxisTitle'],
                style: const TextStyle(color: Colors.white70),
              ),
            ) : null,
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (value, _) {
              if (value >= 0 && value < xValues.length) {
                // Truncate long labels
                final label = xValues[value.toInt()];
                final formattedLabel = label.length > (options['labelMaxLength'] ?? 10) 
                  ? '${label.substring(0, (options['labelMaxLength'] ?? 10) - 3)}...' 
                  : label;
                  
                return rotateLabels 
                  ? Transform.rotate(
                      angle: math.pi / 4,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 5.0, right: 5.0),
                        child: Text(
                          formattedLabel,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Text(
                        formattedLabel,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                        ),
                      ),
                    );
              }
              return const Text('');
            },
            reservedSize: rotateLabels ? 60 : 40,
          ),
          axisNameWidget: options['xAxisTitle'] != null ? 
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(
                options['xAxisTitle'],
                style: const TextStyle(color: Colors.white70),
              ),
            ) : null,
        ),
        topTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: options['showTitle'] == true,
            getTitlesWidget: (_, __) => options['showTitle'] == true 
              ? Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ) 
              : const Text(''),
          ),
        ),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      borderData: FlBorderData(
        show: options['showBorder'] ?? false,
        border: Border(
          bottom: BorderSide(color: gridColor, width: 1),
          left: BorderSide(color: gridColor, width: 1),
        ),
      ),
      gridData: FlGridData(
        show: options['showGrid'] ?? true,
        getDrawingHorizontalLine: (value) => FlLine(
          color: gridColor,
          strokeWidth: 0.5,
          dashArray: options['gridDashed'] == true ? [5, 5] : null,
        ),
        getDrawingVerticalLine: (value) => FlLine(
          color: gridColor,
          strokeWidth: 0.5,
          dashArray: options['gridDashed'] == true ? [5, 5] : null,
        ),
      ),
      // Configura tooltip migliorati
      barTouchData: BarTouchData(
        enabled: true,
        touchTooltipData: BarTouchTooltipData(
          getTooltipItem: (group, groupIndex, rod, rodIndex) {
            final xValue = xValues[group.x.toInt()];
            final yValue = rod.toY;
            String tooltipText = '$xValue: ${yValue.toStringAsFixed(2)}';
            
            if (groupedBars && rodIndex < yFields.length) {
              tooltipText = '${yFields[rodIndex]}: ${yValue.toStringAsFixed(2)}';
            }
            
            return BarTooltipItem(
              tooltipText,
              const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            );
          },
        ),
      ),
    );
  }

  // Generate a line chart based on query results with enhanced features
  LineChartData generateLineChart(
    List<Map<String, dynamic>> data,
    String xAxisField,
    String yAxisField, {
    String title = '',
    Map<String, dynamic>? customOptions,
  }) {
    // Applica opzioni personalizzate o usa valori predefiniti
    final options = customOptions ?? {};
    final lineColor = options['lineColor'] ?? defaultColors[0];
    final gridColor = options['showGrid'] == false ? Colors.transparent : Colors.white24;
    final curvedLines = options['curvedLines'] ?? true;
    final showDots = options['showDots'] ?? true;
    final showArea = options['showArea'] ?? false;
    final areaOpacity = options['areaOpacity'] ?? 0.2;
    final lineWidth = options['lineWidth'] ?? 3.0;
    final bool showTrendline = options['showTrendline'] ?? false;
    final bool multiSeries = options['multiSeries'] ?? false;
    
    // Sort data by x-axis (typically time-based)
    data.sort(
      (a, b) => a[xAxisField].toString().compareTo(b[xAxisField].toString()),
    );

    // Gestione di serie multiple di dati
    List<String> yFields = [yAxisField];
    if (multiSeries && options['yFields'] != null) {
      yFields = List<String>.from(options['yFields']);
    }
    
    // Crea le serie di dati
    List<LineChartBarData> lineBars = [];
    
    for (int seriesIndex = 0; seriesIndex < yFields.length; seriesIndex++) {
      final field = yFields[seriesIndex];
      final seriesColor = multiSeries 
          ? defaultColors[seriesIndex % defaultColors.length]
          : lineColor;
          
      // Create line chart spots
      final spots = List.generate(
        data.length,
        (index) => FlSpot(
          index.toDouble(),
          double.tryParse(data[index][field].toString()) ?? 0.0,
        ),
      );
      
      // Calcola la linea di tendenza se richiesta
      List<ScatterSpot> trendlineSpots = [];
if (showTrendline && spots.length > 2) {
  // Converte ScatterSpot in FlSpot per calcolare la trendline
  final List<FlSpot> flSpots = [];
  for (final spot in spots) {
    flSpots.add(FlSpot(spot.x, spot.y));
  }
  final trendline = _calculateTrendLine(flSpots);

  // Converte la trendline in ScatterSpot
  for (var spot in trendline) {
    trendlineSpots.add(ScatterSpot(spot.x, spot.y));
  }
}
      
      // Aggiungi serie principale
      lineBars.add(
        LineChartBarData(
          spots: spots,
          isCurved: curvedLines,
          color: seriesColor,
          barWidth: lineWidth,
          isStrokeCapRound: true,
          dotData: FlDotData(
            show: showDots,
            getDotPainter: (spot, percent, bar, index) {
              return FlDotCirclePainter(
                radius: 4,
                color: seriesColor,
                strokeWidth: 1,
                strokeColor: Colors.white,
              );
            },
          ),
          belowBarData: BarAreaData(
            show: showArea,
            color: seriesColor.withOpacity(areaOpacity),
          ),
        ),
      );
      
      // Aggiungi linea di tendenza se richiesta
      if (showTrendline && trendlineSpots.isNotEmpty) {
        lineBars.add(
          LineChartBarData(
            spots: trendlineSpots,
            isCurved: false,
            color: seriesColor.withOpacity(0.7),
            barWidth: 1.5,
            isStrokeCapRound: true,
            dotData: FlDotData(show: false),
            dashArray: [5, 5], // Linea tratteggiata per la trendline
          ),
        );
      }
    }

    // Aggiungi statistiche come line bar extras se richieste
    if (options['showAvgLine'] == true) {
      final yValues = data.map((item) => double.tryParse(item[yAxisField].toString()) ?? 0.0).toList();
      final stats = calculateStatistics(yValues);
      final avgValue = stats['mean'] as double;
      
      // Linea della media
      lineBars.add(
        LineChartBarData(
          spots: [
            FlSpot(0, avgValue),
            FlSpot(data.length - 1, avgValue),
          ],
          isCurved: false,
          color: Colors.amber,
          barWidth: 1.5,
          isStrokeCapRound: true,
          dotData: FlDotData(show: false),
          dashArray: [2, 4],
        ),
      );
    }

    return LineChartData(
      lineBarsData: lineBars,
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: options['leftAxisWidth'] ?? 50,
            getTitlesWidget: (value, _) {
              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: Text(
                  value.toStringAsFixed(options['decimalPlaces'] ?? 1),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                  ),
                  textAlign: TextAlign.right,
                ),
              );
            },
          ),
          axisNameWidget: options['yAxisTitle'] != null ? 
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                options['yAxisTitle'],
                style: const TextStyle(color: Colors.white70),
              ),
            ) : null,
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (value, _) {
              if (value >= 0 &&
                  value < data.length &&
                  value.toInt() % (options['xAxisLabelFrequency'] ?? math.max(1, data.length ~/ 5)) == 0) {
                final label = data[value.toInt()][xAxisField].toString();
                final maxLength = options['labelMaxLength'] ?? 10;
                
                return Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    label.length > maxLength ? '${label.substring(0, maxLength - 3)}...' : label,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white,
                    ),
                  ),
                );
              }
              return const Text('');
            },
            reservedSize: 40,
          ),
          axisNameWidget: options['xAxisTitle'] != null ? 
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(
                options['xAxisTitle'],
                style: const TextStyle(color: Colors.white70),
              ),
            ) : null,
        ),
        topTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: options['showTitle'] == true,
            getTitlesWidget: (_, __) => options['showTitle'] == true 
              ? Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ) 
              : const Text(''),
          ),
        ),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      gridData: FlGridData(
        show: options['showGrid'] ?? true,
        getDrawingHorizontalLine: (value) => FlLine(
          color: gridColor,
          strokeWidth: 0.5,
          dashArray: options['gridDashed'] == true ? [5, 5] : null,
        ),
        getDrawingVerticalLine: (value) => FlLine(
          color: gridColor,
          strokeWidth: 0.5,
          dashArray: options['gridDashed'] == true ? [5, 5] : null,
        ),
      ),
      // Configurazione avanzata del tooltip
      lineTouchData: LineTouchData(
        enabled: true,
        touchTooltipData: LineTouchTooltipData(
          getTooltipItems: (touchedSpots) {
            return touchedSpots.map((spot) {
              final seriesIndex = spot.barIndex;
              final dataIndex = spot.x.toInt();
              if (dataIndex >= 0 && dataIndex < data.length) {
                final xValue = data[dataIndex][xAxisField].toString();
                final fieldName = seriesIndex < yFields.length ? yFields[seriesIndex] : yAxisField;
                
                // Se la serie è una trendline o statistica, gestisci diversamente
                if (seriesIndex >= yFields.length) {
                  if (seriesIndex % 2 == 1 && showTrendline) { // È una trendline
                    return LineTooltipItem(
                      'Trend: ${spot.y.toStringAsFixed(2)}',
                      TextStyle(
                        color: defaultColors[seriesIndex ~/ 2 % defaultColors.length],
                        fontWeight: FontWeight.bold,
                      ),
                    );
                  } else { // È una linea statistica
                    return LineTooltipItem(
                      'Avg: ${spot.y.toStringAsFixed(2)}',
                      const TextStyle(
                        color: Colors.amber,
                        fontWeight: FontWeight.bold,
                      ),
                    );
                  }
                }
                
                return LineTooltipItem(
                  '$xValue: ${spot.y.toStringAsFixed(2)}',
                  TextStyle(
                    color: multiSeries 
                      ? defaultColors[seriesIndex % defaultColors.length]
                      : defaultColors[0],
                    fontWeight: FontWeight.bold,
                  ),
                  children: multiSeries 
                    ? [
                        TextSpan(
                          text: '\n$fieldName',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.normal,
                            fontSize: 12,
                          ),
                        )
                      ]
                    : null,
                );
              }
              return null;
            }).toList();
          },
        ),
      ),
    );
  }

  // Calcola la linea di tendenza lineare
  List<FlSpot> _calculateTrendLine(List<FlSpot> spots) {
    if (spots.length < 2) return [];
    
    double sumX = 0;
    double sumY = 0;
    double sumXX = 0;
    double sumXY = 0;
    
    for (var spot in spots) {
      sumX += spot.x;
      sumY += spot.y;
      sumXX += spot.x * spot.x;
      sumXY += spot.x * spot.y;
    }
    
    final n = spots.length.toDouble();
    final slope = (n * sumXY - sumX * sumY) / (n * sumXX - sumX * sumX);
    final intercept = (sumY - slope * sumX) / n;
    
    // Create trendline spots
    return [
      FlSpot(spots.first.x, slope * spots.first.x + intercept),
      FlSpot(spots.last.x, slope * spots.last.x + intercept),
    ];
  }

  // Generate a pie chart based on query results with enhanced features
  PieChartData generatePieChart(
    List<Map<String, dynamic>> data,
    String categoryField,
    String valueField, {
    String title = '',
    Map<String, dynamic>? customOptions,
  }) {
    // Applica opzioni personalizzate o usa valori predefiniti
    final options = customOptions ?? {};
    final sectionSpace = options['sectionSpace'] ?? 2.0;
    final centerSpaceRadius = options['centerSpaceRadius'] ?? 40.0;
    final showPercentValues = options['showPercentValues'] ?? true;
    final showLegend = options['showLegend'] ?? false;
    final useDynamicColors = options['useDynamicColors'] ?? true;
    final bool sortData = options['sortData'] ?? true;
    
    // Filtro per valori nulli o zero e ordino se richiesto
    var filteredData = data.where((item) {
      final value = double.tryParse(item[valueField].toString()) ?? 0.0;
      return value > 0;
    }).toList();
    
    if (sortData) {
      filteredData.sort((a, b) {
        final aValue = double.tryParse(a[valueField].toString()) ?? 0.0;
        final bValue = double.tryParse(b[valueField].toString()) ?? 0.0;
        return bValue.compareTo(aValue); // Sort descending
      });
    }
    
    // Limita il numero di segmenti per evitare grafici troppo affollati
    final maxSegments = options['maxSegments'] ?? 10;
    List<Map<String, dynamic>> processedData;
    
    if (filteredData.length > maxSegments) {
      // Prendi i primi N-1 segmenti più grandi
      processedData = filteredData.sublist(0, maxSegments - 1);
      
      // Aggrega i rimanenti in "Altri"
      double othersTotal = 0;
      for (int i = maxSegments - 1; i < filteredData.length; i++) {
        othersTotal += double.tryParse(filteredData[i][valueField].toString()) ?? 0.0;
      }
      
      // Aggiungi la categoria "Altri"
      if (othersTotal > 0) {
        processedData.add({
          categoryField: options['othersLabel'] ?? 'Others',
          valueField: othersTotal,
        });
      }
    } else {
      processedData = filteredData;
    }

    // Calculate total for percentage
    final totalValue = processedData.fold<double>(
      0,
      (sum, item) =>
          sum + (double.tryParse(item[valueField].toString()) ?? 0.0),
    );

    // Generate dynamic colors or use provided colors
    final List<Color> sectionColors = useDynamicColors
        ? List.generate(
            processedData.length,
            (index) => defaultColors[index % defaultColors.length],
          )
        : options['sectionColors'] ?? defaultColors;

    return PieChartData(
      sections: List.generate(processedData.length, (index) {
        final value =
            double.tryParse(processedData[index][valueField].toString()) ?? 0.0;
        final percentage = totalValue > 0 ? (value / totalValue) * 100 : 0.0;
        final categoryName = processedData[index][categoryField].toString();
        
        // Genera un titolo per la sezione
        String sectionTitle = '';
        if (showPercentValues) {
          sectionTitle = '${percentage.toStringAsFixed(1)}%';
        } else {
          sectionTitle = value.toStringAsFixed(options['decimalPlaces'] ?? 1);
        }
        
        if (options['showCategoryOnPie'] == true) {
          final shortCategory = categoryName.length > 10 
            ? '${categoryName.substring(0, 8)}...' 
            : categoryName;
          sectionTitle = '$shortCategory\n$sectionTitle';
        }

        return PieChartSectionData(
          color: sectionColors[index % sectionColors.length],
          value: value,
          title: sectionTitle,
          radius: options['sectionRadius'] ?? 100,
          titleStyle: TextStyle(
            fontSize: options['titleSize'] ?? 12,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
          badgeWidget: options['badgeIcon'] != null 
            ? Icon(
                options['badgeIcon'],
                color: Colors.white,
                size: 16,
              ) 
            : null,
          badgePositionPercentageOffset: 1.1,
        );
      }),
      sectionsSpace: sectionSpace,
      centerSpaceRadius: centerSpaceRadius,
      pieTouchData: PieTouchData(
        enabled: true,
        touchCallback: (event, response) {
          // Callback personalizzata per il tocco su un settore
          if (options['onSectionTouch'] != null && response != null && response.touchedSection != null) {
            final sectionIndex = response.touchedSection!.touchedSectionIndex;
            if (sectionIndex >= 0 && sectionIndex < processedData.length) {
              options['onSectionTouch'](processedData[sectionIndex]);
            }
          }
        },
      ),
    );
  }

  // Generate a scatter chart (new chart type)
  ScatterChartData generateScatterChart(
    List<Map<String, dynamic>> data,
    String xAxisField,
    String yAxisField, {
    String? sizeField,
    String? colorField,
    Map<String, dynamic>? customOptions,
  }) {
    final options = customOptions ?? {};
    final gridColor = options['showGrid'] == false ? Colors.transparent : Colors.white24;
    final dotSize = options['dotSize'] ?? 8.0;
    final showTrendline = options['showTrendline'] ?? false;
    
    // Estrai valori X e Y
    List<ScatterSpot> spots = [];
    
    for (int i = 0; i < data.length; i++) {
      final xValue = double.tryParse(data[i][xAxisField].toString()) ?? 0.0;
      final yValue = double.tryParse(data[i][yAxisField].toString()) ?? 0.0;
      
      // Dimensione personalizzata se specificato un campo
      double size = dotSize;
      if (sizeField != null && data[i][sizeField] != null) {
        final sizeValue = double.tryParse(data[i][sizeField].toString()) ?? 0.0;
        // Scala il valore in un range ragionevole per il punto
        size = math.max(4.0, math.min(20.0, sizeValue / 10));
      }
      
      // Colore personalizzato se specificato un campo
      Color color = defaultColors[0];
      if (colorField != null && data[i][colorField] != null) {
        // Mappa i valori alle categorie di colore
        final colorValue = data[i][colorField].toString();
        final colorIndex = data.map((e) => e[colorField].toString()).toSet().toList().indexOf(colorValue);
        color = defaultColors[colorIndex % defaultColors.length];
      }
      
      spots.add(
        ScatterSpot(
          xValue, 
          yValue
        ),
      );
    }
    
    // Lista di serie di dati scatter
    List<ScatterSpot> trendlineSpots = [];
if (showTrendline && spots.length > 2) {
  // Converte ScatterSpot in FlSpot per calcolare la trendline
  final List<FlSpot> flSpots = []; // Explicitly type flSpots
  for (final spot in spots) { // Use a for-loop instead of .map()
    flSpots.add(FlSpot(spot.x, spot.y));
  }
  final trendline = _calculateTrendLine(flSpots);

  // Converte la trendline in ScatterSpot
  trendlineSpots = []; // Re-initialize or ensure it's empty if needed
  for (var spot in trendline) {
    trendlineSpots.add(ScatterSpot(spot.x, spot.y));
  }
}

    return ScatterChartData(
      scatterSpots: spots,
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: options['leftAxisWidth'] ?? 50,
            getTitlesWidget: (value, _) {
              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: Text(
                  value.toStringAsFixed(options['decimalPlaces'] ?? 1),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                  ),
                  textAlign: TextAlign.right,
                ),
              );
            },
          ),
          axisNameWidget: options['yAxisTitle'] != null ? 
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                options['yAxisTitle'],
                style: const TextStyle(color: Colors.white70),
              ),
            ) : null,
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (value, _) {
              return Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  value.toStringAsFixed(options['decimalPlaces'] ?? 1),
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white,
                  ),
                ),
              );
            },
            reservedSize: 40,
          ),
          axisNameWidget: options['xAxisTitle'] != null ? 
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(
                options['xAxisTitle'],
                style: const TextStyle(color: Colors.white70),
              ),
            ) : null,
        ),
        topTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: options['showTitle'] == true,
            getTitlesWidget: (_, __) => options['showTitle'] == true 
              ? Text(
                  options['title'],
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ) 
              : const Text(''),
          ),
        ),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      gridData: FlGridData(
        show: options['showGrid'] ?? true,
        getDrawingHorizontalLine: (value) => FlLine(
          color: gridColor,
          strokeWidth: 0.5,
          dashArray: options['gridDashed'] == true ? [5, 5] : null,
        ),
        getDrawingVerticalLine: (value) => FlLine(
          color: gridColor,
          strokeWidth: 0.5,
          dashArray: options['gridDashed'] == true ? [5, 5] : null,
        ),
      ),
      borderData: FlBorderData(
        show: options['showBorder'] ?? true,
        border: Border(
          bottom: BorderSide(color: gridColor, width: 1),
          left: BorderSide(color: gridColor, width: 1),
        ),
      ),
      scatterTouchData: ScatterTouchData(
      enabled: true,
      touchTooltipData: ScatterTouchTooltipData(
        getTooltipItems: (ScatterSpot touchedSpot) {
          return ScatterTooltipItem(
            'X: ${touchedSpot.x.toStringAsFixed(2)}\nY: ${touchedSpot.y.toStringAsFixed(2)}',
            textStyle: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          );
        },
        ),
      ),
    );
  }

  // Generate a radar chart (new chart type)
  RadarChartData generateRadarChart(
    List<Map<String, dynamic>> data,
    List<String> fields, {
    String? titleField,
    Map<String, dynamic>? customOptions,
  }) {
    final options = customOptions ?? {};
    
    // Estrai titoli se presente un campo titolo
    List<String> titles = [];
    if (titleField != null) {
      titles = data.map((item) => item[titleField].toString()).toList();
    } else {
      titles = List.generate(data.length, (index) => 'Item ${index + 1}');
    }
    
    // Genera i dati per il grafico radar
    List<RadarDataSet> dataSets = [];
    
    for (int i = 0; i < data.length; i++) {
      final title = titles[i];
      final values = fields.map((field) {
        return double.tryParse(data[i][field].toString()) ?? 0.0;
      }).toList();
      
      // Normalizza i valori tra 0 e 1 se richiesto
      if (options['normalizeValues'] == true) {
        final maxVal = values.reduce((curr, next) => curr > next ? curr : next);
        if (maxVal > 0) {
          for (int j = 0; j < values.length; j++) {
            values[j] = values[j] / maxVal;
          }
        }
      }
      
      dataSets.add(
        RadarDataSet(
          dataEntries: values.map((value) => RadarEntry(value: value)).toList(),
          fillColor: defaultColors[i % defaultColors.length].withOpacity(0.2),
          borderColor: defaultColors[i % defaultColors.length],
          entryRadius: 3,
          borderWidth: 2,
        ),
      );
    }
    
    return RadarChartData(
      dataSets: dataSets,
      radarShape: options['shape'] == 'circle' ? RadarShape.circle : RadarShape.polygon,
      radarBorderData: const BorderSide(color: Colors.white24),
      gridBorderData: const BorderSide(color: Colors.white24, width: 1),
      tickBorderData: const BorderSide(color: Colors.white24, width: 1),
      ticksTextStyle: const TextStyle(color: Colors.white, fontSize: 10),
      titleTextStyle: const TextStyle(color: Colors.white, fontSize: 12),
      getTitle: (int index, double angle) { // Modified signature
    // The 'angle' parameter is provided by fl_chart and can be used for custom title rotation if needed.
    // If you don't need it, you can ignore it, but it must be in the signature.
    return RadarChartTitle(text: fields[index]); // Return RadarChartTitle
  },
    );
  }

  // Generate a box plot chart (nuovo tipo di grafico)
  LineChartData generateBoxPlotChart(
    List<Map<String, dynamic>> data,
    String categoryField,
    String valueField, {
    Map<String, dynamic>? customOptions,
  }) {
    final options = customOptions ?? {};
    final boxWidth = options['boxWidth'] ?? 0.6;
    final gridColor = options['showGrid'] == false ? Colors.transparent : Colors.white24;
    
    // Raggruppa i dati per categoria
    Map<String, List<double>> categorizedData = {};
    
    for (var item in data) {
      final category = item[categoryField].toString();
      final value = double.tryParse(item[valueField].toString()) ?? 0.0;
      
      if (!categorizedData.containsKey(category)) {
        categorizedData[category] = [];
      }
      categorizedData[category]!.add(value);
    }
    
    // Calcola le statistiche per ogni categoria
    List<String> categories = [];
    List<Map<String, dynamic>> statsForCategories = [];
    
    categorizedData.forEach((category, values) {
      categories.add(category);
      statsForCategories.add(calculateStatistics(values));
    });
    
    // Crea le linee e i rettangoli per i box plot
    List<LineChartBarData> boxPlotBars = [];
    
    for (int i = 0; i < categories.length; i++) {
      final stats = statsForCategories[i];
      final xPos = i.toDouble();
      final color = defaultColors[i % defaultColors.length];
      
      // Linea verticale principale (min-max)
      boxPlotBars.add(
        LineChartBarData(
          spots: [
            FlSpot(xPos, stats['min']),
            FlSpot(xPos, stats['max'])
          ],
          color: color,
          barWidth: 1,
          dotData: FlDotData(show: false),
        ),
      );
      
      // Linee orizzontali per min e max
      final halfWidth = boxWidth / 2;
      boxPlotBars.add(
        LineChartBarData(
          spots: [
            FlSpot(xPos - halfWidth, stats['min']),
            FlSpot(xPos + halfWidth, stats['min'])
          ],
          color: color,
          barWidth: 1,
          dotData: FlDotData(show: false),
        ),
      );
      
      boxPlotBars.add(
        LineChartBarData(
          spots: [
            FlSpot(xPos - halfWidth, stats['max']),
            FlSpot(xPos + halfWidth, stats['max'])
          ],
          color: color,
          barWidth: 1,
          dotData: FlDotData(show: false),
        ),
      );
      
      // Box (IQR): lower quartile to upper quartile
      // Rappresentato da 4 linee che formano un rettangolo
      final q1 = stats['lowerQuartile'];
      final q3 = stats['upperQuartile'];
      
      // Bottom horizontal
      boxPlotBars.add(
        LineChartBarData(
          spots: [
            FlSpot(xPos - halfWidth, q1),
            FlSpot(xPos + halfWidth, q1)
          ],
          color: color,
          barWidth: 2,
          dotData: FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            color: color.withOpacity(0.1),
            cutOffY: q3,
            applyCutOffY: true,
          ),
        ),
      );
      
      // Top horizontal
      boxPlotBars.add(
        LineChartBarData(
          spots: [
            FlSpot(xPos - halfWidth, q3),
            FlSpot(xPos + halfWidth, q3)
          ],
          color: color,
          barWidth: 2,
          dotData: FlDotData(show: false),
        ),
      );
      
      // Left vertical
      boxPlotBars.add(
        LineChartBarData(
          spots: [
            FlSpot(xPos - halfWidth, q1),
            FlSpot(xPos - halfWidth, q3)
          ],
          color: color,
          barWidth: 2,
          dotData: FlDotData(show: false),
        ),
      );
      
      // Right vertical
      boxPlotBars.add(
        LineChartBarData(
          spots: [
            FlSpot(xPos + halfWidth, q1),
            FlSpot(xPos + halfWidth, q3)
          ],
          color: color,
          barWidth: 2,
          dotData: FlDotData(show: false),
        ),
      );
      
      // Median line
      boxPlotBars.add(
        LineChartBarData(
          spots: [
            FlSpot(xPos - halfWidth, stats['median']),
            FlSpot(xPos + halfWidth, stats['median'])
          ],
          color: Colors.white,
          barWidth: 2,
          dotData: FlDotData(show: false),
        ),
      );
    }

    return LineChartData(
      lineBarsData: boxPlotBars,
      gridData: FlGridData(
        show: options['showGrid'] ?? true,
        getDrawingHorizontalLine: (value) => FlLine(
          color: gridColor,
          strokeWidth: 0.5,
        ),
        getDrawingVerticalLine: (value) => FlLine(
          color: gridColor,
          strokeWidth: 0.5,
        ),
      ),
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 40,
            getTitlesWidget: (value, _) {
              return Text(
                value.toString(),
                style: const TextStyle(color: Colors.white),
              );
            },
          ),
          axisNameWidget: options['yAxisTitle'] != null ? 
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                options['yAxisTitle'],
                style: const TextStyle(color: Colors.white70),
              ),
            ) : null,
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (value, _) {
              if (value >= 0 && value < categories.length) {
                final label = categories[value.toInt()];
                return Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    label.length > 10 ? '${label.substring(0, 7)}...' : label,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white,
                    ),
                  ),
                );
              }
              return const Text('');
            },
            reservedSize: 40,
          ),
          axisNameWidget: options['xAxisTitle'] != null ? 
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(
                options['xAxisTitle'],
                style: const TextStyle(color: Colors.white70),
              ),
            ) : null,
        ),
        topTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: options['showTitle'] == true,
            getTitlesWidget: (_, __) => options['showTitle'] == true && options['title'] != null
              ? Text(
                  options['title'],
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ) 
              : const Text(''),
          ),
        ),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      borderData: FlBorderData(
        show: options['showBorder'] ?? true,
        border: Border(
          bottom: BorderSide(color: gridColor, width: 1),
          left: BorderSide(color: gridColor, width: 1),
        ),
      ),
      // Tooltip personalizzato per box plot
      lineTouchData: LineTouchData(
        enabled: true,
        touchTooltipData: LineTouchTooltipData(
          getTooltipItems: (touchedSpots) {
            if (touchedSpots.isEmpty) return [];
            
            final index = touchedSpots.first.x.toInt();
            if (index >= 0 && index < categories.length) {
              final category = categories[index];
              final stats = statsForCategories[index];
              
              return [
                LineTooltipItem(
                  '$category\n'
                  'Min: ${stats["min"].toStringAsFixed(2)}\n'
                  'Q1: ${stats["lowerQuartile"].toStringAsFixed(2)}\n'
                  'Median: ${stats["median"].toStringAsFixed(2)}\n'
                  'Q3: ${stats["upperQuartile"].toStringAsFixed(2)}\n'
                  'Max: ${stats["max"].toStringAsFixed(2)}',
                  const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ];
            }
            return [];
          },
        ),
      ),
    );
  }

  // Histograma (nuovo tipo di grafico)
  BarChartData generateHistogram(
    List<Map<String, dynamic>> data,
    String valueField, {
    int bins = 10,
    Map<String, dynamic>? customOptions,
  }) {
    final options = customOptions ?? {};
    final histogramColor = options['histogramColor'] ?? defaultColors[0];
    final gridColor = options['showGrid'] == false ? Colors.transparent : Colors.white24;
    
    // Estrai valori numerici
    final values = data
        .map((item) => double.tryParse(item[valueField].toString()) ?? 0.0)
        .toList();
    
    if (values.isEmpty) {
      return BarChartData();
    }
    
    // Calcola min e max
    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);
    
    // Calcola i bin
    final binWidth = (max - min) / bins;
    
    // Funzione per calcolare il bin di un valore
    int getBinIndex(double value) {
      if (value == max) return bins - 1;
      return ((value - min) / binWidth).floor();
    }
    
    // Conteggia i valori in ciascun bin
    List<int> binCounts = List.filled(bins, 0);
    for (var value in values) {
      binCounts[getBinIndex(value)]++;
    }
    
    // Crea i gruppi di barre per l'istogramma
    final barGroups = List.generate(
      bins,
      (index) => BarChartGroupData(
        x: index,
        barRods: [
          BarChartRodData(
            toY: binCounts[index].toDouble(),
            color: histogramColor,
            width: options['barWidth'] ?? 16,
            borderRadius: BorderRadius.circular(0), // Barre rettangolari per istogramma
            backDrawRodData: BackgroundBarChartRodData(
              show: true,
              color: Colors.transparent,
            ),
          ),
        ],
        showingTooltipIndicators: [0],
      ),
    );

    return BarChartData(
      barGroups: barGroups,
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 40,
            getTitlesWidget: (value, _) {
              return Text(
                value.toInt().toString(),
                style: const TextStyle(color: Colors.white),
              );
            },
          ),
          axisNameWidget: options['yAxisTitle'] != null ? 
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                options['yAxisTitle'] ?? 'Frequency',
                style: const TextStyle(color: Colors.white70),
              ),
            ) : null,
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (value, _) {
              if (value >= 0 && value < bins) {
                // Calcola il valore di inizio del bin
                final binStart = min + (value * binWidth);
                final binEnd = binStart + binWidth;
                
                return Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    '${binStart.toStringAsFixed(1)}-${binEnd.toStringAsFixed(1)}',
                    style: const TextStyle(
                      fontSize: 8,
                      color: Colors.white,
                    ),
                  ),
                );
              }
              return const Text('');
            },
            reservedSize: 50,
          ),
          axisNameWidget: options['xAxisTitle'] != null ? 
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(
                options['xAxisTitle'] ?? valueField,
                style: const TextStyle(color: Colors.white70),
              ),
            ) : null,
        ),
        topTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: options['showTitle'] == true,
            getTitlesWidget: (_, __) => options['showTitle'] == true
              ? Text(
                  options['title'] ?? 'Histogram of $valueField',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ) 
              : const Text(''),
          ),
        ),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      gridData: FlGridData(
        show: options['showGrid'] ?? true,
        getDrawingHorizontalLine: (value) => FlLine(
          color: gridColor,
          strokeWidth: 0.5,
        ),
        getDrawingVerticalLine: (value) => FlLine(
          color: gridColor,
          strokeWidth: 0.5,
        ),
      ),
      borderData: FlBorderData(
        show: options['showBorder'] ?? false,
        border: Border(
          bottom: BorderSide(color: gridColor, width: 1),
          left: BorderSide(color: gridColor, width: 1),
        ),
      ),
      // Tooltip migliorato per istogramma
      barTouchData: BarTouchData(
        enabled: true,
        touchTooltipData: BarTouchTooltipData(
          getTooltipItem: (group, groupIndex, rod, rodIndex) {
            final binStart = min + (group.x * binWidth);
            final binEnd = binStart + binWidth;
            final count = rod.toY.toInt();
            
            return BarTooltipItem(
              'Range: ${binStart.toStringAsFixed(1)} - ${binEnd.toStringAsFixed(1)}\n'
              'Count: $count (${(count / values.length * 100).toStringAsFixed(1)}%)',
              const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            );
          },
        ),
      ),
    );
  }

  // Determine best chart type based on data with new chart types
  Widget suggestChartType(
    List<Map<String, dynamic>> data,
    String xField,
    String yField, {
    Map<String, dynamic>? customOptions,
  }) {
    final options = customOptions ?? {};
    
    // Esaminiamo la struttura dei dati per fare una scelta intelligente
    if (data.isEmpty) {
      return const Center(child: Text('No data available', style: TextStyle(color: Colors.white)));
    }
    
    // Se i dati sono pochi (≤10), un grafico a barre è generalmente più leggibile
    if (data.length <= 10) {
      return BarChart(generateBarChart(data, xField, yField, customOptions: options));
    }
    
    // Verifica se xField contiene date (potrebbe essere una serie temporale)
    bool hasTimeData = false;
    final firstValue = data.first[xField].toString();
    if (firstValue.contains('-') && (firstValue.contains(':') || firstValue.length == 10)) {
      hasTimeData = true;
    }
    
    // Verifica se i dati contengono percentuali o parti di un tutto
    final totalValue = data.fold<double>(
      0,
      (sum, item) => sum + (double.tryParse(item[yField].toString()) ?? 0.0),
    );
    
    // Verifica se xField contiene valori numerici (potenzialmente correlazioni)
    bool hasNumericXAxis = data.first[xField] != null &&
                      double.tryParse(data.first[xField].toString()) != null;
                          
    // Verifica se i dati hanno molte categorie uniche per l'asse x
    final uniqueXValues = data.map((item) => item[xField].toString()).toSet();
    
    // Conta il numero di valori y non nulli
    int nonNullYValues = data.where((item) => 
      double.tryParse(item[yField].toString()) != null && 
      double.tryParse(item[yField].toString())! > 0
    ).length;
    
    // Logica di decisione per il tipo di grafico più appropriato
    
    // Se entrambi gli assi sono numerici (e non date), probabilmente un grafico a dispersione è più adatto
    if (hasNumericXAxis && nonNullYValues > 0) {
      return options['preferScatter'] == true ? 
        ScatterChart(generateScatterChart(data, xField, yField, customOptions: options)) :
        LineChart(generateLineChart(data, xField, yField, customOptions: options));
    }
    
    // Per dati temporali o dati con molte categorie, un grafico a linee è spesso la scelta migliore
    if (hasTimeData || uniqueXValues.length > 10) {
      return LineChart(generateLineChart(data, xField, yField, customOptions: options));
    }
    
    // Per distribuzioni di dati, l'istogramma è utile
    if (options['showDistribution'] == true && nonNullYValues > 5) {
      return BarChart(generateHistogram(data, yField, customOptions: options));
    }
    
    // Per percentuali o parti di un tutto, un grafico a torta è appropriato se ci sono poche categorie
    if (data.length <= 7 && nonNullYValues > 0 && totalValue > 0 && 
        (options['preferPie'] == true || uniqueXValues.length <= 7)) {
      return PieChart(generatePieChart(data, xField, yField, customOptions: options));
    }
    
    // Se abbiamo più di una metrica da confrontare, un grafico radar può essere utile
    if (options['radarFields'] != null && (options['radarFields'] as List).length >= 3) {
      return RadarChart(generateRadarChart(
        data, 
        List<String>.from(options['radarFields']),
        titleField: xField,
        customOptions: options
      ));
    }
    
    // Per un confronto di distribuzione statistica, i box plot sono ottimi
    if (options['showBoxPlot'] == true) {
      return LineChart(generateBoxPlotChart(data, xField, yField, customOptions: options));
    }
    
    // Default: un grafico a barre per casi generici
    return BarChart(generateBarChart(data, xField, yField, customOptions: options));
  }
}
