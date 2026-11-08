import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/data_models.dart';
import '../providers/photo_provider.dart';
import '../providers/storage_provider.dart';
import '../providers/theme_provider.dart';
import '../utils/format_bytes.dart';
import '../widgets/ui_widgets.dart';
import 'blurry_photos_screen.dart';
import 'duplicate_photos_screen.dart';
import 'storage_analyzer_screen.dart';
import 'trash_screen.dart';

/// Main dashboard showing storage overview and quick access to all three features.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;
  late final List<Widget> _screens;

  static const _titles = [
    'Dashboard',
    'Blurry Photos',
    'Duplicates',
    'Storage',
  ];

  @override
  void initState() {
    super.initState();
    _screens = [
      _DashboardHome(onOpenTab: _openTab, onOpenTrash: _openTrash),
      const BlurryPhotosScreen(embedded: true),
      const DuplicatePhotosScreen(embedded: true),
      const StorageAnalyzerScreen(embedded: true),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<StorageProvider>().refreshStorage();
      context.read<PhotoProvider>().scanPhotos();
    });
  }

  void _openTab(int index) {
    if (index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
  }

  Future<void> _openTrash() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const TrashScreen()));
    if (!mounted) return;
    await context.read<StorageProvider>().refreshStorage();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_selectedIndex]),
        actions: [
          Consumer<PhotoProvider>(
            builder: (context, photos, _) {
              return Badge(
                isLabelVisible: photos.trashCount > 0,
                label: Text('${photos.trashCount}'),
                child: IconButton(
                  onPressed: _openTrash,
                  icon: const Icon(Icons.restore_from_trash_rounded),
                  tooltip: 'Recently Deleted',
                ),
              );
            },
          ),
          IconButton(
            onPressed: () {
              context.read<StorageProvider>().refreshStorage();
              context.read<PhotoProvider>().checkForNewPhotos();
            },
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh storage',
          ),
          _ThemeMenu(provider: themeProvider),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: Consumer<PhotoProvider>(
            builder: (context, photos, _) {
              if (!photos.isScanning) return const SizedBox(height: 3);
              return LinearProgressIndicator(
                value: photos.scanTotal > 0 ? photos.scanPercent : null,
                minHeight: 3,
                backgroundColor: Colors.transparent,
              );
            },
          ),
        ),
      ),
      body: IndexedStack(index: _selectedIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _openTab,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.blur_on_outlined),
            selectedIcon: Icon(Icons.blur_on_rounded),
            label: 'Blurry',
          ),
          NavigationDestination(
            icon: Icon(Icons.copy_outlined),
            selectedIcon: Icon(Icons.copy_rounded),
            label: 'Duplicates',
          ),
          NavigationDestination(
            icon: Icon(Icons.memory_outlined),
            selectedIcon: Icon(Icons.memory_rounded),
            label: 'Storage',
          ),
        ],
      ),
    );
  }
}

class _ThemeMenu extends StatelessWidget {
  final ThemeProvider provider;

  const _ThemeMenu({required this.provider});

  @override
  Widget build(BuildContext context) {
    final icon = switch (provider.themeMode) {
      ThemeMode.light => Icons.light_mode_rounded,
      ThemeMode.dark => Icons.dark_mode_rounded,
      ThemeMode.system => Icons.brightness_auto_rounded,
    };

    return PopupMenuButton<ThemeMode>(
      tooltip: 'Appearance',
      icon: Icon(icon),
      onSelected: provider.setThemeMode,
      itemBuilder: (context) => [
        _item(ThemeMode.system, Icons.brightness_auto_rounded, 'System'),
        _item(ThemeMode.light, Icons.light_mode_rounded, 'Light'),
        _item(ThemeMode.dark, Icons.dark_mode_rounded, 'Dark'),
      ],
    );
  }

  PopupMenuItem<ThemeMode> _item(ThemeMode mode, IconData icon, String label) {
    final selected = provider.themeMode == mode;
    return PopupMenuItem(
      value: mode,
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Text(label),
          const Spacer(),
          if (selected) const Icon(Icons.check_rounded, size: 18),
        ],
      ),
    );
  }
}

/// Dashboard home with storage summary and feature buttons.
class _DashboardHome extends StatelessWidget {
  final ValueChanged<int> onOpenTab;
  final Future<void> Function() onOpenTrash;

  const _DashboardHome({required this.onOpenTab, required this.onOpenTrash});

  @override
  Widget build(BuildContext context) {
    return Consumer2<StorageProvider, PhotoProvider>(
      builder: (context, storageProvider, photos, _) {
        final info = storageProvider.storageInfo;
        final colors = context.colors;

        return RefreshIndicator(
          onRefresh: () async {
            await Future.wait([
              storageProvider.refreshStorage(),
              photos.refreshGallery(),
            ]);
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _StorageHero(info: info),
                const SizedBox(height: 18),
                _GalleryStatusCard(
                  photos: photos,
                  onRefresh: photos.refreshGallery,
                  onRescanAll: photos.rescanAll,
                ),
                if (photos.trashCount > 0) ...[
                  const SizedBox(height: 12),
                  _RecentlyDeletedCard(photos: photos, onTap: onOpenTrash),
                ],
                const SizedBox(height: 24),
                Text(
                  'Quick Actions',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: FeatureButton(
                        title: 'Blurry Photos',
                        subtitle: 'Find soft and out-of-focus shots',
                        icon: Icons.blur_on_rounded,
                        color: colors.brand,
                        badge: '${photos.blurryCount}',
                        onTap: () => onOpenTab(1),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FeatureButton(
                        title: 'Duplicates',
                        subtitle: 'Review copies side by side',
                        icon: Icons.copy_rounded,
                        color: colors.pink,
                        badge: '${photos.duplicateGroupCount}',
                        onTap: () => onOpenTab(2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: FeatureButton(
                        title: 'Storage',
                        subtitle: 'See what is using your space',
                        icon: Icons.memory_rounded,
                        color: colors.green,
                        onTap: () => onOpenTab(3),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FeatureButton(
                        title: 'Refresh Gallery',
                        subtitle: 'Analyze only new photos',
                        icon: Icons.refresh_rounded,
                        color: colors.amber,
                        badge: photos.newPhotoCount > 0
                            ? '${photos.newPhotoCount}'
                            : null,
                        onTap: photos.refreshGallery,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: StorageCard(
                        title: 'Total Storage',
                        value: info.totalString.isEmpty
                            ? '—'
                            : info.totalString,
                        subtitle: 'Capacity',
                        color: colors.brand,
                        icon: Icons.storage_rounded,
                        progress: info.totalBytes > 0
                            ? info.usedPercent / 100
                            : 0,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: StorageCard(
                        title: 'Free Space',
                        value: info.freeString.isEmpty ? '—' : info.freeString,
                        subtitle:
                            '${info.freePercent.toStringAsFixed(0)}% free',
                        color: colors.green,
                        icon: Icons.cloud_download_rounded,
                        progress: info.totalBytes > 0
                            ? info.freePercent / 100
                            : 0,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  'Storage Breakdown',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        _BreakdownRow(
                          label: 'Photos',
                          value: info.photosString,
                          color: colors.pink,
                          ratio: info.totalBytes > 0
                              ? info.photosBytes / info.totalBytes
                              : 0,
                        ),
                        const SizedBox(height: 14),
                        _BreakdownRow(
                          label: 'Videos',
                          value: info.videosString,
                          color: colors.brand,
                          ratio: info.totalBytes > 0
                              ? info.videosBytes / info.totalBytes
                              : 0,
                        ),
                        const SizedBox(height: 14),
                        _BreakdownRow(
                          label: 'Apps',
                          value: info.appsString,
                          color: colors.green,
                          ratio: info.totalBytes > 0
                              ? info.appsBytes / info.totalBytes
                              : 0,
                        ),
                        const SizedBox(height: 14),
                        _BreakdownRow(
                          label: 'Other Files',
                          value: info.othersString,
                          color: colors.textMuted,
                          ratio: info.totalBytes > 0
                              ? info.othersBytes / info.totalBytes
                              : 0,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 14,
                      color: colors.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Scanning and Smart Enhance stay on this device. AI '
                        'Enhance uploads only after you confirm.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: colors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RecentlyDeletedCard extends StatelessWidget {
  final PhotoProvider photos;
  final Future<void> Function() onTap;

  const _RecentlyDeletedCard({required this.photos, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final count = photos.trashCount;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.amber.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.restore_from_trash_rounded,
                  color: colors.amber,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Recently Deleted',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$count ${count == 1 ? 'photo' : 'photos'} · '
                      '${formatBytes(photos.trashBytes)} · restorable for '
                      'about 30 days',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _StorageHero extends StatelessWidget {
  final StorageInfo info;

  const _StorageHero({required this.info});

  @override
  Widget build(BuildContext context) {
    final usedPercent = info.totalBytes > 0
        ? (info.usedPercent / 100).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF6366F1), Color(0xFF8B5CF6), Color(0xFFEC4899)],
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6366F1).withValues(alpha: 0.32),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.smartphone_rounded,
                color: Colors.white70,
                size: 16,
              ),
              const SizedBox(width: 6),
              const Text(
                'THIS DEVICE',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: Colors.white70,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${(usedPercent * 100).toStringAsFixed(0)}% used',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            info.freeString.isEmpty ? '—' : info.freeString,
            style: const TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.4,
              height: 1,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'free of ${info.totalString}',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 18),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: usedPercent,
              minHeight: 8,
              backgroundColor: Colors.white.withValues(alpha: 0.22),
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _HeroStat(label: 'Used', value: info.usedString),
              const SizedBox(width: 28),
              _HeroStat(label: 'Photos', value: info.photosString),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  final String label;
  final String value;

  const _HeroStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            color: Colors.white60,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}

class _GalleryStatusCard extends StatelessWidget {
  final PhotoProvider photos;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onRescanAll;

  const _GalleryStatusCard({
    required this.photos,
    required this.onRefresh,
    required this.onRescanAll,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final scanning = photos.isScanning;
    final newCount = photos.newPhotoCount;

    final title = scanning
        ? 'Analyzing your gallery'
        : newCount > 0
        ? '$newCount new ${newCount == 1 ? 'photo' : 'photos'} ready'
        : photos.hasScanned
        ? 'Gallery up to date'
        : 'Preparing your gallery';

    final subtitle = scanning
        ? photos.scanStatus
        : newCount > 0
        ? 'Only new or changed photos will be analyzed.'
        : photos.hasScanned
        ? '${photos.photoCount} photos indexed · ${photos.blurryCount} blurry · ${photos.duplicateGroupCount} duplicate groups'
        : 'Photo access is needed to find blurry and duplicate images.';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colors.brand.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    scanning
                        ? Icons.auto_awesome_rounded
                        : Icons.photo_library_rounded,
                    color: colors.brand,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!scanning)
                  TextButton(
                    onPressed: newCount > 0 ? onRefresh : onRescanAll,
                    child: Text(newCount > 0 ? 'Analyze' : 'Check'),
                  ),
              ],
            ),
            if (scanning) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: photos.scanTotal > 0 ? photos.scanPercent : null,
                  minHeight: 6,
                  backgroundColor: colors.cardAlt,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      photos.scanTotal > 0
                          ? '${photos.scanProgress} of ${photos.scanTotal} photos'
                          : 'Checking your gallery…',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  if (photos.estimatedRemaining != null)
                    Text(
                      '~${_eta(photos.estimatedRemaining!)} left',
                      style: TextStyle(fontSize: 11.5, color: colors.textMuted),
                    ),
                  TextButton(
                    onPressed: photos.cancelScan,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.only(left: 12),
                      minimumSize: const Size(0, 30),
                    ),
                    child: const Text('Stop', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
            if (photos.error != null && !scanning) ...[
              const SizedBox(height: 12),
              Text(
                photos.error!,
                style: TextStyle(fontSize: 12, color: colors.red),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _eta(Duration duration) {
    if (duration.inSeconds < 60) return '${duration.inSeconds}s';
    final minutes = duration.inMinutes;
    if (minutes < 60) return '${minutes}m';
    return '${duration.inHours}h';
  }
}

class _BreakdownRow extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final double ratio;

  const _BreakdownRow({
    required this.label,
    required this.value,
    required this.color,
    required this.ratio,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: ratio.clamp(0.0, 1.0),
            backgroundColor: colors.cardAlt,
            color: color,
            minHeight: 6,
          ),
        ),
      ],
    );
  }
}
