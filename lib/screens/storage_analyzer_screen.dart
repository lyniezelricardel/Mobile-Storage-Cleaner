import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import '../providers/storage_provider.dart';
import '../widgets/ui_widgets.dart';

/// Screen showing storage analysis with charts and breakdown.
class StorageAnalyzerScreen extends StatefulWidget {
  final bool embedded;

  const StorageAnalyzerScreen({super.key, this.embedded = false});

  @override
  State<StorageAnalyzerScreen> createState() => _StorageAnalyzerScreenState();
}

class _StorageAnalyzerScreenState extends State<StorageAnalyzerScreen> {
  PreferredSizeWidget? _appBar() {
    if (widget.embedded) return null;
    return AppBar(
      title: const Text('Storage Analyzer'),
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: const Color(0xFF0F172A),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _loadStorage,
          tooltip: 'Refresh storage',
        ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _loadStorage();
  }

  Future<void> _loadStorage() async {
    await context.read<StorageProvider>().refreshStorage();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<StorageProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) {
          return Scaffold(
            appBar: _appBar(),
            body: const Center(child: CircularProgressIndicator()),
          );
        }

        final info = provider.storageInfo;

        return Scaffold(
          appBar: _appBar(),
          body: info.totalBytes == 0
              ? EmptyState(
                  icon: Icons.memory_rounded,
                  title: 'Storage Info Unavailable',
                  subtitle:
                      'Unable to read storage information. Please try again.',
                  onAction: _loadStorage,
                  actionLabel: 'Refresh',
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Usage summary
                      Row(
                        children: [
                          Expanded(
                            child: StorageCard(
                              title: 'Total Storage',
                              value: info.totalString,
                              subtitle: 'Total',
                              color: const Color(0xFF6366F1),
                              icon: Icons.storage_rounded,
                              progress: info.usedPercent / 100,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: StorageCard(
                              title: 'Used',
                              value: info.usedString,
                              subtitle:
                                  '${info.usedPercent.toStringAsFixed(0)}% used',
                              color: const Color(0xFFF59E0B),
                              icon: Icons.warning_rounded,
                              progress: info.usedPercent / 100,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: StorageCard(
                              title: 'Free Space',
                              value: info.freeString,
                              subtitle:
                                  '${info.freePercent.toStringAsFixed(0)}% free',
                              color: const Color(0xFF10B981),
                              icon: Icons.cloud_download_rounded,
                              progress: info.freePercent / 100,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: StatCard(
                              title: 'Photos',
                              value: info.photosString,
                              color: const Color(0xFFEC4899),
                              icon: Icons.photo_library_rounded,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),

                      // Donut chart
                      const Text(
                        'Storage Distribution',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 260,
                        child: PieChart(
                          PieChartData(
                            sections: [
                              PieChartSectionData(
                                color: const Color(0xFFEC4899),
                                value: info.photosBytes.toDouble(),
                                title:
                                    '${_percent(info.photosBytes, info.usedBytes)}%',
                                radius: 90,
                                titleStyle: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              PieChartSectionData(
                                color: const Color(0xFF6366F1),
                                value: info.videosBytes.toDouble(),
                                title:
                                    '${_percent(info.videosBytes, info.usedBytes)}%',
                                radius: 90,
                                titleStyle: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              PieChartSectionData(
                                color: const Color(0xFF10B981),
                                value: info.appsBytes.toDouble(),
                                title:
                                    '${_percent(info.appsBytes, info.usedBytes)}%',
                                radius: 90,
                                titleStyle: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              PieChartSectionData(
                                color: const Color(0xFF94A3B8),
                                value: info.othersBytes.toDouble(),
                                title:
                                    '${_percent(info.othersBytes, info.usedBytes)}%',
                                radius: 90,
                                titleStyle: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                            centerSpaceRadius: 40,
                            sectionsSpace: 4,
                            startDegreeOffset: -90,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Center(
                        child: Column(
                          children: [
                            Text(
                              info.usedString,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'of ${info.totalString} used',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),

                      // Breakdown list
                      const Text(
                        'Detailed Breakdown',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _BreakdownItem(
                        label: 'Photos',
                        value: info.photosString,
                        color: const Color(0xFFEC4899),
                        ratio: info.totalBytes > 0
                            ? info.photosBytes / info.totalBytes
                            : 0,
                      ),
                      _BreakdownItem(
                        label: 'Videos',
                        value: info.videosString,
                        color: const Color(0xFF6366F1),
                        ratio: info.totalBytes > 0
                            ? info.videosBytes / info.totalBytes
                            : 0,
                      ),
                      _BreakdownItem(
                        label: 'Applications',
                        value: info.appsString,
                        color: const Color(0xFF10B981),
                        ratio: info.totalBytes > 0
                            ? info.appsBytes / info.totalBytes
                            : 0,
                      ),
                      _BreakdownItem(
                        label: 'Other Files',
                        value: info.othersString,
                        color: const Color(0xFF94A3B8),
                        ratio: info.totalBytes > 0
                            ? info.othersBytes / info.totalBytes
                            : 0,
                      ),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
        );
      },
    );
  }

  int _percent(int part, int total) {
    if (total == 0) return 0;
    return ((part / total) * 100).round();
  }
}

class _BreakdownItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final double ratio;

  const _BreakdownItem({
    required this.label,
    required this.value,
    required this.color,
    required this.ratio,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF1F5F9)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(_getIcon(label), color: color, size: 20),
        ),
        title: Text(
          label,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Color(0xFF0F172A),
          ),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              width: 80,
              height: 6,
              decoration: BoxDecoration(
                color: const Color(0xFFE2E8F0),
                borderRadius: BorderRadius.circular(3),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: ratio.clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getIcon(String label) {
    switch (label.toLowerCase()) {
      case 'photos':
        return Icons.photo_library_rounded;
      case 'videos':
        return Icons.videocam_rounded;
      case 'applications':
        return Icons.apps_rounded;
      default:
        return Icons.folder_rounded;
    }
  }
}
