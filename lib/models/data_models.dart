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
    required this.mimeType,
    this.perceptualHash = '',
  });

  PhotoModel copyWith({
    String? id,
    String? path,
    String? thumbnailPath,
    int? fileSize,
    double? blurScore,
    bool? isBlurry,
    bool? isSelected,
    DateTime? dateTaken,
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

  /// Size that would be freed if all but one photo in group are deleted.
  int get savableSize {
    if (photos.length <= 1) return 0;
    // Keep the largest (assumed best quality), delete the rest
    final sorted = List<PhotoModel>.from(photos)
      ..sort((a, b) => b.fileSize.compareTo(a.fileSize));
    return sorted.skip(1).fold(0, (sum, p) => sum + p.fileSize);
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
