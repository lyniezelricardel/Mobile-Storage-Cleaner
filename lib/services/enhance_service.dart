import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:photo_manager/photo_manager.dart';

/// One painted or erased stroke in normalized image coordinates.
///
/// [points] stores pairs of x and y values in the 0..1 range. [radius] is the
/// brush radius as a fraction of the image width, so the same stroke works on
/// both the on-screen preview and the full-resolution export.
class MaskStroke {
  final List<double> points;
  final double radius;
  final bool erase;

  const MaskStroke({
    required this.points,
    required this.radius,
    this.erase = false,
  });
}

/// A display-ready preview and its pixel dimensions.
class EnhancePreview {
  final Uint8List bytes;
  final int width;
  final int height;

  const EnhancePreview({
    required this.bytes,
    required this.width,
    required this.height,
  });

  double get aspectRatio => height == 0 ? 1 : width / height;
}

/// Manual tonal and detail adjustments for the whole photo.
///
/// Values are kept in the same units the sliders use so the UI and the
/// renderer stay in sync. A neutral adjustment leaves the photo unchanged.
class ManualAdjustments {
  /// Exposure-like brightness, -100 darkens and +100 lifts.
  final double lighting;

  /// Fine-detail sharpening, 0 leaves detail alone and 100 is the maximum.
  final double sharpness;

  /// Global contrast around mid-gray, -100 flattens and +100 deepens.
  final double contrast;

  /// Wide-radius local contrast, 0 leaves it alone and 100 is the maximum.
  final double clarity;

  /// Color intensity, -100 is grayscale and +100 is double saturation.
  final double saturation;

  /// Hue rotation in degrees, -180 to +180.
  final double hue;

  /// Bright-area recovery or lift, -100 recovers and +100 lifts.
  final double highlights;

  /// White balance shift, -100 cools and +100 warms.
  final double temperature;

  const ManualAdjustments({
    this.lighting = 0,
    this.sharpness = 0,
    this.contrast = 0,
    this.clarity = 0,
    this.saturation = 0,
    this.hue = 0,
    this.highlights = 0,
    this.temperature = 0,
  });

  static const ManualAdjustments neutral = ManualAdjustments();

  bool get isNeutral =>
      lighting == 0 &&
      sharpness == 0 &&
      contrast == 0 &&
      clarity == 0 &&
      saturation == 0 &&
      hue == 0 &&
      highlights == 0 &&
      temperature == 0;

  ManualAdjustments copyWith({
    double? lighting,
    double? sharpness,
    double? contrast,
    double? clarity,
    double? saturation,
    double? hue,
    double? highlights,
    double? temperature,
  }) {
    return ManualAdjustments(
      lighting: lighting ?? this.lighting,
      sharpness: sharpness ?? this.sharpness,
      contrast: contrast ?? this.contrast,
      clarity: clarity ?? this.clarity,
      saturation: saturation ?? this.saturation,
      hue: hue ?? this.hue,
      highlights: highlights ?? this.highlights,
      temperature: temperature ?? this.temperature,
    );
  }
}

/// On-device enhancement for blurry photos.
///
/// The painted mask limits a multi-scale sharpening and local-contrast pass to
/// the area the user selected. This is a classical image filter: it recovers
/// detail that is already in the photo and never invents new content.
class EnhanceService {
  static const int previewMaxSize = 1800;
  static const int saveMaxSize = 2880;
  static const int previewQuality = 92;
  static const int saveQuality = 95;

  /// Small, fast source for live manual-preview updates while the sliders move.
  static const int livePreviewMaxSize = 800;
  static const int livePreviewQuality = 80;
  static const int liveSourceQuality = 88;

  /// Extra-small frame used while a slider is actively being dragged, so the
  /// photo can respond before the user lifts their finger.
  static const int fastLivePreviewMaxSize = 480;
  static const int fastLivePreviewQuality = 68;

  /// Input size used for cloud enhancement. The API accepts at most one
  /// megapixel, so a bounded thumbnail avoids decoding a full camera file.
  static const int aiInputMaxSize = 1536;

  /// Loads a bounded preview without decoding the full camera file.
  static Future<EnhancePreview> loadPreview({
    required String photoId,
    required String path,
  }) async {
    final native = await _nativeThumbnail(
      photoId,
      previewMaxSize,
      previewQuality,
    );
    if (native != null) {
      try {
        return await compute(
          _inspectJpeg,
          native,
          debugLabel: 'enhance-preview',
        );
      } catch (_) {
        // Fall back to the original file below.
      }
    }

    final bytes = await File(path).readAsBytes();
    return compute(
      _normalizeToJpeg,
      _NormalizeRequest(
        bytes: bytes,
        maxDimension: previewMaxSize,
        quality: previewQuality,
      ),
      debugLabel: 'enhance-preview-file',
    );
  }

  /// Runs the enhancement on the already-loaded preview for a fast result.
  static Future<Uint8List> renderPreview({
    required Uint8List previewBytes,
    required List<MaskStroke> strokes,
    required double strength,
    required bool wholePhoto,
  }) {
    return compute(
      _enhanceRequest,
      _EnhanceRequest(
        sourceBytes: previewBytes,
        strokes: strokes,
        strength: strength,
        wholePhoto: wholePhoto,
        maxDimension: previewMaxSize,
        quality: previewQuality,
      ),
      debugLabel: 'enhance-preview-render',
    );
  }

  /// Runs the enhancement at export resolution.
  static Future<Uint8List> renderEnhanced({
    required String photoId,
    required String path,
    required List<MaskStroke> strokes,
    required double strength,
    required bool wholePhoto,
  }) async {
    final native = await _nativeThumbnail(photoId, saveMaxSize, 95);
    final source = native ?? await File(path).readAsBytes();
    return compute(
      _enhanceRequest,
      _EnhanceRequest(
        sourceBytes: source,
        strokes: strokes,
        strength: strength,
        wholePhoto: wholePhoto,
        maxDimension: saveMaxSize,
        quality: saveQuality,
      ),
      debugLabel: 'enhance-render',
    );
  }

  /// Runs the manual adjustments on the already-loaded preview.
  static Future<Uint8List> renderManualPreview({
    required Uint8List previewBytes,
    required ManualAdjustments adjustments,
  }) {
    return compute(
      _manualRequest,
      _ManualRequest(
        sourceBytes: previewBytes,
        adjustments: adjustments,
        maxDimension: previewMaxSize,
        quality: previewQuality,
      ),
      debugLabel: 'enhance-manual-preview',
    );
  }

  /// Prepares a small source once so live previews only decode a bounded image.
  static Future<Uint8List> prepareManualLiveSource(
    Uint8List previewBytes,
  ) async {
    final prepared = await compute(
      _normalizeToJpeg,
      _NormalizeRequest(
        bytes: previewBytes,
        maxDimension: livePreviewMaxSize,
        quality: liveSourceQuality,
      ),
      debugLabel: 'enhance-manual-live-source',
    );
    return prepared.bytes;
  }

  /// Renders a fast, lower-resolution preview for live slider feedback.
  ///
  /// [fast] is used while a slider is held: the frame is smaller and encoded
  /// more aggressively so it can appear during the drag instead of after it.
  static Future<Uint8List> renderManualLivePreview({
    required Uint8List previewBytes,
    required ManualAdjustments adjustments,
    bool fast = false,
  }) {
    return compute(
      _manualRequest,
      _ManualRequest(
        sourceBytes: previewBytes,
        adjustments: adjustments,
        maxDimension: fast ? fastLivePreviewMaxSize : livePreviewMaxSize,
        quality: fast ? fastLivePreviewQuality : livePreviewQuality,
      ),
      debugLabel: 'enhance-manual-live',
    );
  }

  /// Runs the manual adjustments at export resolution.
  static Future<Uint8List> renderManualEnhanced({
    required String photoId,
    required String path,
    required ManualAdjustments adjustments,
  }) async {
    final native = await _nativeThumbnail(photoId, saveMaxSize, 95);
    final source = native ?? await File(path).readAsBytes();
    return compute(
      _manualRequest,
      _ManualRequest(
        sourceBytes: source,
        adjustments: adjustments,
        maxDimension: saveMaxSize,
        quality: saveQuality,
      ),
      debugLabel: 'enhance-manual-render',
    );
  }

  /// Loads a bounded source for cloud enhancement. This is only called after
  /// the user confirms that the photo may be uploaded.
  static Future<Uint8List> loadAiSource({
    required String photoId,
    required String path,
  }) async {
    final native = await _nativeThumbnail(photoId, aiInputMaxSize, 95);
    if (native != null) return native;
    return File(path).readAsBytes();
  }

  /// Saves the enhanced result as a new image in the gallery. The original
  /// photo is never modified.
  static Future<AssetEntity> saveEnhanced(
    Uint8List bytes, {
    required String sourceName,
    String suffix = '_enhanced',
    String description = 'Enhanced with Mobile Storage Cleaner',
  }) {
    final base = _baseName(sourceName);
    final name = '$base${suffix}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    return PhotoManager.editor.saveImage(
      bytes,
      filename: name,
      title: name,
      desc: description,
      relativePath: 'Pictures/Mobile Storage Cleaner',
    );
  }

  static Future<Uint8List?> _nativeThumbnail(
    String photoId,
    int size,
    int quality,
  ) async {
    try {
      final asset = await AssetEntity.fromId(photoId);
      final bytes = await asset?.thumbnailDataWithSize(
        ThumbnailSize(size, size),
        quality: quality,
      );
      if (bytes != null && bytes.isNotEmpty) return bytes;
    } catch (_) {
      // The original file is tried next.
    }
    return null;
  }

  static String _baseName(String sourceName) {
    final file = sourceName.split(RegExp(r'[/\\]')).last;
    final dot = file.lastIndexOf('.');
    final base = dot > 0 ? file.substring(0, dot) : file;
    final trimmed = base.trim();
    return trimmed.isEmpty ? 'photo' : trimmed;
  }
}

/// Builds a feathered grayscale mask for [strokes].
///
/// White (255) means full enhancement, black (0) leaves the pixel untouched.
/// The brush edge fades smoothly so the edit blends into the rest of the photo.
Uint8List buildEnhanceMask({
  required int width,
  required int height,
  required List<MaskStroke> strokes,
  bool wholePhoto = false,
}) {
  final mask = Uint8List(width * height);
  if (wholePhoto) {
    mask.fillRange(0, mask.length, 255);
    return mask;
  }

  for (final stroke in strokes) {
    final radius = (stroke.radius * width).clamp(2.0, width * 0.75);
    final points = stroke.points;
    if (points.length < 2) continue;

    var previousX = points[0] * width;
    var previousY = points[1] * height;
    _stampMask(mask, width, height, previousX, previousY, radius, stroke.erase);

    for (var i = 2; i + 1 < points.length; i += 2) {
      final x = points[i] * width;
      final y = points[i + 1] * height;
      final dx = x - previousX;
      final dy = y - previousY;
      final distance = math.sqrt(dx * dx + dy * dy);
      final steps = math.max(
        1,
        (distance / math.max(1.0, radius * 0.18)).ceil(),
      );
      for (var step = 1; step <= steps; step++) {
        final t = step / steps;
        _stampMask(
          mask,
          width,
          height,
          previousX + dx * t,
          previousY + dy * t,
          radius,
          stroke.erase,
        );
      }
      previousX = x;
      previousY = y;
    }
  }
  return mask;
}

void _stampMask(
  Uint8List mask,
  int width,
  int height,
  double centerX,
  double centerY,
  double radius,
  bool erase,
) {
  final left = math.max(0, (centerX - radius).floor());
  final right = math.min(width - 1, (centerX + radius).ceil());
  final top = math.max(0, (centerY - radius).floor());
  final bottom = math.min(height - 1, (centerY + radius).ceil());
  if (left > right || top > bottom) return;

  final inner = radius * 0.55;
  final feather = radius - inner;

  for (var y = top; y <= bottom; y++) {
    final dy = y - centerY;
    final row = y * width;
    for (var x = left; x <= right; x++) {
      final dx = x - centerX;
      final distance = math.sqrt(dx * dx + dy * dy);
      if (distance >= radius) continue;

      final double coverage;
      if (distance <= inner) {
        coverage = 1;
      } else {
        final t = (distance - inner) / feather;
        // Smoothstep gives the painted edge a soft, natural falloff.
        coverage = 1 - t * t * (3 - 2 * t);
      }

      final index = row + x;
      if (erase) {
        mask[index] = (mask[index] * (1 - coverage)).round();
      } else {
        final value = (coverage * 255).round();
        if (value > mask[index]) mask[index] = value;
      }
    }
  }
}

/// Applies the enhancement to decoded JPEG bytes. Public so unit tests can
/// exercise the same code path that runs inside the background isolate.
Uint8List enhanceImageBytes(
  Uint8List sourceBytes, {
  required List<MaskStroke> strokes,
  required double strength,
  required bool wholePhoto,
  int maxDimension = EnhanceService.saveMaxSize,
  int quality = EnhanceService.saveQuality,
}) {
  var image = img.decodeImage(sourceBytes);
  if (image == null) {
    throw const FormatException('This photo could not be decoded.');
  }
  image = img.bakeOrientation(image);
  image = _fitToMax(image, maxDimension);

  final width = image.width;
  final height = image.height;
  // The curve makes 75% feel like the previous maximum while keeping the top
  // of the slider noticeably stronger than before.
  final amount = math.pow(strength.clamp(0.0, 1.0), 1.3).toDouble();
  final rgba = image.convert(numChannels: 3);
  if (amount <= 0) {
    return img.encodeJpg(rgba, quality: quality);
  }

  final source = rgba.getBytes(order: img.ChannelOrder.rgb);
  final fine = img.gaussianBlur(rgba, radius: _blurRadius(width, height));
  final fineBytes = fine.getBytes(order: img.ChannelOrder.rgb);
  final wideBytes = _wideBlurBytes(rgba);
  final mask = buildEnhanceMask(
    width: width,
    height: height,
    strokes: strokes,
    wholePhoto: wholePhoto,
  );

  final output = Uint8List(width * height * 3);
  final saturation = 1 + 0.16 * amount;
  final contrast = 1 + 0.14 * amount;

  for (var index = 0, pixel = 0; index < output.length; index += 3, pixel++) {
    final maskValue = mask[pixel];
    final red = source[index].toDouble();
    final green = source[index + 1].toDouble();
    final blue = source[index + 2].toDouble();

    if (maskValue == 0) {
      output[index] = source[index];
      output[index + 1] = source[index + 1];
      output[index + 2] = source[index + 2];
      continue;
    }

    final fineRed = fineBytes[index].toDouble();
    final fineGreen = fineBytes[index + 1].toDouble();
    final fineBlue = fineBytes[index + 2].toDouble();
    final wideRed = wideBytes[index].toDouble();
    final wideGreen = wideBytes[index + 1].toDouble();
    final wideBlue = wideBytes[index + 2].toDouble();

    final sourceLuma = 0.299 * red + 0.587 * green + 0.114 * blue;
    final fineLuma = 0.299 * fineRed + 0.587 * fineGreen + 0.114 * fineBlue;
    final wideLuma = 0.299 * wideRed + 0.587 * wideGreen + 0.114 * wideBlue;

    // A strong multi-scale unsharp pass. Working in luminance keeps colors
    // stable, and the clamp prevents bright halos around hard edges.
    var detail = (sourceLuma - fineLuma) * 4.2 + (sourceLuma - wideLuma) * 1.6;
    detail = detail.clamp(-110.0, 110.0);

    var enhancedRed = red + amount * detail;
    var enhancedGreen = green + amount * detail;
    var enhancedBlue = blue + amount * detail;

    final luminance =
        0.299 * enhancedRed + 0.587 * enhancedGreen + 0.114 * enhancedBlue;
    enhancedRed = luminance + (enhancedRed - luminance) * saturation;
    enhancedGreen = luminance + (enhancedGreen - luminance) * saturation;
    enhancedBlue = luminance + (enhancedBlue - luminance) * saturation;

    enhancedRed = (enhancedRed - 127.5) * contrast + 127.5;
    enhancedGreen = (enhancedGreen - 127.5) * contrast + 127.5;
    enhancedBlue = (enhancedBlue - 127.5) * contrast + 127.5;

    final blend = maskValue / 255.0;
    output[index] = _clamp255(red + (enhancedRed - red) * blend);
    output[index + 1] = _clamp255(green + (enhancedGreen - green) * blend);
    output[index + 2] = _clamp255(blue + (enhancedBlue - blue) * blend);
  }

  final result = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: output.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );
  return img.encodeJpg(result, quality: quality);
}

int _clamp255(double value) {
  if (value <= 0) return 0;
  if (value >= 255) return 255;
  return value.round();
}

/// Applies the manual tonal controls to decoded image bytes. Public so tests
/// can exercise the same code path used by the background isolate.
Uint8List enhanceManualImageBytes(
  Uint8List sourceBytes, {
  required ManualAdjustments adjustments,
  int maxDimension = EnhanceService.saveMaxSize,
  int quality = EnhanceService.saveQuality,
}) {
  var image = img.decodeImage(sourceBytes);
  if (image == null) {
    throw const FormatException('This photo could not be decoded.');
  }
  image = img.bakeOrientation(image);
  image = _fitToMax(image, maxDimension);

  if (adjustments.isNeutral) {
    return img.encodeJpg(image, quality: quality);
  }

  final width = image.width;
  final height = image.height;
  final rgba = image.convert(numChannels: 3);
  final source = rgba.getBytes(order: img.ChannelOrder.rgb);

  final lighting = adjustments.lighting.clamp(-100.0, 100.0);
  final sharpness = adjustments.sharpness.clamp(0.0, 100.0) / 100;
  final contrast = adjustments.contrast.clamp(-100.0, 100.0) / 100;
  final clarity = adjustments.clarity.clamp(0.0, 100.0) / 100;
  final saturation = adjustments.saturation.clamp(-100.0, 100.0) / 100;
  final hue = adjustments.hue.clamp(-180.0, 180.0);
  final highlights = adjustments.highlights.clamp(-100.0, 100.0) / 100;
  final temperature = adjustments.temperature.clamp(-100.0, 100.0) / 100;

  Uint8List? fineBytes;
  Uint8List? wideBytes;
  if (sharpness > 0) {
    fineBytes = img
        .gaussianBlur(rgba, radius: _blurRadius(width, height))
        .getBytes(order: img.ChannelOrder.rgb);
  }
  if (clarity > 0) {
    wideBytes = _wideBlurBytes(rgba);
  }

  Uint8List? lightingLut;
  if (lighting != 0) {
    // A gamma curve lifts shadows without clipping every highlight to white.
    final gamma = math.pow(2, -(lighting / 100) * 0.6).toDouble();
    lightingLut = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      lightingLut[i] = _clamp255(255.0 * math.pow(i / 255, gamma));
    }
  }

  List<double>? hueMatrix;
  if (hue != 0) {
    final radians = hue * math.pi / 180;
    final cosA = math.cos(radians);
    final sinA = math.sin(radians);
    hueMatrix = [
      0.213 + cosA * 0.787 - sinA * 0.213,
      0.715 - cosA * 0.715 - sinA * 0.715,
      0.072 - cosA * 0.072 + sinA * 0.928,
      0.213 - cosA * 0.213 + sinA * 0.143,
      0.715 + cosA * 0.285 + sinA * 0.140,
      0.072 - cosA * 0.072 - sinA * 0.283,
      0.213 - cosA * 0.213 - sinA * 0.787,
      0.715 - cosA * 0.715 + sinA * 0.715,
      0.072 + cosA * 0.928 + sinA * 0.072,
    ];
  }

  final contrastFactor = 1 + contrast * 0.6;
  final saturationFactor = 1 + saturation;
  final highlightAmount = highlights * 0.5;
  final temperatureShift = temperature * 28;
  final sharpnessAmount = sharpness * 1.5;
  final clarityAmount = clarity * 1.2;
  final output = Uint8List(width * height * 3);

  for (var index = 0; index < output.length; index += 3) {
    var red = source[index].toDouble();
    var green = source[index + 1].toDouble();
    var blue = source[index + 2].toDouble();
    final sourceLuma = 0.299 * red + 0.587 * green + 0.114 * blue;

    if (lightingLut != null) {
      red = lightingLut[_clamp255(red)].toDouble();
      green = lightingLut[_clamp255(green)].toDouble();
      blue = lightingLut[_clamp255(blue)].toDouble();
    }

    if (highlightAmount != 0) {
      final luminance = 0.299 * red + 0.587 * green + 0.114 * blue;
      final t = ((luminance - 140) / 115).clamp(0.0, 1.0);
      final weight = t * t * (3 - 2 * t);
      final factor = 1 + highlightAmount * weight;
      red *= factor;
      green *= factor;
      blue *= factor;
    }

    if (temperatureShift != 0) {
      red += temperatureShift;
      blue -= temperatureShift;
    }

    if (contrastFactor != 1) {
      red = (red - 127.5) * contrastFactor + 127.5;
      green = (green - 127.5) * contrastFactor + 127.5;
      blue = (blue - 127.5) * contrastFactor + 127.5;
    }

    if (hueMatrix != null) {
      final hueRed =
          hueMatrix[0] * red + hueMatrix[1] * green + hueMatrix[2] * blue;
      final hueGreen =
          hueMatrix[3] * red + hueMatrix[4] * green + hueMatrix[5] * blue;
      final hueBlue =
          hueMatrix[6] * red + hueMatrix[7] * green + hueMatrix[8] * blue;
      red = hueRed;
      green = hueGreen;
      blue = hueBlue;
    }

    if (saturationFactor != 1) {
      final luminance = 0.299 * red + 0.587 * green + 0.114 * blue;
      red = luminance + (red - luminance) * saturationFactor;
      green = luminance + (green - luminance) * saturationFactor;
      blue = luminance + (blue - luminance) * saturationFactor;
    }

    if (fineBytes != null || wideBytes != null) {
      var detail = 0.0;
      if (fineBytes != null) {
        final fineLuma =
            0.299 * fineBytes[index] +
            0.587 * fineBytes[index + 1] +
            0.114 * fineBytes[index + 2];
        detail += (sharpnessAmount * (sourceLuma - fineLuma)).clamp(
          -70.0,
          70.0,
        );
      }
      if (wideBytes != null) {
        final wideLuma =
            0.299 * wideBytes[index] +
            0.587 * wideBytes[index + 1] +
            0.114 * wideBytes[index + 2];
        detail += (clarityAmount * (sourceLuma - wideLuma)).clamp(-75.0, 75.0);
      }
      red += detail;
      green += detail;
      blue += detail;
    }

    output[index] = _clamp255(red);
    output[index + 1] = _clamp255(green);
    output[index + 2] = _clamp255(blue);
  }

  final result = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: output.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );
  return img.encodeJpg(result, quality: quality);
}

int _blurRadius(int width, int height) {
  return math.max(1, (math.max(width, height) / 800).round());
}

Uint8List _wideBlurBytes(img.Image image) {
  final target = math.max(
    1,
    (math.min(image.width, image.height) / 12).round(),
  );
  final small = img.copyResize(
    image,
    width: target,
    interpolation: img.Interpolation.average,
  );
  final wide = img.copyResize(
    small,
    width: image.width,
    height: image.height,
    interpolation: img.Interpolation.linear,
  );
  return wide.getBytes(order: img.ChannelOrder.rgb);
}

img.Image _fitToMax(img.Image image, int maxDimension) {
  final longest = math.max(image.width, image.height);
  if (longest <= maxDimension) return image;
  if (image.width >= image.height) {
    return img.copyResize(
      image,
      width: maxDimension,
      interpolation: img.Interpolation.average,
    );
  }
  return img.copyResize(
    image,
    height: maxDimension,
    interpolation: img.Interpolation.average,
  );
}

EnhancePreview _inspectJpeg(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null) {
    throw const FormatException('This photo could not be decoded.');
  }
  return EnhancePreview(bytes: bytes, width: image.width, height: image.height);
}

EnhancePreview _normalizeToJpeg(_NormalizeRequest request) {
  var image = img.decodeImage(request.bytes);
  if (image == null) {
    throw const FormatException('This photo could not be decoded.');
  }
  image = img.bakeOrientation(image);
  image = _fitToMax(image, request.maxDimension);
  return EnhancePreview(
    bytes: img.encodeJpg(image, quality: request.quality),
    width: image.width,
    height: image.height,
  );
}

Uint8List _enhanceRequest(_EnhanceRequest request) {
  return enhanceImageBytes(
    request.sourceBytes,
    strokes: request.strokes,
    strength: request.strength,
    wholePhoto: request.wholePhoto,
    maxDimension: request.maxDimension,
    quality: request.quality,
  );
}

Uint8List _manualRequest(_ManualRequest request) {
  return enhanceManualImageBytes(
    request.sourceBytes,
    adjustments: request.adjustments,
    maxDimension: request.maxDimension,
    quality: request.quality,
  );
}

class _NormalizeRequest {
  final Uint8List bytes;
  final int maxDimension;
  final int quality;

  const _NormalizeRequest({
    required this.bytes,
    required this.maxDimension,
    required this.quality,
  });
}

class _EnhanceRequest {
  final Uint8List sourceBytes;
  final List<MaskStroke> strokes;
  final double strength;
  final bool wholePhoto;
  final int maxDimension;
  final int quality;

  const _EnhanceRequest({
    required this.sourceBytes,
    required this.strokes,
    required this.strength,
    required this.wholePhoto,
    required this.maxDimension,
    required this.quality,
  });
}

class _ManualRequest {
  final Uint8List sourceBytes;
  final ManualAdjustments adjustments;
  final int maxDimension;
  final int quality;

  const _ManualRequest({
    required this.sourceBytes,
    required this.adjustments,
    required this.maxDimension,
    required this.quality,
  });
}
