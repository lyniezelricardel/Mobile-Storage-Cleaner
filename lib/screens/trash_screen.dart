import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/data_models.dart';
import '../providers/photo_provider.dart';
import '../utils/format_bytes.dart';
import '../widgets/ui_widgets.dart';

/// Shows photos that currently sit in Android's system trash.
///
/// Android hides trashed files from normal gallery queries, so this screen
/// uses the locally cached list. Restoring hands the ids back to MediaStore,
/// which shows its own confirmation.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  final Set<String> _selected = {};
  bool _busy = false;
  String _busyMessage = 'Restoring photos…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<PhotoProvider>().refreshTrash();
    });
  }

  Future<void> _restore(
    PhotoProvider provider,
    List<TrashedPhoto> photos, {
    required String emptyMessage,
  }) async {
    if (photos.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _busyMessage = 'Restoring photos…';
    });

    final messenger = ScaffoldMessenger.of(context);
    final result = await provider.restoreTrashedPhotos(photos);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.restoredCount > 0) {
        _selected.removeAll(photos.map((photo) => photo.id));
      }
    });

    if (result.error != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.error!,
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: context.colors.red,
        ),
      );
      return;
    }

    if (result.canceled) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Restore canceled — nothing changed.')),
      );
      return;
    }

    final message = result.restoredCount == 0
        ? emptyMessage
        : 'Restored ${result.restoredCount} '
              '${result.restoredCount == 1 ? 'photo' : 'photos'} to your gallery.';
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _restoreSelected(
    PhotoProvider provider,
    List<TrashedPhoto> photos,
  ) async {
    final selected = photos
        .where((photo) => _selected.contains(photo.id))
        .toList(growable: false);
    if (selected.isEmpty) return;
    await _restore(
      provider,
      selected,
      emptyMessage: 'These photos have already left the trash.',
    );
  }

  Future<void> _confirmRestoreAll(
    PhotoProvider provider,
    List<TrashedPhoto> photos,
  ) async {
    if (photos.isEmpty || _busy) return;
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ConfirmationDialog(
        title: 'Restore All Photos?',
        content:
            'Every photo in Recently Deleted will return to your gallery. '
            'Nothing is removed.',
        photoCount: photos.length,
        detail:
            '${formatBytes(provider.trashBytes)} will leave the trash and '
            'become visible again.',
        note: 'Android will ask you to confirm.',
        confirmLabel: 'Restore all',
        icon: Icons.restore_rounded,
        accent: colors.green,
        onConfirm: () => Navigator.of(dialogContext).pop(true),
        onCancel: () => Navigator.of(dialogContext).pop(false),
      ),
    );
    if (confirmed != true) return;
    await _restore(
      provider,
      photos,
      emptyMessage: 'These photos have already left the trash.',
    );
  }

  Future<void> _deleteForever(
    PhotoProvider provider,
    List<TrashedPhoto> photos, {
    required String emptyMessage,
  }) async {
    if (photos.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _busyMessage = 'Deleting photos…';
    });

    final messenger = ScaffoldMessenger.of(context);
    final result = await provider.permanentlyDeleteTrashedPhotos(photos);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selected.removeAll(result.deletedPhotos.map((photo) => photo.id));
    });

    if (result.error != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.error!,
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: context.colors.red,
        ),
      );
      return;
    }

    if (result.canceled) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Delete canceled — nothing was removed.')),
      );
      return;
    }

    if (result.deletedCount == 0) {
      messenger.showSnackBar(SnackBar(content: Text(emptyMessage)));
      return;
    }

    final count = result.deletedCount;
    final message = result.partial
        ? 'Permanently deleted $count of ${result.requestedCount} photos · '
              '${formatBytes(result.deletedBytes)} freed.'
        : 'Permanently deleted $count '
              '${count == 1 ? 'photo' : 'photos'} · '
              '${formatBytes(result.deletedBytes)} freed.';
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmDeleteSelected(
    PhotoProvider provider,
    List<TrashedPhoto> photos,
  ) async {
    final selected = photos
        .where((photo) => _selected.contains(photo.id))
        .toList(growable: false);
    if (selected.isEmpty || _busy) return;
    final colors = context.colors;
    final bytes = selected.fold<int>(0, (sum, photo) => sum + photo.fileSize);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ConfirmationDialog(
        title: 'Delete Forever?',
        content:
            'These photos will be permanently removed from the trash and '
            'your gallery. This cannot be undone.',
        photoCount: selected.length,
        detail: '${formatBytes(bytes)} will be freed on this device.',
        note: 'Android will ask you to confirm again.',
        confirmLabel: 'Delete forever',
        icon: Icons.delete_forever_rounded,
        accent: colors.red,
        onConfirm: () => Navigator.of(dialogContext).pop(true),
        onCancel: () => Navigator.of(dialogContext).pop(false),
      ),
    );
    if (confirmed != true) return;
    await _deleteForever(
      provider,
      selected,
      emptyMessage: 'These photos have already left the trash.',
    );
  }

  Future<void> _confirmEmptyTrash(
    PhotoProvider provider,
    List<TrashedPhoto> photos,
  ) async {
    if (photos.isEmpty || _busy) return;
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ConfirmationDialog(
        title: 'Empty Trash?',
        content:
            'All photos in Recently Deleted will be permanently removed from '
            'the trash and your gallery. This cannot be undone.',
        photoCount: photos.length,
        detail:
            '${formatBytes(provider.trashBytes)} will be freed on this device.',
        note: 'Android will ask you to confirm again.',
        confirmLabel: 'Empty trash',
        icon: Icons.delete_forever_rounded,
        accent: colors.red,
        onConfirm: () => Navigator.of(dialogContext).pop(true),
        onCancel: () => Navigator.of(dialogContext).pop(false),
      ),
    );
    if (confirmed != true) return;
    await _deleteForever(
      provider,
      photos,
      emptyMessage: 'These photos have already left the trash.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PhotoProvider>(
      builder: (context, provider, _) {
        final photos = provider.trashedPhotos;
        final ids = photos.map((photo) => photo.id).toSet();
        final selectedPhotos = photos
            .where((photo) => _selected.contains(photo.id))
            .toList(growable: false);
        final allSelected =
            photos.isNotEmpty && selectedPhotos.length == photos.length;

        return Scaffold(
          appBar: AppBar(
            title: Text(
              photos.isEmpty
                  ? 'Recently Deleted'
                  : 'Recently Deleted (${photos.length})',
            ),
            actions: [
              if (photos.isNotEmpty)
                IconButton(
                  onPressed: _busy
                      ? null
                      : () => _confirmRestoreAll(provider, photos),
                  icon: const Icon(Icons.restore_rounded),
                  tooltip: 'Restore all',
                ),
              if (photos.isNotEmpty)
                IconButton(
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() {
                            if (allSelected) {
                              _selected.clear();
                            } else {
                              _selected
                                ..clear()
                                ..addAll(ids);
                            }
                          });
                        },
                  icon: Icon(
                    allSelected
                        ? Icons.deselect_rounded
                        : Icons.select_all_rounded,
                  ),
                  tooltip: allSelected ? 'Deselect all' : 'Select all',
                ),
              const SizedBox(width: 4),
            ],
          ),
          body: _busy
              ? _BusyBody(message: _busyMessage)
              : photos.isEmpty
              ? const EmptyState(
                  icon: Icons.restore_from_trash_rounded,
                  title: 'Trash is Empty',
                  subtitle:
                      'Photos you move to the trash appear here, where you '
                      'can restore them for about 30 days.',
                )
              : _buildList(context, provider, photos, selectedPhotos),
        );
      },
    );
  }

  Widget _buildList(
    BuildContext context,
    PhotoProvider provider,
    List<TrashedPhoto> photos,
    List<TrashedPhoto> selectedPhotos,
  ) {
    final colors = context.colors;
    return Column(
      children: [
        _TrashNote(
          provider: provider,
          onEmptyTrash: _busy
              ? null
              : () => _confirmEmptyTrash(provider, photos),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 0.72,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: photos.length,
            itemBuilder: (context, index) {
              final photo = photos[index];
              return _TrashTile(
                key: ValueKey(photo.id),
                photo: photo,
                selected: _selected.contains(photo.id),
                onTap: _busy
                    ? null
                    : () => setState(() {
                        if (!_selected.add(photo.id)) {
                          _selected.remove(photo.id);
                        }
                      }),
              );
            },
          ),
        ),
        if (selectedPhotos.isNotEmpty)
          SafeArea(
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
                      '${selectedPhotos.length} selected',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(_selected.clear),
                    icon: const Icon(Icons.close_rounded, size: 20),
                    tooltip: 'Clear selection',
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 2),
                  TextButton.icon(
                    onPressed: () => _restoreSelected(provider, selectedPhotos),
                    style: TextButton.styleFrom(
                      foregroundColor: colors.green,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                    icon: const Icon(Icons.restore_rounded, size: 18),
                    label: const Text('Restore'),
                  ),
                  const SizedBox(width: 4),
                  ElevatedButton.icon(
                    onPressed: () =>
                        _confirmDeleteSelected(provider, selectedPhotos),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.red,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    icon: const Icon(Icons.delete_forever_rounded, size: 18),
                    label: const Text('Delete'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _TrashNote extends StatelessWidget {
  final PhotoProvider provider;
  final VoidCallback? onEmptyTrash;

  const _TrashNote({required this.provider, required this.onEmptyTrash});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.cardAlt,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: colors.brand, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${provider.trashCount} ${provider.trashCount == 1 ? 'photo' : 'photos'} · ${formatBytes(provider.trashBytes)}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "These files are in Android's trash, not deleted yet. "
                  'Restore them within about 30 days or Android may remove '
                  'them for good.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: onEmptyTrash,
                  style: TextButton.styleFrom(
                    foregroundColor: colors.red,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.delete_forever_rounded, size: 18),
                  label: const Text('Empty trash'),
                ),
                Text(
                  'Permanently deletes every photo above. Cannot be undone.',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: colors.textMuted,
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

class _TrashTile extends StatelessWidget {
  final TrashedPhoto photo;
  final bool selected;
  final VoidCallback? onTap;

  const _TrashTile({
    super.key,
    required this.photo,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final urgency = photo.daysLeft <= 3 ? colors.amber : colors.textSecondary;
    return GestureDetector(
      onTap: onTap,
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? colors.green : colors.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(15),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (photo.thumbnail != null && photo.thumbnail!.isNotEmpty)
                      Image.memory(
                        photo.thumbnail!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      )
                    else
                      Container(
                        color: colors.cardAlt,
                        child: Icon(
                          Icons.image_not_supported_rounded,
                          color: colors.textMuted,
                          size: 34,
                        ),
                      ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: selected
                              ? colors.green
                              : Colors.black.withValues(alpha: 0.38),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? colors.green : Colors.white,
                            width: 2,
                          ),
                        ),
                        child: selected
                            ? const Icon(
                                Icons.check_rounded,
                                color: Colors.white,
                                size: 16,
                              )
                            : null,
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
                    photo.fileName,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    photo.sizeString,
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.schedule_rounded, size: 12, color: urgency),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          photo.expiryLabel,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: urgency,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
  }
}

class _BusyBody extends StatelessWidget {
  final String message;

  const _BusyBody({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 14),
          Text(
            message,
            style: TextStyle(fontSize: 13, color: context.colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
