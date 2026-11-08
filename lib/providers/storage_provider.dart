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
    if (_isLoading) return;
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
}
