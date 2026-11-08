import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../models/data_models.dart';

/// Detects duplicate and visually similar images using perceptual hashing.
class DuplicateDetector {
  /// Hash size for dHash (16x16 comparisons = 256-bit hash).
  static const int hashSize = 16;

  /// Similarity threshold: groups with hamming distance at or below this are
  /// considered visually similar. Lower = stricter matching.
  ///
  /// Unrelated photos typically differ by ~100+ of 256 bits, while re-saved or
  /// lightly edited copies stay well below 24.
  static const int similarityThreshold = 24;

  /// Computes a difference hash (dHash) from an already decoded image.
  ///
  /// Resizes to 17x16 grayscale and sets one bit per horizontal neighbor pair,
  /// which captures relative brightness gradients instead of absolute levels.
  /// This is far more discriminative than an average hash, especially for
  /// flat or mostly uniform images.
  static String computeHashFromImage(img.Image image) {
    try {
      // One extra column provides the right-hand neighbor for every bit.
      final resized = img.copyResize(
        image,
        width: hashSize + 1,
        height: hashSize,
        interpolation: img.Interpolation.average,
      );
      final gray = img.grayscale(resized);

      final bits = StringBuffer();
      for (int y = 0; y < hashSize; y++) {
        for (int x = 0; x < hashSize; x++) {
          final left = gray.getPixel(x, y);
          final right = gray.getPixel(x + 1, y);
          final leftLum = (left.r + left.g + left.b) / 3.0;
          final rightLum = (right.r + right.g + right.b) / 3.0;
          bits.write(leftLum > rightLum ? '1' : '0');
        }
      }

      return bits.toString();
    } catch (_) {
      return '';
    }
  }

  /// Computes a difference hash for an image file.
  static String computeHash(String path) {
    try {
      final bytes = File(path).readAsBytesSync();
      final image = img.decodeImage(bytes);
      if (image == null) return '';
      return computeHashFromImage(image);
    } catch (_) {
      return '';
    }
  }

  /// Computes Hamming distance between two equal-length binary hash strings.
  static int hammingDistance(String hash1, String hash2) {
    if (hash1.length != hash2.length) return hash1.length + hash2.length;
    int distance = 0;
    for (int i = 0; i < hash1.length; i++) {
      if (hash1[i] != hash2[i]) distance++;
    }
    return distance;
  }

  /// Returns the Hamming distance when it is within [threshold], else null.
  ///
  /// Stops comparing as soon as the threshold is exceeded, which keeps large
  /// galleries fast because most unrelated pairs differ in the first few bits.
  static int? distanceWithin(
    String hash1,
    String hash2, {
    int threshold = similarityThreshold,
  }) {
    if (hash1.length != hash2.length) return null;
    int distance = 0;
    for (int i = 0; i < hash1.length; i++) {
      if (hash1[i] != hash2[i]) {
        distance++;
        if (distance > threshold) return null;
      }
    }
    return distance;
  }

  /// Whether two hashes are within the similarity threshold.
  static bool isSimilar(
    String hash1,
    String hash2, {
    int threshold = similarityThreshold,
  }) {
    return distanceWithin(hash1, hash2, threshold: threshold) != null;
  }

  /// Groups photos into duplicate/similar groups based on perceptual hashing.
  ///
  /// Instead of comparing every pair, hashes are split into
  /// `similarityThreshold + 1` chunks. By the pigeonhole principle, two hashes
  /// within the threshold must share at least one identical chunk, so only
  /// photos in those buckets need a full distance check. This keeps large
  /// galleries fast without changing which photos are grouped.
  static List<DuplicateGroup> groupDuplicates(List<PhotoModel> photos) {
    final expectedLength = hashSize * hashSize;

    // Collect hashes computed during the gallery scan. Photos are decoded once.
    final photoHashes = <String, String>{};
    for (final photo in photos) {
      final hash = photo.perceptualHash;
      if (hash.length == expectedLength) {
        photoHashes[photo.id] = hash;
      }
    }

    final photoList = photos
        .where((p) => photoHashes.containsKey(p.id))
        .toList(growable: false);
    if (photoList.length < 2) return [];

    final chunkCount = similarityThreshold + 1;
    final chunkRanges = <List<int>>[];
    final baseLength = expectedLength ~/ chunkCount;
    final remainder = expectedLength % chunkCount;
    var cursor = 0;
    for (var chunk = 0; chunk < chunkCount; chunk++) {
      final length = baseLength + (chunk < remainder ? 1 : 0);
      chunkRanges.add([cursor, cursor + length]);
      cursor += length;
    }

    // Map each chunk value to the indices of photos that contain it.
    final buckets = <String, List<int>>{};
    for (var i = 0; i < photoList.length; i++) {
      final hash = photoHashes[photoList[i].id]!;
      for (final range in chunkRanges) {
        final key = '${range[0]}:${hash.substring(range[0], range[1])}';
        buckets.putIfAbsent(key, () => <int>[]).add(i);
      }
    }

    final groups = <DuplicateGroup>[];
    final assigned = <String>{};

    for (int i = 0; i < photoList.length; i++) {
      final photoA = photoList[i];
      if (assigned.contains(photoA.id)) continue;

      final groupPhotos = <PhotoModel>[photoA];
      assigned.add(photoA.id);

      final hashA = photoHashes[photoA.id]!;
      var distanceSum = 0;

      // Union of all buckets shared with this hash, in gallery order.
      final candidateIndices = <int>{};
      for (final range in chunkRanges) {
        final key = '${range[0]}:${hashA.substring(range[0], range[1])}';
        final matches = buckets[key];
        if (matches == null) continue;
        for (final index in matches) {
          if (index > i && !assigned.contains(photoList[index].id)) {
            candidateIndices.add(index);
          }
        }
      }
      final orderedCandidates = candidateIndices.toList()..sort();

      for (final j in orderedCandidates) {
        final photoB = photoList[j];
        final hashB = photoHashes[photoB.id]!;
        final distance = distanceWithin(hashA, hashB);
        if (distance == null) continue;

        groupPhotos.add(photoB);
        assigned.add(photoB.id);
        distanceSum += distance;
      }

      if (groupPhotos.length > 1) {
        final averageDistance = distanceSum / (groupPhotos.length - 1);
        groups.add(
          DuplicateGroup(
            groupId: photoA.id,
            photos: groupPhotos,
            isExactDuplicate: distanceSum == 0,
            similarityScore: (1.0 - averageDistance / expectedLength).clamp(
              0.0,
              1.0,
            ),
          ),
        );
      }
    }

    // Show the groups that can free the most space first.
    groups.sort((a, b) => b.savableSize.compareTo(a.savableSize));
    return groups;
  }

  /// Generates a thumbnail for preview.
  static Uint8List? generateThumbnail(String path, {int maxSize = 300}) {
    try {
      final file = File(path);
      final bytes = file.readAsBytesSync();
      final image = img.decodeImage(bytes);
      if (image == null) return null;

      final resized = img.copyResize(image, width: maxSize, height: maxSize);
      final png = img.encodePng(resized);
      return Uint8List.fromList(png);
    } catch (_) {
      return null;
    }
  }
}

/// Top-level entry point for running duplicate grouping in a background
/// isolate via `compute`.
List<DuplicateGroup> groupPhotosInIsolate(List<PhotoModel> photos) {
  return DuplicateDetector.groupDuplicates(photos);
}
