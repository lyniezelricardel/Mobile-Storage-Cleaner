import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/data_models.dart';
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<StorageProvider>().refreshStorage();
    });
  }

  Future<void> _loadStorage() =>
      context.read<StorageProvider>().refreshStorage();

  @override
  Widget build(BuildContext context) {
    return Consumer<StorageProvider>(
      builder: (context, provider, _) {
        final info = provider.storageInfo;
        return Scaffold(
          appBar: widget.embedded
              ? null
              : AppBar(
                  title: const Text('Storage Analyzer'),
                  actions: [
                    IconButton(
                      onPressed: _loadStorage,
                      icon: const Icon(Icons.refresh_rounded),
                      tooltip: 'Refresh storage',
                    ),
                  ],
                ),
          body: info.totalBytes == 0
              ? (provider.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : EmptyState(
                        icon: Icons.memory_rounded,
                        title: 'Storage Info Unavailable',
                        subtitle:
                            'Unable to read storage information. Please try again.',
                        onAction: _loadStorage,
                        actionLabel: 'Refresh',
                      ))
              : RefreshIndicator(
                  onRefresh: _loadStorage,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: StorageCard(
                                title: 'Total Storage',
                                value: info.totalString,
                                subtitle: 'Capacity',
                                color: context.colors.brand,
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
                                color: context.colors.amber,
                                icon: Icons.pie_chart_rounded,
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
                                color: context.colors.green,
                                icon: Icons.cloud_download_rounded,
                                progress: info.freePercent / 100,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: StatCard(
                                title: 'Photos',
                                value: info.photosString,
                                color: context.colors.pink,
                                icon: Icons.photo_library_rounded,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'Storage Distribution',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: context.colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
                            child: Column(
                              children: [
                                SizedBox(
                                  height: 230,
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      PieChart(
                                        PieChartData(
                                          sections: _sections(info),
                                          centerSpaceRadius: 58,
                                          sectionsSpace: 3,
                                          startDegreeOffset: -90,
                                          borderData: FlBorderData(show: false),
                                        ),
                                      ),
                                      IgnorePointer(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              info.freeString,
                                              style: TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: -0.5,
                                                color:
                                                    context.colors.textPrimary,
                                              ),
                                            ),
                                            Text(
                                              'free',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: context
                                                    .colors
                                                    .textSecondary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                _Legend(
                                  items: [
                                    _LegendItem(
                                      label: 'Photos',
                                      value: info.photosString,
                                      color: context.colors.pink,
                                    ),
                                    _LegendItem(
                                      label: 'Videos',
                                      value: info.videosString,
                                      color: context.colors.brand,
                                    ),
                                    _LegendItem(
                                      label: 'Apps',
                                      value: info.appsString,
                                      color: context.colors.green,
                                    ),
                                    _LegendItem(
                                      label: 'Other',
                                      value: info.othersString,
                                      color: context.colors.textMuted,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'Detailed Breakdown',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: context.colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _BreakdownItem(
                          label: 'Photos',
                          value: info.photosString,
                          color: context.colors.pink,
                          ratio: info.totalBytes > 0
                              ? info.photosBytes / info.totalBytes
                              : 0,
                        ),
                        _BreakdownItem(
                          label: 'Videos',
                          value: info.videosString,
                          color: context.colors.brand,
                          ratio: info.totalBytes > 0
                              ? info.videosBytes / info.totalBytes
                              : 0,
                        ),
                        _BreakdownItem(
                          label: 'Applications',
                          value: info.appsString,
                          color: context.colors.green,
                          ratio: info.totalBytes > 0
                              ? info.appsBytes / info.totalBytes
                              : 0,
                        ),
                        _BreakdownItem(
                          label: 'Other Files',
                          value: info.othersString,
                          color: context.colors.textMuted,
                          ratio: info.totalBytes > 0
                              ? info.othersBytes / info.totalBytes
                              : 0,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'App data is estimated because Android does not expose per-app storage without extra permissions.',
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.4,
                            color: context.colors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }

  List<PieChartSectionData> _sections(StorageInfo info) {
    final colors = context.colors;
    final entries = [
      (info.photosBytes, colors.pink),
      (info.videosBytes, colors.brand),
      (info.appsBytes, colors.green),
      (info.othersBytes, colors.textMuted),
    ];
    final total = entries.fold<int>(0, (sum, entry) => sum + entry.$1);
    if (total <= 0) return [];

    return entries
        .where((entry) => entry.$1 > 0)
        .map((entry) {
          final percent = (entry.$1 / total) * 100;
          return PieChartSectionData(
            color: entry.$2,
            value: entry.$1.toDouble(),
            title: percent >= 7 ? '${percent.round()}%' : '',
            radius: 54,
            titleStyle: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          );
        })
        .toList(growable: false);
  }
}

class _LegendItem {
  final String label;
  final String value;
  final Color color;

  const _LegendItem({
    required this.label,
    required this.value,
    required this.color,
  });
}

class _Legend extends StatelessWidget {
  final List<_LegendItem> items;

  const _Legend({required this.items});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Wrap(
      spacing: 18,
      runSpacing: 10,
      children: items
          .map((item) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: item.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  item.label,
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
                const SizedBox(width: 5),
                Text(
                  item.value,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ],
            );
          })
          .toList(growable: false),
    );
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
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(_getIcon(label), color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: ratio.clamp(0.0, 1.0),
                    backgroundColor: colors.cardAlt,
                    color: color,
                    minHeight: 5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
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
