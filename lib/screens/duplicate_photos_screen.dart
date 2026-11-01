import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/data_models.dart';
import '../providers/photo_provider.dart';
import '../providers/storage_provider.dart';
import '../widgets/ui_widgets.dart';

/// Screen showing duplicate photo groups detected from the gallery.
class DuplicatePhotosScreen extends StatefulWidget {
  final bool embedded;

  const DuplicatePhotosScreen({super.key, this.embedded = false});

  @override
  State<DuplicatePhotosScreen> createState() => _DuplicatePhotosScreenState();
}

class _DuplicatePhotosScreenState extends State<DuplicatePhotosScreen> {
  PreferredSizeWidget? _appBar(String title, {List<Widget>? actions}) {
    if (widget.embedded) return null;
    return AppBar(
      title: Text(title),
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: const Color(0xFF0F172A),
      actions: actions,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    final provider = context.read<PhotoProvider>();
    await provider.scanPhotos();
  }

  Future<void> _refresh() async {
    final provider = context.read<PhotoProvider>();
    await provider.rescan();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PhotoProvider>(
      builder: (context, provider, child) {
        if (provider.isScanning) {
          return Scaffold(
            appBar: _appBar('Finding Duplicates'),
            body: Center(
              child: ScanProgress(
                status: provider.scanStatus,
                progress: provider.scanProgress,
                total: provider.scanTotal,
              ),
            ),
            floatingActionButton: FloatingActionButton(
              onPressed: _refresh,
              child: const Icon(Icons.refresh_rounded),
            ),
          );
        }

        if (provider.error != null) {
          return Scaffold(
            appBar: _appBar('Duplicates'),
            body: EmptyState(
              icon: Icons.error_outline_rounded,
              title: 'Scan Error',
              subtitle: provider.error!,
              onAction: _refresh,
              actionLabel: 'Try Again',
            ),
            floatingActionButton: FloatingActionButton(
              onPressed: _refresh,
              child: const Icon(Icons.refresh_rounded),
            ),
          );
        }

        if (provider.duplicateGroups.isEmpty) {
          return Scaffold(
            appBar: _appBar('Duplicates'),
            body: EmptyState(
              icon: Icons.auto_awesome_rounded,
              title: 'No Duplicates Found',
              subtitle:
                  'Your gallery looks unique! Run a new scan to check again.',
              onAction: _refresh,
              actionLabel: 'Scan Again',
            ),
            floatingActionButton: FloatingActionButton(
              onPressed: _refresh,
              child: const Icon(Icons.refresh_rounded),
            ),
          );
        }

        final selectedCount = provider.selectedDuplicatePhotos.length;
        final freedBytes = provider.totalSelectedSize;

        return Scaffold(
          appBar: _appBar(
            selectedCount > 0 ? '$selectedCount selected' : 'Duplicate Photos',
            actions: [
              if (selectedCount > 0)
                TextButton(
                  onPressed: provider.deselectAllDuplicates,
                  child: const Text('Deselect all'),
                ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _refresh,
                tooltip: 'Rescan',
              ),
            ],
          ),
          body: Column(
            children: [
              if (selectedCount > 0)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  color: const Color(0xFFFEF2F2),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.delete_outline_rounded,
                        color: Color(0xFFEF4444),
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Delete $selectedCount selected duplicate(s) to free ${_formatBytes(freedBytes)}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFEF4444),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: provider.deselectAllDuplicates,
                        icon: const Icon(Icons.close_rounded, size: 18),
                        color: const Color(0xFFEF4444),
                        tooltip: 'Deselect all',
                        visualDensity: VisualDensity.compact,
                      ),
                      TextButton(
                        onPressed: () => _confirmDelete(
                          context,
                          provider,
                          selectedCount,
                          freedBytes,
                        ),
                        child: const Text(
                          'Delete',
                          style: TextStyle(
                            color: Color(0xFFEF4444),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: provider.duplicateGroups.length,
                  itemBuilder: (context, groupIndex) {
                    final group = provider.duplicateGroups[groupIndex];
                    return _DuplicateGroupCard(
                      group: group,
                      onToggle: (photoId) => provider.toggleDuplicateSelection(
                        group.groupId,
                        photoId,
                      ),
                      onSelectAllButOne: () =>
                          provider.selectAllButOneInGroup(group.groupId),
                    );
                  },
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: _refresh,
            child: const Icon(Icons.refresh_rounded),
          ),
        );
      },
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    PhotoProvider provider,
    int selectedCount,
    int bytesFreed,
  ) async {
    final selected = provider.selectedDuplicatePhotos;
    if (selected.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    final storageProvider = context.read<StorageProvider>();

    bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ConfirmationDialog(
        title: 'Delete Duplicate Photos?',
        content:
            'This will permanently delete $selectedCount selected duplicate photo(s). This action cannot be undone.',
        photoCount: selectedCount,
        bytesFreed: bytesFreed,
        onConfirm: () => Navigator.of(context).pop(true),
        onCancel: () => Navigator.of(context).pop(false),
      ),
    );

    if (confirmed == true) {
      final freed = await provider.deleteSelectedDuplicatePhotos();
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Deleted $selectedCount duplicate(s). Freed ${_formatBytes(freed)}',
          ),
          backgroundColor: const Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
      storageProvider.updateAfterDeletion(freed);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else {
      return '$bytes B';
    }
  }
}

/// Card showing a group of duplicate/similar photos side by side.
class _DuplicateGroupCard extends StatelessWidget {
  final DuplicateGroup group;
  final ValueChanged<String> onToggle;
  final VoidCallback onSelectAllButOne;

  const _DuplicateGroupCard({
    required this.group,
    required this.onToggle,
    required this.onSelectAllButOne,
  });

  @override
  Widget build(BuildContext context) {
    final selectedCount = group.selectedCount;
    final savableBytes = group.savableSize;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 1,
      shadowColor: Colors.black.withValues(alpha: 0.05),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Group header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: group.isExactDuplicate
                        ? const Color(0xFFEF4444).withValues(alpha: 0.1)
                        : const Color(0xFF6366F1).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    group.isExactDuplicate
                        ? Icons.copy_rounded
                        : Icons.compare_rounded,
                    color: group.isExactDuplicate
                        ? const Color(0xFFEF4444)
                        : const Color(0xFF6366F1),
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
                            : 'Similar Photos Group',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${group.photos.length} photos • ${_formatBytes(savableBytes)} can be freed',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
                if (selectedCount > 0)
                  TextButton(
                    onPressed: onSelectAllButOne,
                    child: const Text(
                      'Keep one',
                      style: TextStyle(
                        color: Color(0xFF6366F1),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Photos row
          SizedBox(
            height: 160,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: group.photos.length,
              itemBuilder: (context, index) {
                final photo = group.photos[index];
                final isSelected = photo.isSelected;
                final isLast = index == group.photos.length - 1;

                return GestureDetector(
                  onTap: () => onToggle(photo.id),
                  child: Container(
                    width: 130,
                    margin: EdgeInsets.only(right: isLast ? 0 : 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF6366F1)
                            : const Color(0xFFE2E8F0),
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
                            child: Image.file(
                              File(photo.path),
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                              errorBuilder: (context, error, stackTrace) {
                                return Container(
                                  color: const Color(0xFFF1F5F9),
                                  child: Icon(
                                    Icons.image_not_supported_rounded,
                                    color: const Color(0xFF94A3B8),
                                    size: 28,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 22,
                                    height: 22,
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? const Color(0xFF6366F1)
                                          : Colors.white,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isSelected
                                            ? const Color(0xFF6366F1)
                                            : const Color(0xFF94A3B8),
                                        width: 2,
                                      ),
                                    ),
                                    child: isSelected
                                        ? const Icon(
                                            Icons.check_circle,
                                            color: Colors.white,
                                            size: 16,
                                          )
                                        : null,
                                  ),
                                  const Spacer(),
                                  Text(
                                    photo.sizeString,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                      color: Color(0xFF64748B),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          // Divider + select all
          if (group.photos.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onSelectAllButOne,
                      icon: const Icon(Icons.select_all_rounded, size: 16),
                      label: const Text('Select all but one'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF6366F1),
                        side: const BorderSide(color: Color(0xFF6366F1)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        minimumSize: Size.zero,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else {
      return '$bytes B';
    }
  }
}
