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

  /// Groups photos into duplicate/similar groups based on perceptual hashing.
  static List<DuplicateGroup> groupDuplicates(List<PhotoModel> photos) {
    // Collect hashes computed during the gallery scan. Photos are decoded once.
    final photoHashes = <String, String>{};
    for (final photo in photos) {
      if (photo.perceptualHash.isNotEmpty) {
        photoHashes[photo.id] = photo.perceptualHash;
      }
    }

    final groups = <DuplicateGroup>[];
    final assigned = <String>{};

    final photoList = photos
        .where((p) => photoHashes.containsKey(p.id))
        .toList();

    for (int i = 0; i < photoList.length; i++) {
      final photoA = photoList[i];
      if (assigned.contains(photoA.id)) continue;

      final groupPhotos = <PhotoModel>[photoA];
      assigned.add(photoA.id);

      final hashA = photoHashes[photoA.id]!;
      var distanceSum = 0;

      for (int j = i + 1; j < photoList.length; j++) {
        final photoB = photoList[j];
        if (assigned.contains(photoB.id)) continue;

        final hashB = photoHashes[photoB.id]!;
        final distance = hammingDistance(hashA, hashB);

        if (distance <= similarityThreshold) {
          groupPhotos.add(photoB);
          assigned.add(photoB.id);
          distanceSum += distance;
        }
      }

      if (groupPhotos.length > 1) {
        final averageDistance = distanceSum / (groupPhotos.length - 1);
        groups.add(
          DuplicateGroup(
            groupId: photoA.id,
            photos: groupPhotos,
            isExactDuplicate: distanceSum == 0,
            similarityScore: (1.0 - averageDistance / (hashSize * hashSize))
                .clamp(0.0, 1.0),
          ),
        );
      }
    }

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
