import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mobile_storage_cleaner/services/enhance_service.dart';

void main() {
  group('buildEnhanceMask', () {
    test('whole photo selects every pixel', () {
      final mask = buildEnhanceMask(
        width: 40,
        height: 30,
        strokes: const [],
        wholePhoto: true,
      );

      expect(mask, hasLength(40 * 30));
      expect(mask.every((value) => value == 255), isTrue);
    });

    test('a painted stroke fills its center and fades at the edge', () {
      const width = 120;
      const height = 80;
      final mask = buildEnhanceMask(
        width: width,
        height: height,
        strokes: const [
          MaskStroke(points: [0.5, 0.5], radius: 0.25),
        ],
      );

      expect(mask[40 * width + 60], 255);
      expect(mask[40 * width + 60 + 40], 0);
      final feathered = mask[40 * width + 60 + 25];
      expect(feathered, greaterThan(0));
      expect(feathered, lessThan(255));
      expect(mask[0], 0);
    });

    test('an eraser removes the painted coverage', () {
      final mask = buildEnhanceMask(
        width: 120,
        height: 80,
        strokes: const [
          MaskStroke(points: [0.5, 0.5], radius: 0.25),
          MaskStroke(points: [0.5, 0.5], radius: 0.25, erase: true),
        ],
      );

      expect(mask[40 * 120 + 60], 0);
    });

    test('strokes are bounded by the image edges', () {
      final mask = buildEnhanceMask(
        width: 32,
        height: 32,
        strokes: const [
          MaskStroke(points: [0, 0], radius: 0.5),
        ],
      );

      expect(mask, hasLength(32 * 32));
      expect(mask[0], 255);
      expect(mask[31 * 32 + 31], 0);
    });
  });

  group('enhanceImageBytes', () {
    test('leaves pixels untouched when no area is painted', () {
      final source = img.Image(width: 32, height: 32);
      img.fill(source, color: img.ColorRgb8(70, 110, 150));
      final encoded = img.encodeJpg(source, quality: 100);

      final result = enhanceImageBytes(
        encoded,
        strokes: const [],
        strength: 0.8,
        wholePhoto: false,
        maxDimension: 32,
        quality: 100,
      );
      final decoded = img.decodeJpg(result);

      expect(decoded, isNotNull);
      expect(decoded!.width, 32);
      expect(decoded.height, 32);
      final pixel = decoded.getPixel(16, 16);
      expect((pixel.r - 70).abs(), lessThanOrEqualTo(3));
      expect((pixel.g - 110).abs(), lessThanOrEqualTo(3));
      expect((pixel.b - 150).abs(), lessThanOrEqualTo(3));
    });

    test('whole-photo enhancement sharpens an edge and keeps the size', () {
      final source = img.Image(width: 32, height: 32);
      for (var y = 0; y < 32; y++) {
        for (var x = 0; x < 32; x++) {
          final bright = (x ~/ 4 + y ~/ 4).isEven;
          source.setPixelRgb(
            x,
            y,
            bright ? 210 : 40,
            bright ? 210 : 40,
            bright ? 210 : 40,
          );
        }
      }
      final encoded = img.encodeJpg(source, quality: 95);

      final result = enhanceImageBytes(
        encoded,
        strokes: const [],
        strength: 1,
        wholePhoto: true,
        maxDimension: 32,
        quality: 95,
      );
      final decoded = img.decodeJpg(result);
      final original = img.decodeJpg(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.width, 32);
      expect(decoded.height, 32);

      var maxDifference = 0;
      for (var y = 0; y < 32; y++) {
        for (var x = 0; x < 32; x++) {
          final before = original!.getPixel(x, y);
          final after = decoded.getPixel(x, y);
          final difference = (after.r - before.r).abs().toInt();
          if (difference > maxDifference) maxDifference = difference;
        }
      }
      expect(maxDifference, greaterThan(5));
    });

    test('the default strength produces a noticeable change', () {
      final source = img.Image(width: 64, height: 64);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final bright = (x ~/ 8 + y ~/ 8).isEven;
          source.setPixelRgb(
            x,
            y,
            bright ? 190 : 120,
            bright ? 190 : 120,
            bright ? 190 : 120,
          );
        }
      }
      final encoded = img.encodeJpg(source, quality: 95);

      final result = enhanceImageBytes(
        encoded,
        strokes: const [],
        strength: 0.75,
        wholePhoto: true,
        maxDimension: 64,
        quality: 95,
      );
      final decoded = img.decodeJpg(result)!;
      final original = img.decodeJpg(encoded)!;

      var maxDifference = 0;
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final difference =
              (decoded.getPixel(x, y).r - original.getPixel(x, y).r)
                  .abs()
                  .toInt();
          if (difference > maxDifference) maxDifference = difference;
        }
      }
      expect(maxDifference, greaterThan(12));
    });

    test('rejects bytes that are not an image', () {
      expect(
        () => enhanceImageBytes(
          Uint8List.fromList([1, 2, 3, 4]),
          strokes: const [],
          strength: 0.5,
          wholePhoto: true,
          maxDimension: 32,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('100% strength applies more detail than the 75% default', () {
      final encoded = img.encodeJpg(
        _checkerboardImage(width: 64, height: 64, block: 8),
        quality: 95,
      );
      final original = img.decodeJpg(encoded)!;

      double detailAmount(double strength) {
        final result = img.decodeJpg(
          enhanceImageBytes(
            encoded,
            strokes: const [],
            strength: strength,
            wholePhoto: true,
            maxDimension: 64,
            quality: 95,
          ),
        )!;
        var total = 0.0;
        for (var y = 0; y < 64; y++) {
          for (var x = 0; x < 64; x++) {
            total += (result.getPixel(x, y).r - original.getPixel(x, y).r)
                .abs();
          }
        }
        return total / (64 * 64);
      }

      final defaultValue = detailAmount(0.75);
      final maximumValue = detailAmount(1);

      expect(defaultValue, greaterThan(0.5));
      expect(maximumValue, greaterThan(defaultValue));
    });
  });

  group('ManualAdjustments', () {
    test('identifies neutral values and copies selected controls', () {
      expect(ManualAdjustments.neutral.isNeutral, isTrue);
      expect(const ManualAdjustments(lighting: 20).isNeutral, isFalse);

      final adjusted = ManualAdjustments.neutral.copyWith(
        lighting: 25,
        sharpness: 60,
        hue: -30,
      );

      expect(adjusted.isNeutral, isFalse);
      expect(adjusted.lighting, 25);
      expect(adjusted.sharpness, 60);
      expect(adjusted.hue, -30);
      expect(adjusted.contrast, 0);
      expect(adjusted.temperature, 0);
    });
  });

  group('enhanceManualImageBytes', () {
    test('neutral adjustments leave the photo unchanged', () {
      final encoded = img.encodeJpg(
        _gradientImage(width: 64, height: 64),
        quality: 100,
      );
      final result = enhanceManualImageBytes(
        encoded,
        adjustments: ManualAdjustments.neutral,
        maxDimension: 64,
        quality: 100,
      );
      final original = img.decodeJpg(encoded)!;
      final decoded = img.decodeJpg(result)!;

      expect(decoded.width, 64);
      expect(decoded.height, 64);
      var maxDifference = 0;
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final before = original.getPixel(x, y);
          final after = decoded.getPixel(x, y);
          final difference = (after.r - before.r).abs().toInt();
          if (difference > maxDifference) maxDifference = difference;
        }
      }
      expect(maxDifference, lessThanOrEqualTo(3));
    });

    test('lighting brightens or darkens the whole frame', () {
      final encoded = _encodedFlat(img.ColorRgb8(128, 128, 128));
      final original = img.decodeJpg(encoded)!;
      final baseLuma = _meanLuma(original);

      final brighter = img.decodeJpg(
        _renderManual(encoded, const ManualAdjustments(lighting: 60)),
      )!;
      final darker = img.decodeJpg(
        _renderManual(encoded, const ManualAdjustments(lighting: -60)),
      )!;

      expect(_meanLuma(brighter), greaterThan(baseLuma + 10));
      expect(_meanLuma(darker), lessThan(baseLuma - 10));
    });

    test('contrast deepens or flattens the tonal range', () {
      final source = img.Image(width: 64, height: 64);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final value = x < 32 ? 80 : 180;
          source.setPixelRgb(x, y, value, value, value);
        }
      }
      final encoded = img.encodeJpg(source, quality: 100);

      double tonalRange(ManualAdjustments adjustments) {
        final image = img.decodeJpg(_renderManual(encoded, adjustments))!;
        return _meanLuma(image, x0: 40) - _meanLuma(image, x1: 24);
      }

      final neutralRange = tonalRange(ManualAdjustments.neutral);
      final deepRange = tonalRange(const ManualAdjustments(contrast: 70));
      final flatRange = tonalRange(const ManualAdjustments(contrast: -70));

      expect(deepRange, greaterThan(neutralRange + 20));
      expect(flatRange, lessThan(neutralRange - 10));
    });

    test('saturation can remove or boost color', () {
      final encoded = _encodedFlat(img.ColorRgb8(90, 130, 170));
      final grayscale = img.decodeJpg(
        _renderManual(encoded, const ManualAdjustments(saturation: -100)),
      )!;
      final vivid = img.decodeJpg(
        _renderManual(encoded, const ManualAdjustments(saturation: 80)),
      )!;

      final grayPixel = grayscale.getPixel(32, 32);
      final graySpread =
          [grayPixel.r, grayPixel.g, grayPixel.b].reduce(math.max) -
          [grayPixel.r, grayPixel.g, grayPixel.b].reduce(math.min);
      expect(graySpread, lessThanOrEqualTo(3));

      final vividPixel = vivid.getPixel(32, 32);
      final vividSpread =
          [vividPixel.r, vividPixel.g, vividPixel.b].reduce(math.max) -
          [vividPixel.r, vividPixel.g, vividPixel.b].reduce(math.min);
      expect(vividSpread, greaterThan(110));
    });

    test('hue rotates the color channels', () {
      final encoded = _encodedFlat(img.ColorRgb8(200, 40, 40));
      final rotated = img.decodeJpg(
        _renderManual(encoded, const ManualAdjustments(hue: 120)),
      )!;
      final pixel = rotated.getPixel(32, 32);

      expect(pixel.g, greaterThan(50));
      expect(pixel.r, lessThan(120));
    });

    test('temperature warms or cools the white balance', () {
      final encoded = _encodedFlat(img.ColorRgb8(120, 120, 120));
      final warm = img
          .decodeJpg(
            _renderManual(encoded, const ManualAdjustments(temperature: 80)),
          )!
          .getPixel(32, 32);
      final cool = img
          .decodeJpg(
            _renderManual(encoded, const ManualAdjustments(temperature: -80)),
          )!
          .getPixel(32, 32);

      expect(warm.r - warm.b, greaterThan(30));
      expect(cool.b - cool.r, greaterThan(30));
    });

    test('highlights recover bright areas without crushing shadows', () {
      final source = img.Image(width: 64, height: 64);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final value = x < 32 ? 220 : 40;
          source.setPixelRgb(x, y, value, value, value);
        }
      }
      final encoded = img.encodeJpg(source, quality: 100);
      final recovered = img.decodeJpg(
        _renderManual(encoded, const ManualAdjustments(highlights: -100)),
      )!;

      final brightBefore = _meanLuma(img.decodeJpg(encoded)!, x1: 16);
      final brightAfter = _meanLuma(recovered, x1: 16);
      final shadowBefore = _meanLuma(img.decodeJpg(encoded)!, x0: 48);
      final shadowAfter = _meanLuma(recovered, x0: 48);

      expect(brightAfter, lessThan(brightBefore - 40));
      expect((shadowAfter - shadowBefore).abs(), lessThan(3));
    });

    test('sharpness adds fine local detail', () {
      final encoded = img.encodeJpg(
        _checkerboardImage(width: 64, height: 64, block: 8),
        quality: 100,
      );
      final original = img.decodeJpg(encoded)!;
      final sharpened = img.decodeJpg(
        _renderManual(encoded, const ManualAdjustments(sharpness: 100)),
      )!;

      expect(_maxChannelDifference(original, sharpened), greaterThan(15));
    });

    test('clarity adds wider local contrast', () {
      final encoded = img.encodeJpg(
        _checkerboardImage(width: 64, height: 64, block: 16),
        quality: 100,
      );
      final original = img.decodeJpg(encoded)!;
      final clarified = img.decodeJpg(
        _renderManual(encoded, const ManualAdjustments(clarity: 100)),
      )!;

      expect(_maxChannelDifference(original, clarified), greaterThan(10));
    });
  });
}

img.Image _gradientImage({required int width, required int height}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(
        x,
        y,
        (x * 255 / (width - 1)).round(),
        (y * 255 / (height - 1)).round(),
        ((x + y) * 255 / (width + height - 2)).round(),
      );
    }
  }
  return image;
}

img.Image _checkerboardImage({
  required int width,
  required int height,
  required int block,
}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final bright = (x ~/ block + y ~/ block).isEven;
      final value = bright ? 210 : 45;
      image.setPixelRgb(x, y, value, value, value);
    }
  }
  return image;
}

Uint8List _encodedFlat(img.Color color) {
  final image = img.Image(width: 64, height: 64);
  img.fill(image, color: color);
  return img.encodeJpg(image, quality: 100);
}

Uint8List _renderManual(Uint8List encoded, ManualAdjustments adjustments) {
  return enhanceManualImageBytes(
    encoded,
    adjustments: adjustments,
    maxDimension: 64,
    quality: 100,
  );
}

double _meanLuma(img.Image image, {int x0 = 0, int x1 = 64}) {
  var total = 0.0;
  var count = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = x0; x < x1 && x < image.width; x++) {
      final pixel = image.getPixel(x, y);
      total += 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
      count++;
    }
  }
  return count == 0 ? 0 : total / count;
}

int _maxChannelDifference(img.Image before, img.Image after) {
  var maxDifference = 0;
  for (var y = 0; y < before.height; y++) {
    for (var x = 0; x < before.width; x++) {
      final a = before.getPixel(x, y);
      final b = after.getPixel(x, y);
      for (final difference in [
        (b.r - a.r).abs().toInt(),
        (b.g - a.g).abs().toInt(),
        (b.b - a.b).abs().toInt(),
      ]) {
        if (difference > maxDifference) maxDifference = difference;
      }
    }
  }
  return maxDifference;
}
