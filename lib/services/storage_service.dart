import 'package:flutter/services.dart';
import '../models/data_models.dart';

/// Retrieves device storage information from Android.
class StorageService {
  static const MethodChannel _channel = MethodChannel(
    'com.photocleaner/storage',
  );

  /// Gets current storage info for the device.
  ///
  /// Total, free, photo, and video sizes come from Android system APIs.
  /// App data cannot be measured without the usage-access permission, so the
  /// remaining used space is split between app data and other files.
  static Future<StorageInfo> getStorageInfo() async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
        'getStorageInfo',
      );
      if (map == null) return _getEmptyStorageInfo();

      final totalBytes = (map['totalBytes'] as num?)?.toInt() ?? 0;
      final freeBytes = (map['freeBytes'] as num?)?.toInt() ?? 0;
      if (totalBytes <= 0) return _getEmptyStorageInfo();

      final usedBytes = (totalBytes - freeBytes).clamp(0, totalBytes).toInt();
      final photosBytes = ((map['photosBytes'] as num?)?.toInt() ?? 0)
          .clamp(0, usedBytes)
          .toInt();
      final videosBytes = ((map['videosBytes'] as num?)?.toInt() ?? 0).clamp(
        0,
        usedBytes - photosBytes,
      );

      final remaining = (usedBytes - photosBytes - videosBytes)
          .clamp(0, usedBytes)
          .toInt();
      final appsBytes = (remaining * 0.65).round();
      final othersBytes = remaining - appsBytes;

      return StorageInfo(
        totalBytes: totalBytes,
        usedBytes: usedBytes,
        freeBytes: freeBytes,
        photosBytes: photosBytes,
        videosBytes: videosBytes,
        appsBytes: appsBytes,
        othersBytes: othersBytes,
      );
    } catch (_) {
      return _getEmptyStorageInfo();
    }
  }

  static StorageInfo _getEmptyStorageInfo() {
    return StorageInfo(
      totalBytes: 0,
      usedBytes: 0,
      freeBytes: 0,
      photosBytes: 0,
      videosBytes: 0,
      appsBytes: 0,
      othersBytes: 0,
    );
  }

  /// Formats bytes into human-readable string.
  static String formatBytes(int bytes) {
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
}
