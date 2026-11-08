import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../services/blur_detector.dart';
import '../services/duplicate_detector.dart';

/// Result of analyzing one photo thumbnail.
class PhotoAnalysisResult {
  final double blurScore;
  final String hash;
  final bool decoded;

  const PhotoAnalysisResult({
    required this.blurScore,
    required this.hash,
    required this.decoded,
  });
}

/// Analyzes a batch of thumbnail JPEGs.
///
/// This is a top-level function so it can run in a background isolate via
/// `compute`, keeping image decoding off the UI thread.
List<PhotoAnalysisResult> analyzePhotoBatch(List<Uint8List?> thumbnails) {
  return thumbnails.map(_analyzeThumbnail).toList(growable: false);
}

PhotoAnalysisResult _analyzeThumbnail(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) {
    return const PhotoAnalysisResult(blurScore: 0, hash: '', decoded: false);
  }

  img.Image? decoded;
  try {
    decoded = img.decodeJpg(bytes);
  } catch (_) {
    decoded = null;
  }
  decoded ??= img.decodeImage(bytes);
  if (decoded == null) {
    return const PhotoAnalysisResult(blurScore: 0, hash: '', decoded: false);
  }

  return PhotoAnalysisResult(
    blurScore: BlurDetector.computeBlurScore(decoded),
    hash: DuplicateDetector.computeHashFromImage(decoded),
    decoded: true,
  );
}
