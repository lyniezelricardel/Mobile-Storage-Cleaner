import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/data_models.dart';
import '../providers/photo_provider.dart';
import '../utils/format_bytes.dart';
import '../widgets/ui_widgets.dart';

/// Screen showing duplicate photo groups detected from the gallery.
class DuplicatePhotosScreen extends StatefulWidget {
  final bool embedded;

  const DuplicatePhotosScreen({super.key, this.embedded = false});

  @override
  State<DuplicatePhotosScreen> createState() => _DuplicatePhotosScreenState();
}

class _DuplicatePhotosScreenState extends State<DuplicatePhotosScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<PhotoProvider>().scanPhotos();
    });
  }

  Future<void> _refresh() => context.read<PhotoProvider>().refreshGallery();

  Future<void> _rescanAll() => context.read<PhotoProvider>().rescanAll();

  int _selectedBytes(PhotoProvider provider) =>
      provider.selectedDuplicatePhotos.fold(0, (sum, p) => sum + p.fileSize);

  int _savableBytes(PhotoProvider provider) =>
      provider.duplicateGroups.fold(0, (sum, group) => sum + group.savableSize);

  @override
  Widget build(BuildContext context) {
    return Consumer<PhotoProvider>(
      builder: (context, provider, _) {
        final selectedCount = provider.selectedDuplicatePhotos.length;
        return Scaffold(
          appBar: widget.embedded
              ? null
              : AppBar(
                  title: Text(
                    selectedCount > 0
                        ? '$selectedCount selected'
                        : 'Duplicate Photos',
                  ),
                ),
          body: _buildBody(context, provider),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, PhotoProvider provider) {
    final colors = context.colors;
    final selectedCount = provider.selectedDuplicatePhotos.length;
    final selectedBytes = _selectedBytes(provider);

    if (provider.error != null && provider.photoCount == 0) {
      return EmptyState(
        icon: Icons.error_outline_rounded,
        title: 'Scan Error',
        subtitle: provider.error!,
        onAction: _refresh,
        actionLabel: 'Try Again',
      );
    }

    if (!provider.hasScanned) {
      return Center(
        child: ScanProgress(
          status: provider.scanStatus,
          progress: provider.scanProgress,
          total: provider.scanTotal,
          detail: provider.isScanning
              ? '${provider.scanProgress} of ${provider.scanTotal} photos analyzed'
              : 'Preparing your gallery…',
          hint: provider.isScanning
              ? 'Results are saved as they finish, so you can stop anytime.'
              : null,
          onCancel: provider.isScanning ? provider.cancelScan : null,
        ),
      );
    }

    return Column(
      children: [
        // Every slot above the list stays a SizedBox even when empty. Changing
        // the widget type here would make Flutter rebuild the rest of the
        // Column (including the ListView), which loses its scroll offset.
        SizedBox(
          child: provider.isScanning
              ? ScanBanner(
                  status: provider.scanStatus,
                  progress: provider.scanProgress,
                  total: provider.scanTotal,
                  onCancel: provider.cancelScan,
                )
              : null,
        ),
        SizedBox(
          child: provider.newPhotoCount > 0 && !provider.isScanning
              ? _NewPhotosBanner(
                  count: provider.newPhotoCount,
                  onAnalyze: _refresh,
                )
              : null,
        ),
        _Header(
          provider: provider,
          savableBytes: _savableBytes(provider),
          onRefresh: _refresh,
          onRescanAll: _rescanAll,
        ),
        SizedBox(
          child: selectedCount > 0
              ? _SelectionBanner(
                  count: selectedCount,
                  bytes: selectedBytes,
                  onDeselect: provider.deselectAllDuplicates,
                  onTrash: () => _confirmTrash(
                    context,
                    provider,
                    selectedCount,
                    selectedBytes,
                  ),
                )
              : null,
        ),
        Expanded(
          child: provider.duplicateGroups.isEmpty
              ? EmptyState(
                  icon: Icons.auto_awesome_rounded,
                  title: 'No Duplicates Found',
                  subtitle:
                      'Your gallery looks unique. Refresh after saving new photos.',
                  onAction: _refresh,
                  actionLabel: 'Refresh Gallery',
                )
              : ListView.builder(
                  key: const PageStorageKey<String>('duplicate-groups-list'),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: provider.duplicateGroups.length,
                  itemBuilder: (context, index) {
                    final group = provider.duplicateGroups[index];
                    return _GroupCard(
                      key: ValueKey(group.groupId),
                      group: group,
                      onToggle: (photoId) => provider.toggleDuplicateSelection(
                        group.groupId,
                        photoId,
                      ),
                      onSelectAllButOne: () =>
                          provider.selectAllButOneInGroup(group.groupId),
                      onCompare: () => _openCompare(context, group.groupId),
                    );
                  },
                ),
        ),
        SizedBox(
          child: selectedCount > 0
              ? SafeArea(
                  top: false,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
                    decoration: BoxDecoration(
                      color: colors.card,
                      border: Border(top: BorderSide(color: colors.border)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$selectedCount selected · ${formatBytes(selectedBytes)}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: () => _confirmTrash(
                            context,
                            provider,
                            selectedCount,
                            selectedBytes,
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: colors.red,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                          ),
                          icon: const Icon(
                            Icons.delete_sweep_outlined,
                            size: 18,
                          ),
                          label: const Text('Move to trash'),
                        ),
                      ],
                    ),
                  ),
                )
              : null,
        ),
      ],
    );
  }

  Future<void> _openCompare(BuildContext context, String groupId) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _CompareDialog(groupId: groupId),
    );
  }

  Future<void> _confirmTrash(
    BuildContext context,
    PhotoProvider provider,
    int selectedCount,
    int bytesToTrash,
  ) async {
    if (provider.selectedDuplicatePhotos.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    final colors = context.colors;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ConfirmationDialog(
        title: 'Move Duplicates to Trash?',
        content:
            "The selected copies will move to Android's system trash. Keep "
            'at least one copy if you still want the photo.',
        photoCount: selectedCount,
        detail:
            'About ${formatBytes(bytesToTrash)} stays in the trash for up to '
            '30 days.',
        note:
            'Space is only freed after Android empties the trash. Android '
            'will ask you to confirm.',
        confirmLabel: 'Move to trash',
        icon: Icons.delete_sweep_outlined,
        onConfirm: () => Navigator.of(dialogContext).pop(true),
        onCancel: () => Navigator.of(dialogContext).pop(false),
      ),
    );

    if (confirmed != true) return;

    final result = await provider.moveSelectedDuplicatePhotosToTrash();
    if (!mounted) return;

    if (result.error != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.error!,
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: colors.red,
        ),
      );
      return;
    }

    if (result.canceled) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Canceled — nothing was moved to the trash.'),
        ),
      );
      return;
    }

    final message = result.trashedCount < result.requestedCount
        ? 'Moved ${result.trashedCount} of ${result.requestedCount} photos to the trash'
        : 'Moved ${result.trashedCount} ${result.trashedCount == 1 ? 'copy' : 'copies'} to the trash';
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$message · restorable for about 30 days'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () =>
                _undoTrash(messenger, provider, result.trashedPhotos),
          ),
        ),
      );
  }

  Future<void> _undoTrash(
    ScaffoldMessengerState messenger,
    PhotoProvider provider,
    List<TrashedPhoto> photos,
  ) async {
    final result = await provider.restoreTrashedPhotos(photos);
    final message = result.error != null
        ? result.error!
        : result.canceled
        ? 'Restore canceled — the photos are still in the trash.'
        : 'Restored ${result.restoredCount} '
              '${result.restoredCount == 1 ? 'photo' : 'photos'} from the trash.';
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Header extends StatelessWidget {
  final PhotoProvider provider;
  final int savableBytes;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onRescanAll;

  const _Header({
    required this.provider,
    required this.savableBytes,
    required this.onRefresh,
    required this.onRescanAll,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${provider.duplicateGroupCount} ${provider.duplicateGroupCount == 1 ? 'group' : 'groups'} found',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${formatBytes(savableBytes)} in duplicate copies · ${provider.photoCount} photos scanned',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ],
            ),
          ),
          Badge(
            isLabelVisible: provider.newPhotoCount > 0,
            label: Text('${provider.newPhotoCount}'),
            child: IconButton(
              onPressed: provider.isScanning ? null : onRefresh,
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Check for new photos',
            ),
          ),
          PopupMenuButton<String>(
            enabled: !provider.isScanning,
            tooltip: 'Scan options',
            onSelected: (value) {
              if (value == 'refresh') {
                onRefresh();
              } else if (value == 'rescan') {
                onRescanAll();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'refresh',
                child: Text('Check for new photos'),
              ),
              PopupMenuItem(
                value: 'rescan',
                child: Text('Analyze everything again'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NewPhotosBanner extends StatelessWidget {
  final int count;
  final Future<void> Function() onAnalyze;

  const _NewPhotosBanner({required this.count, required this.onAnalyze});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: colors.green.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.green.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(Icons.auto_awesome_rounded, color: colors.green, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$count new ${count == 1 ? 'photo' : 'photos'} found — only these will be analyzed.',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: colors.textPrimary,
              ),
            ),
          ),
          TextButton(onPressed: onAnalyze, child: const Text('Analyze')),
        ],
      ),
    );
  }
}

class _SelectionBanner extends StatelessWidget {
  final int count;
  final int bytes;
  final VoidCallback onDeselect;
  final VoidCallback onTrash;

  const _SelectionBanner({
    required this.count,
    required this.bytes,
    required this.onDeselect,
    required this.onTrash,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: colors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.red.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.delete_sweep_outlined, color: colors.red, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$count selected · ${formatBytes(bytes)} to the trash',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: colors.red,
              ),
            ),
          ),
          IconButton(
            onPressed: onDeselect,
            icon: const Icon(Icons.close_rounded, size: 18),
            color: colors.red,
            tooltip: 'Deselect all',
            visualDensity: VisualDensity.compact,
          ),
          TextButton(
            onPressed: onTrash,
            style: TextButton.styleFrom(foregroundColor: colors.red),
            child: const Text('Move'),
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final DuplicateGroup group;
  final ValueChanged<String> onToggle;
  final VoidCallback onSelectAllButOne;
  final VoidCallback onCompare;

  const _GroupCard({
    super.key,
    required this.group,
    required this.onToggle,
    required this.onSelectAllButOne,
    required this.onCompare,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final selectedCount = group.selectedCount;
    final bestPhoto = group.bestPhoto;
    final orderedPhotos = group.photosBestFirst;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (group.isExactDuplicate ? colors.red : colors.brand)
                        .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    group.isExactDuplicate
                        ? Icons.copy_all_rounded
                        : Icons.compare_rounded,
                    color: group.isExactDuplicate ? colors.red : colors.brand,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.isExactDuplicate
                            ? 'Exact Duplicates'
                            : 'Visually Similar',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${group.photos.length} photos · up to ${formatBytes(group.savableSize)} savable',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onCompare,
                  icon: const Icon(Icons.visibility_rounded, size: 20),
                  tooltip: 'Compare side by side',
                ),
              ],
            ),
          ),
          SizedBox(
            height: 178,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              itemCount: orderedPhotos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final photo = orderedPhotos[index];
                return _PhotoTile(
                  photo: photo,
                  isSelected: photo.isSelected,
                  isBest: photo.id == bestPhoto.id,
                  onTap: () => onToggle(photo.id),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onSelectAllButOne,
                    icon: const Icon(Icons.done_all_rounded, size: 16),
                    label: const Text('Keep best, select rest'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  selectedCount > 0 ? '$selectedCount marked' : 'None marked',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: selectedCount > 0 ? colors.red : colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompareDialog extends StatelessWidget {
  final String groupId;

  const _CompareDialog({required this.groupId});

  DuplicateGroup? _findGroup(PhotoProvider provider) {
    for (final group in provider.duplicateGroups) {
      if (group.groupId == groupId) return group;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Dialog(
      insetPadding: const EdgeInsets.all(14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.74,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Consumer<PhotoProvider>(
              builder: (context, provider, _) {
                final group = _findGroup(provider);
                if (group == null) {
                  return Center(
                    child: Text(
                      'These photos are no longer available.',
                      style: TextStyle(color: colors.textSecondary),
                    ),
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Compare Photos',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    Text(
                      'Tap a photo to mark it for deletion. Keep at least one copy.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final tileWidth = (constraints.maxWidth - 12) / 2;
                          final orderedPhotos = group.photosBestFirst;
                          return ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: orderedPhotos.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 12),
                            itemBuilder: (context, index) {
                              final photo = orderedPhotos[index];
                              return SizedBox(
                                width: tileWidth,
                                child: _CompareTile(
                                  photo: photo,
                                  isSelected: photo.isSelected,
                                  isBest: photo.id == group.bestPhoto.id,
                                  onTap: () =>
                                      provider.toggleDuplicateSelection(
                                        group.groupId,
                                        photo.id,
                                      ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${group.selectedCount} marked for deletion',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: group.selectedCount > 0
                                  ? colors.red
                                  : colors.textSecondary,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: provider.deselectAllDuplicates,
                          child: const Text('Deselect all'),
                        ),
                        const SizedBox(width: 4),
                        ElevatedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Done'),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _CompareTile extends StatelessWidget {
  final PhotoModel photo;
  final bool isSelected;
  final bool isBest;
  final VoidCallback onTap;

  const _CompareTile({
    required this.photo,
    required this.isSelected,
    required this.isBest,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: colors.cardAlt,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? colors.red : colors.border,
            width: isSelected ? 2.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(14),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Ambient copy fills the letterbox area behind the photo.
                    Opacity(
                      opacity: 0.16,
                      child: Image.file(
                        File(photo.path),
                        fit: BoxFit.cover,
                        cacheWidth: 240,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                    Image.file(
                      File(photo.path),
                      fit: BoxFit.contain,
                      cacheWidth: 720,
                      errorBuilder: (context, error, stackTrace) => Center(
                        child: Icon(
                          Icons.image_not_supported_rounded,
                          color: colors.textMuted,
                          size: 36,
                        ),
                      ),
                    ),
                    if (isBest)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: colors.green.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'BEST',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected ? colors.red : colors.card,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isSelected ? colors.red : colors.border,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isSelected
                                  ? Icons.delete_sweep_outlined
                                  : Icons.check_rounded,
                              size: 13,
                              color: isSelected
                                  ? Colors.white
                                  : colors.textSecondary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              isSelected ? 'Trash' : 'Keep',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: isSelected
                                    ? Colors.white
                                    : colors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _fileName(photo.path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${photo.sizeString} · ${_dateLabel(photo.dateTaken)}',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fileName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty || parts.last.isEmpty ? 'Photo' : parts.last;
  }

  String _dateLabel(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

class _PhotoTile extends StatelessWidget {
  final PhotoModel photo;
  final bool isSelected;
  final bool isBest;
  final VoidCallback onTap;

  const _PhotoTile({
    required this.photo,
    required this.isSelected,
    required this.isBest,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 132,
        decoration: BoxDecoration(
          color: colors.cardAlt,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? colors.red : colors.border,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(13),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(
                      File(photo.path),
                      fit: BoxFit.cover,
                      cacheWidth: 360,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: colors.cardAlt,
                        child: Icon(
                          Icons.image_not_supported_rounded,
                          color: colors.textMuted,
                          size: 28,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isBest
                              ? colors.green.withValues(alpha: 0.92)
                              : Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          isBest ? 'BEST' : 'COPY',
                          style: const TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: isSelected ? colors.red : Colors.black45,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: isSelected
                            ? const Icon(
                                Icons.delete_sweep_outlined,
                                size: 14,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      photo.sizeString,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  Text(
                    isSelected ? 'Trash' : 'Keep',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: isSelected ? colors.red : colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
