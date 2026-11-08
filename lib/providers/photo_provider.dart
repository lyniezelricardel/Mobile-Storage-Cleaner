import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/data_models.dart';
import '../services/blur_detector.dart';
import '../services/duplicate_detector.dart';
import '../services/photo_analysis.dart';
import '../services/scan_store.dart';

class _AssetPayload {
  final AssetEntity asset;
  final File? file;
  final int fileSize;
  final Uint8List? thumbnail;

  const _AssetPayload({
    required this.asset,
    required this.file,
    required this.fileSize,
    required this.thumbnail,
  });
}

/// Manages cached scan results, incremental gallery refreshes, and safe
/// deletion through Android's system trash.
class PhotoProvider extends ChangeNotifier {
  static PMFilter _imageFilter() => PMFilter.defaultValue();
  static const _pageSize = 200;
  static const _batchSize = 24;
  static const _trashRetention = Duration(days: 30);

  final ScanStore _store = ScanStore();
  final Map<String, PhotoModel> _photosById = {};
  final Set<String> _trashedIds = {};

  List<PhotoModel> _allPhotos = [];
  List<PhotoModel> _blurryPhotos = [];
  List<DuplicateGroup> _duplicateGroups = [];
  List<TrashedPhoto> _trashedPhotos = [];

  bool _initialized = false;
  Future<void>? _initializing;
  bool _isScanning = false;
  bool _hasScanned = false;
  bool _limitedAccess = false;
  bool _cancelRequested = false;
  int? _androidSdkInt;

  String _scanStatus = 'Ready';
  int _scanProgress = 0;
  int _scanTotal = 0;
  int _newPhotoCount = 0;
  String? _error;
  DateTime? _scanStartedAt;
  DateTime? _lastScanAt;
  DateTime? _lastCheckedAt;

  List<PhotoModel> get allPhotos => List.unmodifiable(_allPhotos);
  List<PhotoModel> get blurryPhotos => List.unmodifiable(_blurryPhotos);
  List<DuplicateGroup> get duplicateGroups =>
      List.unmodifiable(_duplicateGroups);
  List<TrashedPhoto> get trashedPhotos => List.unmodifiable(_trashedPhotos);
  bool get initialized => _initialized;
  bool get isScanning => _isScanning;
  bool get hasScanned => _hasScanned;
  bool get limitedAccess => _limitedAccess;
  int get newPhotoCount => _newPhotoCount;
  String get scanStatus => _scanStatus;
  int get scanProgress => _scanProgress;
  int get scanTotal => _scanTotal;
  String? get error => _error;
  DateTime? get lastScanAt => _lastScanAt;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  int get photoCount => _allPhotos.length;
  int get trashCount => _trashedPhotos.length;
  int get trashBytes =>
      _trashedPhotos.fold(0, (sum, photo) => sum + photo.fileSize);

  double get scanPercent {
    if (_scanTotal <= 0) return 0;
    return (_scanProgress / _scanTotal).clamp(0.0, 1.0);
  }

  /// Estimated time remaining based on the current throughput.
  Duration? get estimatedRemaining {
    final started = _scanStartedAt;
    if (started == null || _scanProgress <= 0 || _scanTotal <= 0) return null;
    final elapsed = DateTime.now().difference(started);
    final perPhoto = elapsed.inMilliseconds / _scanProgress;
    final remainingMs = (perPhoto * (_scanTotal - _scanProgress)).round();
    if (remainingMs <= 0) return Duration.zero;
    return Duration(milliseconds: remainingMs);
  }

  List<PhotoModel> get selectedBlurryPhotos =>
      _blurryPhotos.where((p) => p.isSelected).toList();

  List<PhotoModel> get selectedDuplicatePhotos {
    final selected = <PhotoModel>[];
    for (final group in _duplicateGroups) {
      selected.addAll(group.photos.where((p) => p.isSelected));
    }
    return selected;
  }

  int get totalSelectedSize =>
      PhotoModel.totalSelectedSize(_blurryPhotos) +
      _duplicateGroups.fold(
        0,
        (sum, g) => sum + PhotoModel.totalSelectedSize(g.photos),
      );

  int get blurryCount => _blurryPhotos.length;
  int get duplicateGroupCount => _duplicateGroups.length;

  /// Loads cached results. Safe to call more than once.
  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      final snapshot = await _store.loadSnapshot();
      _photosById
        ..clear()
        ..addEntries(snapshot.photos.map((p) => MapEntry(p.id, p)));
      _allPhotos = snapshot.photos;
      _blurryPhotos = _sortBlurry(snapshot.photos.where((p) => p.isBlurry));
      _duplicateGroups = snapshot.groups;
      _lastScanAt = snapshot.lastScanAt;
      final checked = await _store.readMeta('last_check_at');
      _lastCheckedAt = checked == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(int.parse(checked));
      _hasScanned =
          snapshot.photos.isNotEmpty ||
          await _store.readMeta('has_scanned') == '1';
      await _loadTrash();
      _initialized = true;
      notifyListeners();
    } catch (e) {
      _error = 'Could not load saved scan results: $e';
      _initialized = true;
      notifyListeners();
    }

    if (_hasScanned) {
      unawaited(_checkForNewPhotos());
    }
  }

  /// Reloads the Recently Deleted list and drops entries whose Android trash
  /// window has already ended.
  Future<void> refreshTrash() async {
    await _loadTrash();
    notifyListeners();
  }

  Future<void> _loadTrash() async {
    try {
      final loaded = await _store.loadTrashedPhotos();
      final now = DateTime.now();
      final expired = loaded
          .where((photo) => !photo.expiresAt.isAfter(now))
          .map((photo) => photo.id)
          .toList(growable: false);
      if (expired.isNotEmpty) {
        await _store.deleteTrashedPhotos(expired);
      }

      _trashedPhotos = loaded
          .where((photo) => photo.expiresAt.isAfter(now))
          .toList(growable: true);
      _trashedPhotos.sort((a, b) => b.trashedAt.compareTo(a.trashedAt));
      _trashedIds
        ..clear()
        ..addAll(_trashedPhotos.map((photo) => photo.id));
    } catch (_) {
      // The trash list is helpful but must never block the photo cache.
    }
  }

  /// Requests permission to read photos. Videos are optional and only used
  /// for the storage breakdown.
  Future<bool> requestPermissions() async {
    var status = await Permission.photos.status;
    if (!status.isGranted && !status.isLimited) {
      status = await Permission.photos.request();
    }
    if (status.isGranted || status.isLimited) {
      _limitedAccess = status.isLimited;
      if (!await Permission.videos.isGranted) {
        await Permission.videos.request();
      }
      return true;
    }
    return false;
  }

  /// Loads results from the cache, or scans when there is nothing cached.
  ///
  /// Tab screens call this on startup. Once a scan exists this is a no-op, so
  /// switching tabs never re-analyzes the gallery.
  Future<void> scanPhotos({bool force = false}) async {
    await initialize();
    if (_isScanning) return;
    if (_hasScanned && !force) return;
    await _runScan(force: force);
  }

  /// Checks the gallery for added, changed, or removed photos.
  Future<void> refreshGallery() async {
    await initialize();
    if (_isScanning) return;
    await _runScan(force: false);
  }

  /// Re-analyzes every photo in the gallery.
  Future<void> rescanAll() async {
    await initialize();
    if (_isScanning) return;
    await _runScan(force: true);
  }

  /// Stops the current scan after the batches that are already running.
  void cancelScan() {
    if (!_isScanning) return;
    _cancelRequested = true;
    _scanStatus = 'Stopping scan...';
    notifyListeners();
  }

  Future<void> _runScan({required bool force}) async {
    _isScanning = true;
    _cancelRequested = false;
    _error = null;
    _scanProgress = 0;
    _scanTotal = 0;
    _scanStartedAt = DateTime.now();
    _scanStatus = 'Requesting photo access...';
    notifyListeners();

    if (!await requestPermissions()) {
      _isScanning = false;
      _error = 'Photo access is required to scan your gallery.';
      _scanStatus = 'Permission denied';
      notifyListeners();
      return;
    }

    try {
      _scanStatus = 'Checking your gallery...';
      notifyListeners();
      final assets = await _loadAllAssets();
      final currentIds = assets.map((a) => a.id).toSet();

      final removedIds = force || !_limitedAccess
          ? _photosById.keys.where((id) => !currentIds.contains(id)).toList()
          : <String>[];

      var indexChanged = removedIds.isNotEmpty;
      if (removedIds.isNotEmpty) {
        for (final id in removedIds) {
          _photosById.remove(id);
        }
        _allPhotos = _photosById.values.toList(growable: false);
        _blurryPhotos = _sortBlurry(_allPhotos.where((p) => p.isBlurry));
        await _store.deletePhotos(removedIds);
      }

      final toAnalyze = <AssetEntity>[];
      for (final asset in assets) {
        if (_trashedIds.contains(asset.id)) continue;
        final cached = _photosById[asset.id];
        if (force ||
            cached == null ||
            cached.modifiedAt.millisecondsSinceEpoch !=
                asset.modifiedDateTime.millisecondsSinceEpoch) {
          toAnalyze.add(asset);
        }
      }

      _scanTotal = toAnalyze.length;
      if (toAnalyze.isEmpty) {
        if (indexChanged) {
          await _recomputeGroups();
        }
        await _markChecked();
        _hasScanned = true;
        await _store.writeMeta('has_scanned', '1');
        _scanStatus = indexChanged ? 'Gallery updated' : 'Already up to date';
        _newPhotoCount = 0;
        notifyListeners();
        return;
      }

      _scanStatus =
          'Analyzing ${toAnalyze.length} ${toAnalyze.length == 1 ? 'photo' : 'photos'}...';
      notifyListeners();

      final completed = await _analyzeAssets(toAnalyze);
      _allPhotos = _sortByDate(_photosById.values);
      _blurryPhotos = _sortBlurry(_allPhotos.where((p) => p.isBlurry));

      if (_cancelRequested) {
        _newPhotoCount = (toAnalyze.length - completed).clamp(
          0,
          toAnalyze.length,
        );
        _scanStatus = 'Scan stopped — $completed of ${toAnalyze.length} saved';
      } else {
        _newPhotoCount = 0;
      }

      await _recomputeGroups();
      await _markChecked(completedAll: !_cancelRequested);
      _hasScanned = true;
      await _store.writeMeta('has_scanned', '1');

      if (!_cancelRequested) {
        _scanStatus = completed == _scanTotal
            ? 'Scan complete'
            : 'Scan complete — $completed photos analyzed';
      }
    } catch (e) {
      _error = 'Scan failed: $e';
      _scanStatus = 'Scan failed';
    } finally {
      _isScanning = false;
      _scanStartedAt = null;
      notifyListeners();
    }
  }

  Future<List<AssetEntity>> _loadAllAssets() async {
    final count = await PhotoManager.getAssetCount(
      filterOption: _imageFilter(),
      type: RequestType.image,
    );
    final assets = <AssetEntity>[];
    for (var start = 0; start < count; start += _pageSize) {
      final end = (start + _pageSize).clamp(0, count);
      final page = await PhotoManager.getAssetListRange(
        start: start,
        end: end,
        filterOption: _imageFilter(),
        type: RequestType.image,
      );
      if (page.isEmpty) break;
      assets.addAll(page);
      if (!_isScanning) break;
    }
    return assets;
  }

  Future<int> _analyzeAssets(List<AssetEntity> assets) async {
    final batches = <List<AssetEntity>>[];
    for (var i = 0; i < assets.length; i += _batchSize) {
      batches.add(assets.sublist(i, (i + _batchSize).clamp(0, assets.length)));
    }

    var nextBatch = 0;
    var completed = 0;
    final workerCount = Platform.numberOfProcessors >= 8 ? 3 : 2;

    Future<void> worker() async {
      while (!_cancelRequested) {
        final index = nextBatch++;
        if (index >= batches.length) return;

        final payloads = await Future.wait(batches[index].map(_readAsset));
        if (_cancelRequested) return;

        final analyses = await compute(
          analyzePhotoBatch,
          payloads.map((p) => p.thumbnail).toList(growable: false),
          debugLabel: 'photo-analysis',
        );

        final models = <PhotoModel>[];
        for (var i = 0; i < payloads.length; i++) {
          final payload = payloads[i];
          if (_trashedIds.contains(payload.asset.id)) continue;
          final analysis = analyses[i];
          models.add(
            PhotoModel(
              id: payload.asset.id,
              path: payload.file?.path ?? '',
              thumbnailPath: payload.file?.path,
              fileSize: payload.fileSize,
              blurScore: analysis.blurScore,
              isBlurry:
                  analysis.decoded &&
                  analysis.blurScore < BlurDetector.blurThreshold,
              dateTaken: payload.asset.createDateTime,
              modifiedAt: payload.asset.modifiedDateTime,
              mimeType: payload.asset.mimeType ?? 'image/jpeg',
              perceptualHash: analysis.hash,
            ),
          );
        }

        if (models.isNotEmpty) {
          await _store.upsertPhotos(models);
          for (final model in models) {
            _photosById[model.id] = model;
          }
        }

        completed += payloads.length;
        _allPhotos = _photosById.values.toList(growable: false);
        _blurryPhotos = _allPhotos
            .where((p) => p.isBlurry)
            .toList(growable: false);
        _scanProgress = completed;
        _scanStatus =
            'Analyzing $completed of ${assets.length} ${assets.length == 1 ? 'photo' : 'photos'}...';
        notifyListeners();
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
    return completed;
  }

  Future<_AssetPayload> _readAsset(AssetEntity asset) async {
    File? file;
    Uint8List? thumbnail;
    int fileSize = 0;

    await Future.wait([
      () async {
        try {
          file = await asset.file;
          if (file != null) fileSize = await file!.length();
        } catch (_) {
          file = null;
        }
      }(),
      () async {
        try {
          thumbnail = await asset.thumbnailDataWithSize(
            const ThumbnailSize(320, 320),
            quality: 80,
          );
        } catch (_) {
          thumbnail = null;
        }
      }(),
    ]);

    if ((thumbnail == null || thumbnail!.isEmpty) && file != null) {
      try {
        thumbnail = await file!.readAsBytes();
      } catch (_) {
        thumbnail = null;
      }
    }

    return _AssetPayload(
      asset: asset,
      file: file,
      fileSize: fileSize,
      thumbnail: thumbnail,
    );
  }

  Future<void> _recomputeGroups() async {
    final selectedIds = <String>{
      ..._blurryPhotos.where((p) => p.isSelected).map((p) => p.id),
      for (final group in _duplicateGroups)
        ...group.photos.where((p) => p.isSelected).map((p) => p.id),
    };

    final candidates = _allPhotos
        .where((p) => p.perceptualHash.isNotEmpty)
        .toList(growable: false);

    _scanStatus = 'Finding duplicates...';
    notifyListeners();

    List<DuplicateGroup> groups;
    if (candidates.length < 2) {
      groups = [];
    } else {
      groups = await compute(
        groupPhotosInIsolate,
        candidates,
        debugLabel: 'duplicate-grouping',
      );
    }

    _duplicateGroups = groups
        .map((group) {
          if (selectedIds.isEmpty) return group;
          return group.copyWith(
            photos: group.photos
                .map(
                  (photo) => photo.copyWith(
                    isSelected: selectedIds.contains(photo.id),
                  ),
                )
                .toList(growable: false),
          );
        })
        .toList(growable: false);

    if (selectedIds.isNotEmpty) {
      _blurryPhotos = _blurryPhotos
          .map((p) => p.copyWith(isSelected: selectedIds.contains(p.id)))
          .toList(growable: false);
    }

    await _store.replaceGroups(_duplicateGroups);
  }

  Future<void> _markChecked({bool completedAll = true}) async {
    final now = DateTime.now();
    _lastCheckedAt = now;
    await _store.writeMeta('last_check_at', '${now.millisecondsSinceEpoch}');
    if (completedAll) {
      _lastScanAt = now;
      await _store.writeMeta('last_scan_at', '${now.millisecondsSinceEpoch}');
    }
  }

  /// Checks metadata only (no image decoding) for newly added photos.
  Future<void> _checkForNewPhotos() async {
    if (_isScanning || !_hasScanned) return;
    try {
      final status = await Permission.photos.status;
      if (!status.isGranted && !status.isLimited) return;
      _limitedAccess = status.isLimited;

      final count = await PhotoManager.getAssetCount(
        filterOption: _imageFilter(),
        type: RequestType.image,
      );
      var changed = 0;
      for (var start = 0; start < count; start += _pageSize) {
        final end = (start + _pageSize).clamp(0, count);
        final page = await PhotoManager.getAssetListRange(
          start: start,
          end: end,
          filterOption: _imageFilter(),
          type: RequestType.image,
        );
        if (page.isEmpty) break;
        for (final asset in page) {
          if (_trashedIds.contains(asset.id)) continue;
          final cached = _photosById[asset.id];
          if (cached == null ||
              cached.modifiedAt.millisecondsSinceEpoch !=
                  asset.modifiedDateTime.millisecondsSinceEpoch) {
            changed++;
          }
        }
      }
      if (_isScanning) return;

      if (_newPhotoCount != changed) {
        _newPhotoCount = changed;
        notifyListeners();
      }
    } catch (_) {
      // A metadata check is best-effort; refresh still works.
    }
  }

  /// Re-checks the gallery for new photos and updates [newPhotoCount].
  Future<void> checkForNewPhotos() => _checkForNewPhotos();

  void toggleBlurrySelection(String photoId) {
    final index = _blurryPhotos.indexWhere((p) => p.id == photoId);
    if (index != -1) {
      _blurryPhotos[index] = _blurryPhotos[index].copyWith(
        isSelected: !_blurryPhotos[index].isSelected,
      );
      notifyListeners();
    }
  }

  void toggleDuplicateSelection(String groupId, String photoId) {
    final groupIndex = _duplicateGroups.indexWhere((g) => g.groupId == groupId);
    if (groupIndex == -1) return;

    final group = _duplicateGroups[groupIndex];
    final photoIndex = group.photos.indexWhere((p) => p.id == photoId);
    if (photoIndex == -1) return;

    final updatedPhotos = List<PhotoModel>.from(group.photos);
    updatedPhotos[photoIndex] = updatedPhotos[photoIndex].copyWith(
      isSelected: !updatedPhotos[photoIndex].isSelected,
    );

    _duplicateGroups[groupIndex] = group.copyWith(photos: updatedPhotos);
    notifyListeners();
  }

  void selectAllButOneInGroup(String groupId) {
    final groupIndex = _duplicateGroups.indexWhere((g) => g.groupId == groupId);
    if (groupIndex == -1) return;

    final group = _duplicateGroups[groupIndex];
    if (group.photos.isEmpty) return;

    // Keep the same copy the UI labels BEST, not whichever happens to be at
    // index zero in the group's gallery order.
    _duplicateGroups[groupIndex] = group.copyWith(
      photos: group.photosAllButBestSelected,
    );
    notifyListeners();
  }

  void selectAllBlurry() {
    _blurryPhotos = _blurryPhotos
        .map((p) => p.copyWith(isSelected: true))
        .toList();
    notifyListeners();
  }

  void deselectAllBlurry() {
    _blurryPhotos = _blurryPhotos
        .map((p) => p.copyWith(isSelected: false))
        .toList();
    notifyListeners();
  }

  void deselectAllDuplicates() {
    _duplicateGroups = _duplicateGroups.map((g) {
      return g.copyWith(
        photos: g.photos.map((p) => p.copyWith(isSelected: false)).toList(),
      );
    }).toList();
    notifyListeners();
  }

  Future<TrashResult> moveSelectedBlurryPhotosToTrash() {
    return movePhotosToTrash(selectedBlurryPhotos);
  }

  Future<TrashResult> moveSelectedDuplicatePhotosToTrash() {
    return movePhotosToTrash(selectedDuplicatePhotos);
  }

  /// Moves photos into Android's system trash so they can still be restored.
  ///
  /// Android 11+ shows a system confirmation. On Android 10 and below the
  /// MediaStore has no trash, so the app refuses to fall back to a permanent
  /// delete and explains why instead.
  Future<TrashResult> movePhotosToTrash(List<PhotoModel> photos) async {
    final unique = <String, PhotoModel>{for (final p in photos) p.id: p};
    if (unique.isEmpty) return const TrashResult();

    final requested = unique.length;
    final sdk = await _androidSdk();
    if (sdk > 0 && sdk < 30) {
      return TrashResult(
        requestedCount: requested,
        error:
            'Android 11 or newer is needed to move photos to the trash. '
            'On this device, use your gallery app if you are sure you want '
            'to remove them.',
      );
    }

    final entries = unique.values.toList(growable: false);
    final assets = <String, AssetEntity>{};
    final thumbnails = <String, Uint8List>{};

    // Resolve assets and capture thumbnails before the files leave the
    // gallery, because trashed files are hidden from normal MediaStore reads.
    for (var start = 0; start < entries.length; start += 6) {
      final end = (start + 6).clamp(0, entries.length);
      final chunk = entries.sublist(start, end);
      await Future.wait(
        chunk.map((photo) async {
          try {
            final asset = await AssetEntity.fromId(photo.id);
            if (asset != null) {
              assets[photo.id] = asset;
              final thumb = await asset.thumbnailDataWithSize(
                const ThumbnailSize(240, 240),
                quality: 70,
              );
              if (thumb != null && thumb.isNotEmpty) {
                thumbnails[photo.id] = thumb;
              }
            }
          } catch (_) {
            // The id-only fallback below is enough for the trash request.
          }
          assets.putIfAbsent(
            photo.id,
            () => AssetEntity(id: photo.id, typeInt: 1, width: 0, height: 0),
          );
        }),
      );
    }

    final assetList = entries
        .map((photo) => assets[photo.id]!)
        .toList(growable: false);
    List<String> trashedIds;
    try {
      trashedIds = await PhotoManager.editor.android.moveToTrash(assetList);
    } catch (e) {
      return TrashResult(
        requestedCount: requested,
        error: _trashErrorMessage(e),
      );
    }

    if (trashedIds.isEmpty) {
      return TrashResult(requestedCount: requested, canceled: true);
    }

    final trashedSet = trashedIds.toSet();
    final now = DateTime.now();
    final records = <TrashedPhoto>[];
    for (final photo in entries) {
      if (!trashedSet.contains(photo.id)) continue;
      final asset = assets[photo.id];
      records.add(
        TrashedPhoto(
          id: photo.id,
          path: photo.path,
          fileSize: photo.fileSize,
          dateTaken: photo.dateTaken,
          mimeType: photo.mimeType,
          typeInt: asset?.typeInt ?? 1,
          width: asset?.width ?? 0,
          height: asset?.height ?? 0,
          trashedAt: now,
          expiresAt: now.add(_trashRetention),
          thumbnail: thumbnails[photo.id],
        ),
      );
    }

    if (records.isEmpty) {
      return TrashResult(requestedCount: requested, canceled: true);
    }

    final recordIds = records.map((photo) => photo.id).toSet();
    _trashedIds.addAll(recordIds);
    try {
      await _store.upsertTrashedPhotos(records);
    } catch (_) {
      // The system trash already accepted the files; keep the in-memory list
      // usable even if the cache write fails.
    }
    _trashedPhotos = [...records, ..._trashedPhotos]
      ..sort((a, b) => b.trashedAt.compareTo(a.trashedAt));

    for (final id in recordIds) {
      _photosById.remove(id);
    }
    _allPhotos = _sortByDate(_photosById.values);
    _blurryPhotos = _sortBlurry(_allPhotos.where((p) => p.isBlurry));
    _duplicateGroups = _duplicateGroups
        .map((group) {
          final remaining = group.photos
              .where((photo) => !recordIds.contains(photo.id))
              .toList(growable: false);
          return group.copyWith(photos: remaining);
        })
        .where((group) => group.photos.length > 1)
        .toList(growable: false);

    await _store.deletePhotos(recordIds);
    await _store.replaceGroups(_duplicateGroups);
    notifyListeners();

    return TrashResult(
      requestedCount: requested,
      trashedCount: records.length,
      trashedPhotos: records,
    );
  }

  /// Restores photos from Android's system trash. The gallery is re-checked so
  /// the restored images return to the app's cache.
  Future<RestoreResult> restoreTrashedPhotos(List<TrashedPhoto> photos) async {
    final unique = <String, TrashedPhoto>{for (final p in photos) p.id: p};
    if (unique.isEmpty) return const RestoreResult();

    final requested = unique.length;
    final assets = unique.values
        .map(
          (photo) => AssetEntity(
            id: photo.id,
            typeInt: photo.typeInt,
            width: photo.width,
            height: photo.height,
            title: photo.fileName,
          ),
        )
        .toList(growable: false);

    List<String> restoredIds;
    try {
      restoredIds = await PhotoManager.editor.android.restoreFromTrash(assets);
    } catch (e) {
      return RestoreResult(
        requestedCount: requested,
        error:
            'Android could not restore these photos. They may already have '
            'left the system trash. $e',
      );
    }

    if (restoredIds.isEmpty) {
      return RestoreResult(requestedCount: requested, canceled: true);
    }

    final restoredSet = restoredIds.toSet();
    _trashedPhotos.removeWhere((photo) => restoredSet.contains(photo.id));
    _trashedIds.removeAll(restoredSet);
    await _store.deleteTrashedPhotos(restoredSet);
    notifyListeners();

    unawaited(refreshGallery());
    return RestoreResult(
      requestedCount: requested,
      restoredCount: restoredIds.length,
    );
  }

  /// Permanently deletes photos that are already in Android's system trash.
  ///
  /// Android 11+ shows its own confirmation before removing the files from
  /// MediaStore and the gallery. Local records are only removed after Android
  /// reports the matching ids as deleted.
  Future<PermanentDeleteResult> permanentlyDeleteTrashedPhotos(
    List<TrashedPhoto> photos,
  ) async {
    final unique = <String, TrashedPhoto>{for (final p in photos) p.id: p};
    if (unique.isEmpty) return const PermanentDeleteResult();

    final requested = unique.length;
    final sdk = await _androidSdk();
    if (sdk > 0 && sdk < 30) {
      return PermanentDeleteResult(
        requestedCount: requested,
        error:
            'Permanent delete needs Android 11 or newer. On this device, '
            'empty the trash from your gallery app instead.',
      );
    }

    List<String> deletedIds;
    try {
      deletedIds = await PhotoManager.editor.deleteWithIds(
        unique.keys.toList(growable: false),
      );
    } catch (e) {
      return PermanentDeleteResult(
        requestedCount: requested,
        error: 'Android could not permanently delete these photos: $e',
      );
    }

    if (deletedIds.isEmpty) {
      return PermanentDeleteResult(requestedCount: requested, canceled: true);
    }

    final deletedSet = deletedIds.toSet();
    final deletedPhotos = unique.values
        .where((photo) => deletedSet.contains(photo.id))
        .toList(growable: false);
    if (deletedPhotos.isEmpty) {
      return PermanentDeleteResult(requestedCount: requested, canceled: true);
    }

    _trashedPhotos.removeWhere((photo) => deletedSet.contains(photo.id));
    _trashedIds.removeAll(deletedSet);
    for (final id in deletedSet) {
      _photosById.remove(id);
    }
    _allPhotos = _sortByDate(_photosById.values);
    _blurryPhotos = _sortBlurry(_allPhotos.where((p) => p.isBlurry));
    _duplicateGroups = _duplicateGroups
        .map((group) {
          final remaining = group.photos
              .where((photo) => !deletedSet.contains(photo.id))
              .toList(growable: false);
          return group.copyWith(photos: remaining);
        })
        .where((group) => group.photos.length > 1)
        .toList(growable: false);

    try {
      await _store.deleteTrashedPhotos(deletedSet);
    } catch (_) {
      // The system already deleted the files; keep the in-memory state usable
      // if the cache cleanup fails.
    }
    try {
      await _store.deletePhotos(deletedSet);
    } catch (_) {
      // Same fallback as above for stale photo or hash rows.
    }
    try {
      await _store.replaceGroups(_duplicateGroups);
    } catch (_) {
      // The deleted photos are already gone from the gallery.
    }
    notifyListeners();

    return PermanentDeleteResult(
      requestedCount: requested,
      deletedPhotos: deletedPhotos,
    );
  }

  Future<int> _androidSdk() async {
    final cached = _androidSdkInt;
    if (cached != null) return cached;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      _androidSdkInt = info.version.sdkInt;
    } catch (_) {
      // Unknown; let the platform plugin decide whether the call is supported.
      _androidSdkInt = 0;
    }
    return _androidSdkInt!;
  }

  String _trashErrorMessage(Object error) {
    final text = error.toString();
    if (text.contains('29 or lower') ||
        text.contains('cannot be used in 29') ||
        text.contains('UnsupportedOperationException')) {
      return 'Android 11 or newer is needed to move photos to the trash. '
          'On this device, use your gallery app if you are sure you want to '
          'remove them.';
    }
    return 'Android could not move these photos to the trash: $error';
  }

  List<PhotoModel> _sortByDate(Iterable<PhotoModel> photos) {
    final sorted = photos.toList(growable: false);
    sorted.sort((a, b) => b.dateTaken.compareTo(a.dateTaken));
    return sorted;
  }

  List<PhotoModel> _sortBlurry(Iterable<PhotoModel> photos) {
    final sorted = photos.toList(growable: false);
    sorted.sort((a, b) => a.blurScore.compareTo(b.blurScore));
    return sorted;
  }
}
