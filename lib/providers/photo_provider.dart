import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/data_models.dart';
import '../services/blur_detector.dart';
import '../services/duplicate_detector.dart';

/// Manages photo scanning, blur detection, duplicate detection, and selection state.
class PhotoProvider extends ChangeNotifier {
  List<PhotoModel> _allPhotos = [];
  List<PhotoModel> _blurryPhotos = [];
  List<DuplicateGroup> _duplicateGroups = [];
  bool _isScanning = false;
  String _scanStatus = 'Ready';
  int _scanProgress = 0;
  int _scanTotal = 0;
  String? _error;

  List<PhotoModel> get allPhotos => _allPhotos;
  List<PhotoModel> get blurryPhotos => _blurryPhotos;
  List<DuplicateGroup> get duplicateGroups => _duplicateGroups;
  bool get isScanning => _isScanning;
  String get scanStatus => _scanStatus;
  int get scanProgress => _scanProgress;
  int get scanTotal => _scanTotal;
  String? get error => _error;

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

  /// Request storage permissions and initialize photo manager.
  Future<bool> requestPermissions() async {
    final photoStatus = await Permission.photos.request();
    // Videos are optional: without them the storage breakdown simply shows
    // zero video usage instead of failing the scan.
    if (photoStatus.isGranted) {
      await Permission.videos.request();
    }
    return photoStatus.isGranted;
  }

  /// Scan the gallery for photos, detect blurry ones, and find duplicates.
  ///
  /// Pass [force] to rescan when results already exist. Calls made while a
  /// scan is running are ignored, so switching tabs never restarts the scan.
  Future<void> scanPhotos({bool force = false}) async {
    if (_isScanning) return;
    if (!force && _allPhotos.isNotEmpty) return;

    _isScanning = true;
    _blurryPhotos = [];
    _duplicateGroups = [];
    _scanStatus = 'Requesting permissions...';
    _scanProgress = 0;
    _scanTotal = 0;
    _error = null;
    notifyListeners();

    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      _error = 'Storage permission denied. Cannot access photos.';
      _isScanning = false;
      notifyListeners();
      return;
    }

    try {
      _scanStatus = 'Loading photo gallery...';
      notifyListeners();

      // Request only recent photos (limit for performance)
      final assets = await PhotoManager.getAssetListRange(
        start: 0,
        end: 500, // Limit for performance on large collections
        filterOption: PMFilter.defaultValue(),
        type: RequestType.image,
      );

      _scanTotal = assets.length;
      _allPhotos = [];

      for (int i = 0; i < assets.length; i++) {
        final asset = assets[i];
        final file = await asset.file;
        if (file == null) continue;

        final id = asset.id.toString();
        final path = file.path;
        final size = await file.length();
        final dateTaken = asset.createDateTime;
        final mimeType = asset.mimeType ?? 'image/jpeg';

        _scanStatus = 'Analyzing photo ${i + 1} of $_scanTotal...';
        _scanProgress = i + 1;
        notifyListeners();

        // Analyze a small native thumbnail instead of the full-resolution
        // file. Full-size camera photos take seconds to decode and are not
        // needed for blur scoring or perceptual hashing.
        Uint8List? bytes;
        try {
          bytes = await asset.thumbnailDataWithSize(
            const ThumbnailSize(400, 400),
            quality: 85,
          );
        } catch (_) {
          // Some assets (cloud-only, corrupt, or unsupported formats) fail to
          // produce thumbnails. Fall back to reading the original file.
          bytes = null;
        }

        if (bytes == null || bytes.isEmpty) {
          try {
            bytes = await file.readAsBytes();
          } catch (_) {
            bytes = null;
          }
        }

        // Decode once and reuse the image for both blur and hash analysis.
        final decoded = bytes == null || bytes.isEmpty
            ? null
            : img.decodeImage(bytes);

        final blurScore = decoded == null
            ? 0.0
            : BlurDetector.computeBlurScore(decoded);
        final hash = decoded == null
            ? ''
            : DuplicateDetector.computeHashFromImage(decoded);

        final photo = PhotoModel(
          id: id,
          path: path,
          thumbnailPath: path,
          fileSize: size,
          blurScore: blurScore,
          isBlurry: decoded != null && blurScore < BlurDetector.blurThreshold,
          dateTaken: dateTaken,
          mimeType: mimeType,
          perceptualHash: hash,
        );

        _allPhotos.add(photo);

        if (photo.isBlurry) {
          _blurryPhotos.add(photo);
        }
      }

      _scanStatus = 'Detecting duplicates...';
      notifyListeners();

      // Detect duplicates among all scanned photos
      _duplicateGroups = DuplicateDetector.groupDuplicates(_allPhotos);

      _isScanning = false;
      _scanStatus = 'Scan complete';
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      _isScanning = false;
      _scanStatus = 'Scan failed';
      notifyListeners();
    }
  }

  /// Clears previous results and starts a fresh scan.
  Future<void> rescan() async {
    if (_isScanning) return;
    clearResults();
    await scanPhotos(force: true);
  }

  /// Toggle selection on a blurry photo.
  void toggleBlurrySelection(String photoId) {
    final index = _blurryPhotos.indexWhere((p) => p.id == photoId);
    if (index != -1) {
      _blurryPhotos[index] = _blurryPhotos[index].copyWith(
        isSelected: !_blurryPhotos[index].isSelected,
      );
      notifyListeners();
    }
  }

  /// Toggle selection on a photo within a duplicate group.
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

  /// Select all photos in a duplicate group except one (keeps the first/largest).
  void selectAllButOneInGroup(String groupId, {int keepIndex = 0}) {
    final groupIndex = _duplicateGroups.indexWhere((g) => g.groupId == groupId);
    if (groupIndex == -1) return;

    final group = _duplicateGroups[groupIndex];
    final updatedPhotos = List<PhotoModel>.from(group.photos);

    for (int i = 0; i < updatedPhotos.length; i++) {
      updatedPhotos[i] = updatedPhotos[i].copyWith(isSelected: i != keepIndex);
    }

    _duplicateGroups[groupIndex] = group.copyWith(photos: updatedPhotos);
    notifyListeners();
  }

  /// Select all blurry photos.
  void selectAllBlurry() {
    _blurryPhotos = _blurryPhotos
        .map((p) => p.copyWith(isSelected: true))
        .toList();
    notifyListeners();
  }

  /// Deselect all blurry photos.
  void deselectAllBlurry() {
    _blurryPhotos = _blurryPhotos
        .map((p) => p.copyWith(isSelected: false))
        .toList();
    notifyListeners();
  }

  /// Deselect all photos in all duplicate groups.
  void deselectAllDuplicates() {
    _duplicateGroups = _duplicateGroups.map((g) {
      return g.copyWith(
        photos: g.photos.map((p) => p.copyWith(isSelected: false)).toList(),
      );
    }).toList();
    notifyListeners();
  }

  /// Delete selected blurry photos and return the total bytes freed.
  Future<int> deleteSelectedBlurryPhotos() async {
    int freedBytes = 0;
    final photosToDelete = selectedBlurryPhotos;

    for (final photo in photosToDelete) {
      try {
        final file = File(photo.path);
        if (await file.exists()) {
          freedBytes += await file.length();
          await file.delete();
        }
      } catch (_) {
        // Skip files that can't be deleted
      }
    }

    // Remove deleted photos from list
    _blurryPhotos.removeWhere((p) => p.isSelected);

    notifyListeners();
    return freedBytes;
  }

  /// Delete selected duplicate photos and return the total bytes freed.
  Future<int> deleteSelectedDuplicatePhotos() async {
    int freedBytes = 0;
    final photosToDelete = selectedDuplicatePhotos;

    for (final photo in photosToDelete) {
      try {
        final file = File(photo.path);
        if (await file.exists()) {
          freedBytes += await file.length();
          await file.delete();
        }
      } catch (_) {
        // Skip files that can't be deleted
      }
    }

    // Remove deleted photos from groups
    _duplicateGroups = _duplicateGroups
        .map((g) {
          final remaining = g.photos.where((p) => !p.isSelected).toList();
          return g.copyWith(photos: remaining);
        })
        .where((g) => g.photos.isNotEmpty)
        .toList();

    notifyListeners();
    return freedBytes;
  }

  /// Clear all scan results.
  void clearResults() {
    _allPhotos = [];
    _blurryPhotos = [];
    _duplicateGroups = [];
    _isScanning = false;
    _scanStatus = 'Ready';
    _scanProgress = 0;
    _scanTotal = 0;
    _error = null;
    notifyListeners();
  }
}
