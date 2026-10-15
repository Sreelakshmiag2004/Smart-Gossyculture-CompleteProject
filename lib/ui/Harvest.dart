import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dashboard.dart';
import 'pest_alerts_page.dart';
import 'notifications_page.dart';
import 'settings_profile_page.dart';
import 'widgets/bottom_nav_bar.dart';
import 'dart:io';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:typed_data';

class Harvest extends StatelessWidget {
  const Harvest({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6FBF4), // Match app theme
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (context) => const Dashboard()),
            );
          },
        ),
        title: const Text(
          'Harvest Logs',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ChartCard(title: 'Daily Yield', chart: _DailyYieldChart()),
              const SizedBox(height: 16),
              _ChartCard(title: 'Weekly Yield', chart: _WeeklyYieldChart()),
              const SizedBox(height: 16),
              _ChartCard(title: 'Monthly Yield', chart: _MonthlyYieldChart()),
              const SizedBox(height: 24),
              const Padding(
                  padding: EdgeInsets.only(left: 4, bottom: 12),
                  child: Text(
                    'RECENT LOGS',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Colors.grey,
                      letterSpacing: 1.2,
                    ),
                  )),
              ..._mockLogs.map((log) => _LogEntryCard(log: log)),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF5FA62C),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        elevation: 4,
                        shadowColor: const Color(0xFF5FA62C).withOpacity(0.4),
                      ),
                      onPressed: () => _saveExport(context),
                      icon: const Icon(Icons.download_rounded, size: 20),
                      label: const Text(
                        'Export',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black87,
                        elevation: 2,
                        shadowColor: Colors.black.withOpacity(0.05),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: () => _shareExport(context),
                      icon: const Icon(Icons.share_rounded, size: 20, color: Colors.blue),
                      label: const Text('Share'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
      bottomNavigationBar: const CommonBottomNavBar(currentIndex: 1),
    );
  }

  Future<List<int>?> _generateExcel() async {
    try {
      final excel = Excel.createExcel();
      // Rename the default sheet (usually 'Sheet1') to 'Harvest Logs'
      final String defaultSheet = excel.sheets.keys.first;
      excel.rename(defaultSheet, 'Harvest Logs');
      final sheet = excel['Harvest Logs'];

      sheet.appendRow([
        TextCellValue('Date'),
        TextCellValue('Status'),
        TextCellValue('Bales'),
        TextCellValue('Description')
      ]);

      for (var log in _mockLogs) {
        sheet.appendRow([
            TextCellValue(log.date),
            TextCellValue(log.status),
            IntCellValue(log.bales),
            TextCellValue(log.description),
        ]);
      }

      final fileBytes = excel.save();
      return fileBytes; 
    } catch (e) {
      return null;
    }
  }

  Future<void> _saveExport(BuildContext context) async {
    final fileBytes = await _generateExcel();
    if (context.mounted && fileBytes != null) {
      try {
        // Save to temp file first
        final directory = await getTemporaryDirectory();
        final tempFilePath = '${directory.path}/harvest_logs.xlsx';
        final tempFile = File(tempFilePath);
        await tempFile.writeAsBytes(fileBytes);

        // Open system save dialog
        final params = SaveFileDialogParams(sourceFilePath: tempFilePath);
        final finalPath = await FlutterFileDialog.saveFile(params: params);

        if (context.mounted && finalPath != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('File saved successfully'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error saving file: $e')),
          );
        }
      }
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to generate logs')),
        );
      }
    }
  }

  Future<void> _shareExport(BuildContext context) async {
    final fileBytes = await _generateExcel();
    if (fileBytes != null) {
       final directory = await getApplicationDocumentsDirectory();
       final filePath = '${directory.path}/harvest_logs.xlsx';
       File(filePath)
          ..createSync(recursive: true)
          ..writeAsBytesSync(fileBytes);
       
       if (context.mounted) {
          await Share.shareXFiles([XFile(filePath)], text: 'Here are my harvest logs');
       }
    }
  }
}

class _ChartCard extends StatelessWidget {
  final String title;
  final Widget chart;
  const _ChartCard({required this.title, required this.chart});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title.toUpperCase(),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.grey,
                    letterSpacing: 1.0,
                  ),
                ),
                Icon(Icons.show_chart_rounded, color: Theme.of(context).primaryColor, size: 20),
              ],
            ),
            const SizedBox(height: 24),
            SizedBox(height: 180, child: chart),
          ],
        ),
      ),
    );
  }
}

class _DailyYieldChart extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 0.05,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: Colors.grey.withOpacity(0.1),
              strokeWidth: 1,
              dashArray: [5, 5], // Dashed lines for clarity
            );
          },
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: 1,
              getTitlesWidget: (value, meta) {
                const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
                if (value >= 0 && value < days.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      days[value.toInt()],
                      style: const TextStyle(
                        color: Colors.grey,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        minY: 0,
        maxY: 0.16,
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
             getTooltipItems: (touchedSpots) {
              return touchedSpots.map((LineBarSpot touchedSpot) {
                return LineTooltipItem(
                  '${(touchedSpot.y * 1000).toInt()} kg',
                  const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                );
              }).toList();
            },
            tooltipRoundedRadius: 8,
            tooltipPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            tooltipMargin: 16,
          ),
          handleBuiltInTouches: true,
        ),
        lineBarsData: [
          LineChartBarData(
            spots: const [
              FlSpot(0, 0.09),
              FlSpot(1, 0.11),
              FlSpot(2, 0.10),
              FlSpot(3, 0.12),
              FlSpot(4, 0.13),
              FlSpot(5, 0.14),
              FlSpot(6, 0.13),
            ],
            isCurved: true,
            color: const Color(0xFF5FA62C),
            barWidth: 4,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 4,
                  color: Colors.white,
                  strokeWidth: 2,
                  strokeColor: const Color(0xFF5FA62C),
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF5FA62C).withOpacity(0.2), // Lighter, subtler gradient
                  const Color(0xFF5FA62C).withOpacity(0.0),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WeeklyYieldChart extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true, 
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) => FlLine(color: Colors.grey.withOpacity(0.1), strokeWidth: 1, dashArray: [5,5]),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 32,
              getTitlesWidget: (value, meta) {
                if (value == 0) return const Text('0k', style: TextStyle(color: Colors.grey, fontSize: 10));
                if (value == 1) return const Text('1k', style: TextStyle(color: Colors.grey, fontSize: 10));
                return const SizedBox.shrink();
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                const weeks = ['Wk 1', 'Wk 2', 'Wk 3', 'Wk 4'];
                if (value >= 0 && value < weeks.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(weeks[value.toInt()], style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 12)),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        minY: 0,
        maxY: 1.2,
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
             getTooltipItems: (touchedSpots) {
              return touchedSpots.map((LineBarSpot touchedSpot) {
                return LineTooltipItem(
                  '${(touchedSpot.y * 1000).toInt()} kg',
                  const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                );
              }).toList();
            },
             tooltipRoundedRadius: 8,
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: [
              FlSpot(0, 0.8),
              FlSpot(1, 0.9),
              FlSpot(2, 0.7),
              FlSpot(3, 0.85),
            ],
            isCurved: true,
            color: const Color(0xFF00B2FF),
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: true,
               getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 4,
                  color: Colors.white,
                  strokeWidth: 2,
                  strokeColor: const Color(0xFF00B2FF),
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF00B2FF).withOpacity(0.2),
                  const Color(0xFF00B2FF).withOpacity(0.0),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MonthlyYieldChart extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
           getDrawingHorizontalLine: (value) => FlLine(color: Colors.grey.withOpacity(0.1), strokeWidth: 1, dashArray: [5,5]),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 32,
              getTitlesWidget: (value, meta) {
                if (value == 0) return const Text('0k', style: TextStyle(color: Colors.grey, fontSize: 10));
                if (value == 2) return const Text('2k', style: TextStyle(color: Colors.grey, fontSize: 10));
                if (value == 4) return const Text('4k', style: TextStyle(color: Colors.grey, fontSize: 10));
                return const SizedBox.shrink();
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                const months = ['Jan', 'Feb', 'Mar', 'Apr'];
                if (value >= 0 && value < months.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(months[value.toInt()], style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 12)),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        minY: 0,
        maxY: 4.5,
         lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
             getTooltipItems: (touchedSpots) {
              return touchedSpots.map((LineBarSpot touchedSpot) {
                return LineTooltipItem(
                  '${(touchedSpot.y * 1000).toInt()} kg',
                  const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                );
              }).toList();
            },
             tooltipRoundedRadius: 8,
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: [
              FlSpot(0, 3.2),
              FlSpot(1, 2.9),
              FlSpot(2, 3.4),
              FlSpot(3, 3.8),
            ],
            isCurved: true,
            color: const Color(0xFF6E7A89),
            barWidth: 3,
            isStrokeCapRound: true,
             dotData: FlDotData(
              show: true,
               getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 4,
                  color: Colors.white,
                  strokeWidth: 2,
                  strokeColor: const Color(0xFF6E7A89),
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF6E7A89).withOpacity(0.2),
                  const Color(0xFF6E7A89).withOpacity(0.0),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LogEntry {
  final String date;
  final String status;
  final int bales;
  final String description;

  _LogEntry({
    required this.date,
    required this.status,
    required this.bales,
    required this.description,
  });
}

final List<_LogEntry> _mockLogs = [
  _LogEntry(
    date: '2024-07-28',
    status: 'Processed',
    bales: 120,
    description: 'High-quality cotton, no pests detected. Ready for shipment.',
  ),
  _LogEntry(
    date: '2024-07-27',
    status: 'Pending',
    bales: 115,
    description: 'Yield slightly below average. Awaiting quality inspection.',
  ),
  _LogEntry(
    date: '2024-07-26',
    status: 'Rejected',
    bales: 105,
    description:
        'Partial contamination detected, requires further processing. Lower yield due to unexpected rain.',
  ),
  _LogEntry(
    date: '2024-07-25',
    status: 'Processed',
    bales: 130,
    description:
        'Excellent harvest conditions. Optimal moisture levels maintained.',
  ),
  _LogEntry(
    date: '2024-07-24',
    status: 'Processed',
    bales: 110,
    description: 'Standard yield, good quality.',
  ),
  _LogEntry(
    date: '2024-07-23',
    status: 'Pending',
    bales: 98,
    description:
        'Lower yield due to late season pest activity. Inspection needed.',
  ),
];

class _LogEntryCard extends StatelessWidget {
  final _LogEntry log;
  const _LogEntryCard({required this.log});

  Color? getStatusColor(String status) {
    switch (status) {
      case 'Processed':
        return Colors.green;
      case 'Pending':
        return const Color(0xFF00B2FF);
      case 'Rejected':
        return const Color(0xFFFF4D4F);
      default:
        return Colors.grey;
    }
  }

  IconData getStatusIcon(String status) {
    switch (status) {
      case 'Processed':
        return Icons.check_circle_outline;
      case 'Pending':
        return Icons.hourglass_empty;
      case 'Rejected':
        return Icons.error_outline;
      default:
        return Icons.info_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = getStatusColor(log.status);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Harvest on ${log.date}', // Parse date for better display if needed
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        log.status,
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.scale, size: 20, color: Colors.black54),
                      const SizedBox(height: 4),
                      Text(
                        '${log.bales}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                Icon(Icons.description_outlined,
                    size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    log.description,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.black54,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
