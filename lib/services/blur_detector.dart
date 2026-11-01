import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../models/data_models.dart';

/// Detects blurry images using focus measures (Laplacian variance and gradient).
class BlurDetector {
  /// Threshold below which an image is considered blurry.
  /// Lower values = more sensitive to blur.
  static const double blurThreshold = 100.0;

  /// Analyzes an image file and returns a blur score and whether it's blurry.
  ///
  /// Uses grayscale conversion and Laplacian-like variance on the image.
  /// Higher variance = sharper image; lower variance = blurrier image.
  static PhotoModel analyzeImage({
    required String path,
    required String id,
    required DateTime dateTaken,
    required String mimeType,
    int fileSize = 0,
  }) {
    try {
      final file = File(path);
      final bytes = file.readAsBytesSync();

      // Decode the image
      final image = img.decodeImage(bytes);
      if (image == null) {
        return _createFallbackPhoto(
          id: id,
          path: path,
          dateTaken: dateTaken,
          mimeType: mimeType,
          fileSize: fileSize,
          error: 'Unable to decode image',
        );
      }

      // Resize to a manageable size for analysis and compute the focus measure.
      final blurScore = computeBlurScore(image);

      final isBlurry = blurScore < blurThreshold;

      return PhotoModel(
        id: id,
        path: path,
        thumbnailPath: path,
        fileSize: fileSize,
        blurScore: blurScore,
        isBlurry: isBlurry,
        dateTaken: dateTaken,
        mimeType: mimeType,
      );
    } catch (e) {
      return _createFallbackPhoto(
        id: id,
        path: path,
        dateTaken: dateTaken,
        mimeType: mimeType,
        fileSize: fileSize,
        error: e.toString(),
      );
    }
  }

  /// Computes the Laplacian variance focus score for an already decoded image.
  ///
  /// Higher scores mean sharper images; lower scores mean blurrier images.
  static double computeBlurScore(img.Image image) {
    // Analyze at a bounded size so large camera photos stay fast.
    final resized = img.copyResize(image, width: 300);
    final gray = img.grayscale(resized);
    return _computeLaplacianVariance(gray);
  }

  /// Computes Laplacian variance on a grayscale image.
  /// This is a common focus measure: sharp edges produce high variance.
  static double _computeLaplacianVariance(img.Image gray) {
    final width = gray.width;
    final height = gray.height;

    // Laplacian kernel
    const laplacian = [
      [0, 1, 0],
      [1, -4, 1],
      [0, 1, 0],
    ];

    double sum = 0;
    double sumSq = 0;
    int count = 0;

    for (int y = 1; y < height - 1; y++) {
      for (int x = 1; x < width - 1; x++) {
        double laplacianValue = 0;

        for (int ky = -1; ky <= 1; ky++) {
          for (int kx = -1; kx <= 1; kx++) {
            final pixel = gray.getPixel(x + kx, y + ky);
            final intensity = (pixel.r + pixel.g + pixel.b) / 3.0;
            laplacianValue += intensity * laplacian[ky + 1][kx + 1];
          }
        }

        sum += laplacianValue;
        sumSq += laplacianValue * laplacianValue;
        count++;
      }
    }

    if (count == 0) return 0.0;

    final mean = sum / count;
    final variance = (sumSq / count) - (mean * mean);

    // Scale variance to a reasonable 0-1000+ range
    return variance.clamp(0, double.infinity);
  }

  static PhotoModel _createFallbackPhoto({
    required String id,
    required String path,
    required DateTime dateTaken,
    required String mimeType,
    required int fileSize,
    required String error,
  }) {
    return PhotoModel(
      id: id,
      path: path,
      thumbnailPath: path,
      fileSize: fileSize,
      blurScore: 0,
      isBlurry: false,
      dateTaken: dateTaken,
      mimeType: mimeType,
    );
  }

  /// Generates a thumbnail Uint8List for a given image path.
  static Uint8List? generateThumbnail(String path, {int maxSize = 200}) {
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
