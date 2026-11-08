import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/data_models.dart';
import '../providers/photo_provider.dart';
import '../utils/format_bytes.dart';
import '../widgets/ui_widgets.dart';
import 'enhance_photo_screen.dart';

/// Screen showing blurry photos detected from the gallery.
class BlurryPhotosScreen extends StatefulWidget {
  final bool embedded;

  const BlurryPhotosScreen({super.key, this.embedded = false});

  @override
  State<BlurryPhotosScreen> createState() => _BlurryPhotosScreenState();
}

class _BlurryPhotosScreenState extends State<BlurryPhotosScreen> {
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

  Future<void> _openEnhancer(PhotoModel photo) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => EnhancePhotoScreen(photo: photo)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PhotoProvider>(
      builder: (context, provider, _) {
        final selectedCount = provider.selectedBlurryPhotos.length;
        return Scaffold(
          appBar: widget.embedded
              ? null
              : AppBar(
                  title: Text(
                    selectedCount > 0
                        ? '$selectedCount selected'
                        : 'Blurry Photos',
                  ),
                ),
          body: _buildBody(context, provider),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, PhotoProvider provider) {
    final colors = context.colors;
    final selected = provider.selectedBlurryPhotos;

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
        // Keep each slot a SizedBox even when empty so the GridView keeps its
        // element (and scroll offset) when the selection UI appears.
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
          onRefresh: _refresh,
          onRescanAll: _rescanAll,
        ),
        SizedBox(
          child: selected.isNotEmpty
              ? _SelectionBanner(
                  count: selected.length,
                  bytes: PhotoModel.totalSelectedSize(provider.blurryPhotos),
                  onDeselect: provider.deselectAllBlurry,
                  onTrash: () => _confirmTrash(
                    context,
                    provider,
                    selected.length,
                    PhotoModel.totalSelectedSize(provider.blurryPhotos),
                  ),
                )
              : null,
        ),
        Expanded(
          child: provider.blurryPhotos.isEmpty
              ? EmptyState(
                  icon: Icons.auto_awesome_rounded,
                  title: 'No Blurry Photos',
                  subtitle:
                      'Your photos look sharp. Refresh the gallery after taking new photos.',
                  onAction: _refresh,
                  actionLabel: 'Refresh Gallery',
                )
              : GridView.builder(
                  key: const PageStorageKey<String>('blurry-photos-grid'),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 0.78,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: provider.blurryPhotos.length,
                  itemBuilder: (context, index) {
                    final photo = provider.blurryPhotos[index];
                    return PhotoGridItem(
                      key: ValueKey(photo.id),
                      photo: photo,
                      isSelected: photo.isSelected,
                      onTap: () => provider.toggleBlurrySelection(photo.id),
                      onEnhance: () => _openEnhancer(photo),
                      showBlurScore: true,
                    );
                  },
                ),
        ),
        SizedBox(
          child: selected.isNotEmpty
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
                            '${selected.length} selected · ${formatBytes(PhotoModel.totalSelectedSize(provider.blurryPhotos))}',
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
                            selected.length,
                            PhotoModel.totalSelectedSize(provider.blurryPhotos),
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

  Future<void> _confirmTrash(
    BuildContext context,
    PhotoProvider provider,
    int selectedCount,
    int bytesToTrash,
  ) async {
    if (provider.selectedBlurryPhotos.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    final colors = context.colors;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ConfirmationDialog(
        title: 'Move Blurry Photos to Trash?',
        content:
            "The selected photos will move to Android's system trash. "
            'Nothing is permanently removed yet.',
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

    final result = await provider.moveSelectedBlurryPhotosToTrash();
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
        : 'Moved ${result.trashedCount} ${result.trashedCount == 1 ? 'photo' : 'photos'} to the trash';
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
  final Future<void> Function() onRefresh;
  final Future<void> Function() onRescanAll;

  const _Header({
    required this.provider,
    required this.onRefresh,
    required this.onRescanAll,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final lastScan = provider.lastScanAt;
    final subtitle = lastScan == null
        ? '${provider.photoCount} photos indexed'
        : '${provider.photoCount} photos · updated ${_relative(lastScan)}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${provider.blurryCount} blurry ${provider.blurryCount == 1 ? 'photo' : 'photos'}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
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

  String _relative(DateTime time) {
    final difference = DateTime.now().difference(time);
    if (difference.inMinutes < 1) return 'just now';
    if (difference.inHours < 1) return '${difference.inMinutes} min ago';
    if (difference.inDays < 1) return '${difference.inHours} h ago';
    return '${difference.inDays} d ago';
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
