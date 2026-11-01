import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/storage_provider.dart';
import '../widgets/ui_widgets.dart';
import '../screens/blurry_photos_screen.dart';
import '../screens/duplicate_photos_screen.dart';
import '../screens/storage_analyzer_screen.dart';

/// Main dashboard showing storage overview and quick access to all three features.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;

  final List<Widget> _screens = [
    const _DashboardHome(),
    const BlurryPhotosScreen(embedded: true),
    const DuplicatePhotosScreen(embedded: true),
    const StorageAnalyzerScreen(embedded: true),
  ];

  final List<String> _titles = [
    'Dashboard',
    'Blurry Photos',
    'Duplicates',
    'Storage',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<StorageProvider>().refreshStorage();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _titles[_selectedIndex],
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFF0F172A),
          ),
        ),
        centerTitle: false,
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: const Color(0xFF0F172A),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              context.read<StorageProvider>().refreshStorage();
            },
            tooltip: 'Refresh storage',
          ),
        ],
      ),
      body: _screens[_selectedIndex],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 12,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: (index) => setState(() => _selectedIndex = index),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.blur_on_rounded),
              label: 'Blurry',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.copy_rounded),
              label: 'Duplicates',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.memory_rounded),
              label: 'Storage',
            ),
          ],
        ),
      ),
    );
  }
}

/// Dashboard home with storage summary and feature buttons.
class _DashboardHome extends StatelessWidget {
  const _DashboardHome();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Text(
            'Storage Overview',
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Keep your phone clean and organized.',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 24),

          // Storage summary cards
          Consumer<StorageProvider>(
            builder: (context, storageProvider, child) {
              final info = storageProvider.storageInfo;
              return Row(
                children: [
                  Expanded(
                    child: StorageCard(
                      title: 'Total Storage',
                      value: info.totalString.isEmpty ? '—' : info.totalString,
                      subtitle: 'Total',
                      color: const Color(0xFF6366F1),
                      icon: Icons.storage_rounded,
                      progress: info.totalBytes > 0
                          ? info.usedPercent / 100
                          : 0.0,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: StorageCard(
                      title: 'Used',
                      value: info.usedString.isEmpty ? '—' : info.usedString,
                      subtitle: '${info.usedPercent.toStringAsFixed(0)}%',
                      color: const Color(0xFFF59E0B),
                      icon: Icons.warning_rounded,
                      progress: info.totalBytes > 0
                          ? info.usedPercent / 100
                          : 0.0,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Consumer<StorageProvider>(
            builder: (context, storageProvider, child) {
              final info = storageProvider.storageInfo;
              return Row(
                children: [
                  Expanded(
                    child: StorageCard(
                      title: 'Free Space',
                      value: info.freeString.isEmpty ? '—' : info.freeString,
                      subtitle: 'Free',
                      color: const Color(0xFF10B981),
                      icon: Icons.cloud_download_rounded,
                      progress: info.totalBytes > 0
                          ? info.freePercent / 100
                          : 0.0,
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
              );
            },
          ),
          const SizedBox(height: 32),

          // Quick actions
          const Text(
            'Quick Actions',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FeatureButton(
                  title: 'Blurry Photos',
                  subtitle: 'Find and remove blurry images',
                  icon: Icons.blur_on_rounded,
                  color: const Color(0xFF6366F1),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const BlurryPhotosScreen(),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FeatureButton(
                  title: 'Duplicates',
                  subtitle: 'Find and remove similar images',
                  icon: Icons.copy_rounded,
                  color: const Color(0xFFEC4899),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const DuplicatePhotosScreen(),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FeatureButton(
                  title: 'Storage Analyzer',
                  subtitle: 'Analyze storage usage breakdown',
                  icon: Icons.memory_rounded,
                  color: const Color(0xFF10B981),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const StorageAnalyzerScreen(),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FeatureButton(
                  title: 'Refresh Storage',
                  subtitle: 'Update storage information',
                  icon: Icons.refresh_rounded,
                  color: const Color(0xFF64748B),
                  onTap: () {
                    context.read<StorageProvider>().refreshStorage();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),

          // Storage breakdown chart section
          Consumer<StorageProvider>(
            builder: (context, storageProvider, child) {
              final info = storageProvider.storageInfo;
              if (info.totalBytes == 0) {
                return const SizedBox.shrink();
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Storage Breakdown',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          _breakdownRow(
                            'Photos',
                            info.photosString,
                            const Color(0xFFEC4899),
                            info.totalBytes > 0
                                ? info.photosBytes / info.totalBytes
                                : 0,
                          ),
                          const SizedBox(height: 12),
                          _breakdownRow(
                            'Videos',
                            info.videosString,
                            const Color(0xFF6366F1),
                            info.totalBytes > 0
                                ? info.videosBytes / info.totalBytes
                                : 0,
                          ),
                          const SizedBox(height: 12),
                          _breakdownRow(
                            'Apps',
                            info.appsString,
                            const Color(0xFF10B981),
                            info.totalBytes > 0
                                ? info.appsBytes / info.totalBytes
                                : 0,
                          ),
                          const SizedBox(height: 12),
                          _breakdownRow(
                            'Other Files',
                            info.othersString,
                            const Color(0xFF94A3B8),
                            info.totalBytes > 0
                                ? info.othersBytes / info.totalBytes
                                : 0,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _breakdownRow(String label, String value, Color color, double ratio) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF0F172A),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: ratio.clamp(0.0, 1.0),
            backgroundColor: const Color(0xFFE2E8F0),
            color: color,
            minHeight: 6,
          ),
        ),
      ],
    );
  }
}
