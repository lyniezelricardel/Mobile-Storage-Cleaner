import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/photo_provider.dart';
import '../providers/storage_provider.dart';
import '../widgets/ui_widgets.dart';

/// Screen showing blurry photos detected from the gallery.
class BlurryPhotosScreen extends StatefulWidget {
  final bool embedded;

  const BlurryPhotosScreen({super.key, this.embedded = false});

  @override
  State<BlurryPhotosScreen> createState() => _BlurryPhotosScreenState();
}

class _BlurryPhotosScreenState extends State<BlurryPhotosScreen> {
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
            appBar: _appBar('Scanning Photos'),
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
            appBar: _appBar('Blurry Photos'),
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

        if (provider.blurryPhotos.isEmpty) {
          return Scaffold(
            appBar: _appBar('Blurry Photos'),
            body: EmptyState(
              icon: Icons.auto_awesome_rounded,
              title: 'No Blurry Photos Found',
              subtitle:
                  'Your photos look sharp! Run a new scan to check again.',
              onAction: _refresh,
              actionLabel: 'Scan Again',
            ),
            floatingActionButton: FloatingActionButton(
              onPressed: _refresh,
              child: const Icon(Icons.refresh_rounded),
            ),
          );
        }

        final selectedCount = provider.selectedBlurryPhotos.length;
        final freedBytes = provider.totalSelectedSize;

        return Scaffold(
          appBar: _appBar(
            selectedCount > 0 ? '$selectedCount selected' : 'Blurry Photos',
            actions: [
              if (selectedCount > 0)
                TextButton(
                  onPressed: provider.deselectAllBlurry,
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
                          'Delete $selectedCount selected photo(s) to free ${_formatBytes(freedBytes)}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFEF4444),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: provider.deselectAllBlurry,
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
                child: GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 0.75,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: provider.blurryPhotos.length,
                  itemBuilder: (context, index) {
                    final photo = provider.blurryPhotos[index];
                    return PhotoGridItem(
                      photo: photo,
                      isSelected: photo.isSelected,
                      onTap: () => provider.toggleBlurrySelection(photo.id),
                      showBlurScore: true,
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
    final selected = provider.selectedBlurryPhotos;
    if (selected.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    final storageProvider = context.read<StorageProvider>();

    bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ConfirmationDialog(
        title: 'Delete Blurry Photos?',
        content:
            'This will permanently delete $selectedCount selected blurry photo(s). This action cannot be undone.',
        photoCount: selectedCount,
        bytesFreed: bytesFreed,
        onConfirm: () => Navigator.of(context).pop(true),
        onCancel: () => Navigator.of(context).pop(false),
      ),
    );

    if (confirmed == true) {
      final freed = await provider.deleteSelectedBlurryPhotos();
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Deleted $selectedCount photo(s). Freed ${_formatBytes(freed)}',
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
