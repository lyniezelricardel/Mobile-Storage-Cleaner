import 'dart:async';
import 'package:flutter/material.dart';
import '../models/data_models.dart';
import '../services/storage_service.dart';

/// Manages storage information and refreshes it after deletions.
class StorageProvider extends ChangeNotifier {
  StorageInfo _storageInfo = StorageInfo(
    totalBytes: 0,
    usedBytes: 0,
    freeBytes: 0,
    photosBytes: 0,
    videosBytes: 0,
    appsBytes: 0,
    othersBytes: 0,
  );
  bool _isLoading = false;
  String? _error;

  StorageInfo get storageInfo => _storageInfo;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Refresh storage info from the device.
  Future<void> refreshStorage() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _storageInfo = await StorageService.getStorageInfo();
    } catch (e) {
      _error = e.toString();
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Simulate storage update after deletion (subtracts freed bytes).
  /// In production, call refreshStorage() after actual deletion.
  void updateAfterDeletion(int bytesFreed) {
    _storageInfo = StorageInfo(
      totalBytes: _storageInfo.totalBytes,
      usedBytes: (_storageInfo.usedBytes - bytesFreed).clamp(
        0,
        _storageInfo.totalBytes,
      ),
      freeBytes: _storageInfo.freeBytes + bytesFreed,
      photosBytes: (_storageInfo.photosBytes - (bytesFreed * 0.4).round())
          .clamp(0, _storageInfo.usedBytes),
      videosBytes: (_storageInfo.videosBytes - (bytesFreed * 0.25).round())
          .clamp(0, _storageInfo.usedBytes),
      appsBytes: (_storageInfo.appsBytes - (bytesFreed * 0.2).round()).clamp(
        0,
        _storageInfo.usedBytes,
      ),
      othersBytes: _storageInfo.othersBytes.clamp(0, _storageInfo.usedBytes),
    );
    notifyListeners();
  }
}
