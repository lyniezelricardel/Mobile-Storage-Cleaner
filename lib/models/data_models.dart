import 'dart:typed_data';

/// Represents a photo scanned from the device gallery.
class PhotoModel {
  final String id;
  final String path;
  final String? thumbnailPath;
  final int fileSize; // bytes
  final double blurScore; // 0 = very blurry, higher = sharper
  final bool isBlurry;
  final bool isSelected;
  final DateTime dateTaken;
  final DateTime modifiedAt;
  final String mimeType;
  final String perceptualHash; // 256-bit dHash, empty if unavailable

  PhotoModel({
    required this.id,
    required this.path,
    this.thumbnailPath,
    required this.fileSize,
    required this.blurScore,
    required this.isBlurry,
    this.isSelected = false,
    required this.dateTaken,
    DateTime? modifiedAt,
    required this.mimeType,
    this.perceptualHash = '',
  }) : modifiedAt = modifiedAt ?? dateTaken;

  PhotoModel copyWith({
    String? id,
    String? path,
    String? thumbnailPath,
    int? fileSize,
    double? blurScore,
    bool? isBlurry,
    bool? isSelected,
    DateTime? dateTaken,
    DateTime? modifiedAt,
    String? mimeType,
    String? perceptualHash,
  }) {
    return PhotoModel(
      id: id ?? this.id,
      path: path ?? this.path,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      fileSize: fileSize ?? this.fileSize,
      blurScore: blurScore ?? this.blurScore,
      isBlurry: isBlurry ?? this.isBlurry,
      isSelected: isSelected ?? this.isSelected,
      dateTaken: dateTaken ?? this.dateTaken,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      mimeType: mimeType ?? this.mimeType,
      perceptualHash: perceptualHash ?? this.perceptualHash,
    );
  }

  /// Human-readable file size string.
  String get sizeString {
    if (fileSize >= 1048576) {
      return '${(fileSize / 1048576).toStringAsFixed(1)} MB';
    } else if (fileSize >= 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    } else {
      return '$fileSize B';
    }
  }

  /// Total size of all selected photos in bytes.
  static int totalSelectedSize(List<PhotoModel> photos) {
    return photos
        .where((p) => p.isSelected)
        .fold(0, (sum, p) => sum + p.fileSize);
  }
}

/// Represents a group of duplicate/similar photos.
class DuplicateGroup {
  final String groupId;
  final List<PhotoModel> photos;
  final bool isExactDuplicate;
  final double similarityScore;

  DuplicateGroup({
    required this.groupId,
    required this.photos,
    this.isExactDuplicate = false,
    this.similarityScore = 0.0,
  });

  DuplicateGroup copyWith({
    String? groupId,
    List<PhotoModel>? photos,
    bool? isExactDuplicate,
    double? similarityScore,
  }) {
    return DuplicateGroup(
      groupId: groupId ?? this.groupId,
      photos: photos ?? this.photos,
      isExactDuplicate: isExactDuplicate ?? this.isExactDuplicate,
      similarityScore: similarityScore ?? this.similarityScore,
    );
  }

  int get selectedCount => photos.where((p) => p.isSelected).length;

  int get totalSize => photos.fold(0, (sum, p) => sum + p.fileSize);

  /// The copy most likely to be the best quality.
  ///
  /// Uses the same rule as [savableSize]: largest file first, then the higher
  /// sharpness score, then the newest photo. Keeping this in one place means
  /// the BEST badge, the displayed order, and "Keep best, select rest" always
  /// agree.
  PhotoModel get bestPhoto {
    if (photos.isEmpty) {
      throw StateError('A duplicate group must contain at least one photo.');
    }
    return photos.reduce(
      (best, candidate) => _isBetter(candidate, best) ? candidate : best,
    );
  }

  /// The group photos with [bestPhoto] first, so the BEST tile is always on
  /// the left in the horizontal card and compare dialog.
  List<PhotoModel> get photosBestFirst {
    if (photos.length < 2) return photos;
    final best = bestPhoto;
    return [best, ...photos.where((photo) => photo.id != best.id)];
  }

  /// Copies of the photos with every copy selected except [bestPhoto].
  ///
  /// This backs "Keep best, select rest", so the copy the UI marks BEST is
  /// never marked for deletion.
  List<PhotoModel> get photosAllButBestSelected {
    final best = bestPhoto;
    return photos
        .map((photo) => photo.copyWith(isSelected: photo.id != best.id))
        .toList(growable: false);
  }

  /// Size of the extra copies that could be moved to the trash.
  int get savableSize {
    if (photos.length <= 1) return 0;
    final best = bestPhoto;
    return photos
        .where((photo) => photo.id != best.id)
        .fold(0, (sum, photo) => sum + photo.fileSize);
  }

  static bool _isBetter(PhotoModel candidate, PhotoModel current) {
    if (candidate.fileSize != current.fileSize) {
      return candidate.fileSize > current.fileSize;
    }
    if (candidate.blurScore != current.blurScore) {
      return candidate.blurScore > current.blurScore;
    }
    return candidate.dateTaken.isAfter(current.dateTaken);
  }
}

/// Storage breakdown information.
class StorageInfo {
  final int totalBytes;
  final int usedBytes;
  final int freeBytes;
  final int photosBytes;
  final int videosBytes;
  final int appsBytes;
  final int othersBytes;

  StorageInfo({
    required this.totalBytes,
    required this.usedBytes,
    required this.freeBytes,
    required this.photosBytes,
    required this.videosBytes,
    required this.appsBytes,
    required this.othersBytes,
  });

  double get usedPercent => totalBytes > 0 ? (usedBytes / totalBytes) * 100 : 0;
  double get freePercent => totalBytes > 0 ? (freeBytes / totalBytes) * 100 : 0;

  String formatBytes(int bytes) {
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    } else if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else {
      return '$bytes B';
    }
  }

  String get totalString => formatBytes(totalBytes);
  String get usedString => formatBytes(usedBytes);
  String get freeString => formatBytes(freeBytes);
  String get photosString => formatBytes(photosBytes);
  String get videosString => formatBytes(videosBytes);
  String get appsString => formatBytes(appsBytes);
  String get othersString => formatBytes(othersBytes);
}

/// A photo that currently sits in Android's system trash.
///
/// Android hides trashed assets from normal MediaStore queries, so everything
/// the Recently Deleted screen needs is cached here, including a small
/// thumbnail that keeps working after a restart.
class TrashedPhoto {
  final String id;
  final String path;
  final int fileSize;
  final DateTime dateTaken;
  final String mimeType;
  final int typeInt;
  final int width;
  final int height;
  final DateTime trashedAt;
  final DateTime expiresAt;
  final Uint8List? thumbnail;

  const TrashedPhoto({
    required this.id,
    required this.path,
    required this.fileSize,
    required this.dateTaken,
    required this.mimeType,
    this.typeInt = 1,
    this.width = 0,
    this.height = 0,
    required this.trashedAt,
    required this.expiresAt,
    this.thumbnail,
  });

  String get fileName {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty || parts.last.isEmpty ? 'Photo' : parts.last;
  }

  String get sizeString {
    if (fileSize >= 1048576) {
      return '${(fileSize / 1048576).toStringAsFixed(1)} MB';
    } else if (fileSize >= 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    return '$fileSize B';
  }

  /// Whole days left before Android may remove the file for good.
  int get daysLeft {
    final remaining = expiresAt.difference(DateTime.now()).inDays;
    return remaining < 0 ? 0 : remaining;
  }

  String get expiryLabel {
    final days = daysLeft;
    if (days <= 0) return 'Expires today';
    return 'Expires in $days ${days == 1 ? 'day' : 'days'}';
  }
}

/// Outcome of moving photos into Android's system trash.
class TrashResult {
  final int requestedCount;
  final int trashedCount;
  final List<TrashedPhoto> trashedPhotos;
  final bool canceled;
  final String? error;

  const TrashResult({
    this.requestedCount = 0,
    this.trashedCount = 0,
    this.trashedPhotos = const [],
    this.canceled = false,
    this.error,
  });

  bool get success => trashedCount > 0 && error == null;
  bool get partial => trashedCount > 0 && trashedCount < requestedCount;

  int get trashedBytes =>
      trashedPhotos.fold(0, (sum, photo) => sum + photo.fileSize);
}

/// Outcome of restoring photos from Android's system trash.
class RestoreResult {
  final int requestedCount;
  final int restoredCount;
  final bool canceled;
  final String? error;

  const RestoreResult({
    this.requestedCount = 0,
    this.restoredCount = 0,
    this.canceled = false,
    this.error,
  });

  bool get success => restoredCount > 0 && error == null;
  bool get partial => restoredCount > 0 && restoredCount < requestedCount;
}

/// Outcome of permanently deleting photos from Android's system trash.
class PermanentDeleteResult {
  final int requestedCount;
  final List<TrashedPhoto> deletedPhotos;
  final bool canceled;
  final String? error;

  const PermanentDeleteResult({
    this.requestedCount = 0,
    this.deletedPhotos = const [],
    this.canceled = false,
    this.error,
  });

  int get deletedCount => deletedPhotos.length;
  int get deletedBytes =>
      deletedPhotos.fold(0, (sum, photo) => sum + photo.fileSize);
  bool get success => deletedPhotos.isNotEmpty && error == null;
  bool get partial =>
      deletedPhotos.isNotEmpty && deletedPhotos.length < requestedCount;
}
