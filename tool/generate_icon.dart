import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

// Unique launcher icon: a camera lens with a cleaning orbit and sparkles.
// Rendered at 4x and downsampled for clean edges.

final _white = img.ColorRgba8(255, 255, 255, 255);
final _pink = img.ColorRgba8(255, 79, 154, 255);

void main() {
  final res = 'android/app/src/main/res';

  const legacySizes = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
  };
  const adaptiveSizes = {
    'mipmap-mdpi': 108,
    'mipmap-hdpi': 162,
    'mipmap-xhdpi': 216,
    'mipmap-xxhdpi': 324,
    'mipmap-xxxhdpi': 432,
  };

  for (final entry in legacySizes.entries) {
    _write(
      '$res/${entry.key}/ic_launcher.png',
      _legacyIcon(entry.value, rounded: true),
    );
    _write(
      '$res/${entry.key}/ic_launcher_round.png',
      _legacyIcon(entry.value, rounded: true, circular: true),
    );
  }

  for (final entry in adaptiveSizes.entries) {
    _write(
      '$res/${entry.key}/ic_launcher_background.png',
      _background(entry.value),
    );
    _write(
      '$res/${entry.key}/ic_launcher_foreground.png',
      _foreground(entry.value),
    );
    _write(
      '$res/${entry.key}/ic_launcher_monochrome.png',
      _foreground(entry.value, monochrome: true),
    );
  }

  stdout.writeln('Launcher icons generated.');
}

img.Image _legacyIcon(
  int size, {
  required bool rounded,
  bool circular = false,
}) {
  final canvas = _newCanvas(size);
  _paintBackground(canvas);
  _drawMark(canvas);
  var output = img.copyResize(
    canvas,
    width: size,
    height: size,
    interpolation: img.Interpolation.average,
  );

  if (circular) {
    _clipCircle(output);
  } else if (rounded) {
    _roundCorners(output, size * 0.22);
  }
  return output;
}

img.Image _foreground(int size, {bool monochrome = false}) {
  final canvas = _newCanvas(size);
  _drawMark(canvas, monochrome: monochrome);
  return img.copyResize(
    canvas,
    width: size,
    height: size,
    interpolation: img.Interpolation.average,
  );
}

img.Image _background(int size) {
  final canvas = _newCanvas(size);
  _paintBackground(canvas);
  return img.copyResize(
    canvas,
    width: size,
    height: size,
    interpolation: img.Interpolation.average,
  );
}

img.Image _newCanvas(int size) {
  return img.Image(width: size * 4, height: size * 4, numChannels: 4);
}

void _write(String path, img.Image image) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(img.encodePng(image));
}

void _paintBackground(img.Image image) {
  final w = image.width;
  final h = image.height;

  const stops = [(0.0, 67, 56, 202), (0.52, 109, 40, 217), (1.0, 219, 39, 119)];

  for (var y = 0; y < h; y++) {
    final t = y / (h - 1);
    var lower = stops.first;
    var upper = stops.last;
    for (var i = 0; i < stops.length - 1; i++) {
      if (t >= stops[i].$1 && t <= stops[i + 1].$1) {
        lower = stops[i];
        upper = stops[i + 1];
        break;
      }
    }
    final span = upper.$1 - lower.$1;
    final local = span == 0 ? 0.0 : (t - lower.$1) / span;
    final r = _lerp(lower.$2, upper.$2, local);
    final g = _lerp(lower.$3, upper.$3, local);
    final b = _lerp(lower.$4, upper.$4, local);
    img.fillRect(
      image,
      x1: 0,
      y1: y,
      x2: w - 1,
      y2: y,
      color: img.ColorRgba8(r, g, b, 255),
    );
  }

  // Soft glows give the flat gradient some depth.
  img.fillCircle(
    image,
    x: (w * 0.16).round(),
    y: (h * 0.12).round(),
    radius: (w * 0.52).round(),
    color: img.ColorRgba8(255, 255, 255, 18),
    antialias: true,
  );
  img.fillCircle(
    image,
    x: (w * 0.9).round(),
    y: (h * 0.92).round(),
    radius: (w * 0.38).round(),
    color: img.ColorRgba8(255, 255, 255, 12),
    antialias: true,
  );
  img.fillCircle(
    image,
    x: (w * 0.75).round(),
    y: (h * 0.22).round(),
    radius: (w * 0.06).round(),
    color: img.ColorRgba8(255, 255, 255, 30),
    antialias: true,
  );
}

void _drawMark(img.Image image, {bool monochrome = false}) {
  final s = image.width.toDouble();
  final cx = s * 0.5;
  final cy = s * 0.5;
  final white = monochrome ? img.ColorRgba8(255, 255, 255, 255) : _white;
  final accent = monochrome ? white : _pink;

  // Cleaning orbit behind the lens.
  _drawArc(
    image,
    cx: cx,
    cy: cy,
    radius: s * 0.292,
    thickness: s * 0.034,
    startAngle: 132 * math.pi / 180,
    sweep: 280 * math.pi / 180,
    color: monochrome ? white : img.ColorRgba8(255, 255, 255, 232),
  );
  _drawArrowHead(
    image,
    cx: cx,
    cy: cy,
    radius: s * 0.292,
    angle: 412 * math.pi / 180,
    size: s * 0.052,
    color: monochrome ? white : _white,
  );

  // Lens ring.
  _drawRing(
    image,
    cx: cx,
    cy: cy,
    outer: s * 0.228,
    inner: s * 0.163,
    color: white,
  );

  // Soft inner rim.
  _drawRing(
    image,
    cx: cx,
    cy: cy,
    outer: s * 0.154,
    inner: s * 0.146,
    color: monochrome ? white : img.ColorRgba8(255, 255, 255, 200),
  );

  // Center sparkle: the "cleaned" result.
  _drawSparkle(image, cx: cx, cy: cy, length: s * 0.095, color: accent);
  _drawSparkle(image, cx: cx, cy: cy, length: s * 0.045, color: white);

  // Accent sparkles outside the lens.
  _drawSparkle(
    image,
    cx: s * 0.752,
    cy: s * 0.278,
    length: s * 0.047,
    color: monochrome ? white : _white,
  );
  _drawSparkle(
    image,
    cx: s * 0.294,
    cy: s * 0.742,
    length: s * 0.027,
    color: monochrome ? white : img.ColorRgba8(255, 255, 255, 210),
  );
}

void _drawRing(
  img.Image image, {
  required double cx,
  required double cy,
  required double outer,
  required double inner,
  required img.Color color,
}) {
  final x0 = math.max(0, (cx - outer - 2).floor());
  final x1 = math.min(image.width - 1, (cx + outer + 2).ceil());
  final y0 = math.max(0, (cy - outer - 2).floor());
  final y1 = math.min(image.height - 1, (cy + outer + 2).ceil());

  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final dx = x + 0.5 - cx;
      final dy = y + 0.5 - cy;
      final distance = math.sqrt(dx * dx + dy * dy);
      final outerCoverage = ((outer + 0.75 - distance) / 1.5).clamp(0.0, 1.0);
      final innerCoverage = ((distance - inner + 0.75) / 1.5).clamp(0.0, 1.0);
      final coverage = math.min(outerCoverage, innerCoverage);
      if (coverage <= 0) continue;
      img.drawPixel(image, x, y, color, alpha: coverage);
    }
  }
}

void _drawArc(
  img.Image image, {
  required double cx,
  required double cy,
  required double radius,
  required double thickness,
  required double startAngle,
  required double sweep,
  required img.Color color,
}) {
  final box = radius + thickness;
  final x0 = math.max(0, (cx - box - 2).floor());
  final x1 = math.min(image.width - 1, (cx + box + 2).ceil());
  final y0 = math.max(0, (cy - box - 2).floor());
  final y1 = math.min(image.height - 1, (cy + box + 2).ceil());
  final half = thickness / 2;

  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final dx = x + 0.5 - cx;
      final dy = y + 0.5 - cy;
      final distance = math.sqrt(dx * dx + dy * dy);
      final edge = half - (distance - radius).abs();
      if (edge <= 0) continue;

      var angle = math.atan2(dy, dx);
      while (angle < startAngle) {
        angle += math.pi * 2;
      }
      if (angle > startAngle + sweep) continue;

      final coverage = (edge / 1.5).clamp(0.0, 1.0);
      img.drawPixel(image, x, y, color, alpha: coverage);
    }
  }
}

void _drawArrowHead(
  img.Image image, {
  required double cx,
  required double cy,
  required double radius,
  required double angle,
  required double size,
  required img.Color color,
}) {
  final px = cx + math.cos(angle) * radius;
  final py = cy + math.sin(angle) * radius;
  final tangentX = -math.sin(angle);
  final tangentY = math.cos(angle);
  final normalX = math.cos(angle);
  final normalY = math.sin(angle);

  final tip = img.Point(px + tangentX * size, py + tangentY * size);
  final baseA = img.Point(
    px + normalX * size * 0.78 - tangentX * size * 0.2,
    py + normalY * size * 0.78 - tangentY * size * 0.2,
  );
  final baseB = img.Point(
    px - normalX * size * 0.78 - tangentX * size * 0.2,
    py - normalY * size * 0.78 - tangentY * size * 0.2,
  );

  img.fillPolygon(image, vertices: [tip, baseA, baseB], color: color);
}

void _drawSparkle(
  img.Image image, {
  required double cx,
  required double cy,
  required double length,
  required img.Color color,
}) {
  final inner = length * 0.24;
  final points = <img.Point>[];
  for (var i = 0; i < 8; i++) {
    final angle = -math.pi / 2 + i * math.pi / 4;
    final distance = i.isEven ? length : inner;
    points.add(
      img.Point(
        cx + math.cos(angle) * distance,
        cy + math.sin(angle) * distance,
      ),
    );
  }
  img.fillPolygon(image, vertices: points, color: color);
}

void _roundCorners(img.Image image, double radius) {
  final size = image.width;
  final limit = radius;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final nearestX = x < limit
          ? limit
          : (x > size - limit ? size - limit : x.toDouble());
      final nearestY = y < limit
          ? limit
          : (y > size - limit ? size - limit : y.toDouble());
      final dx = x - nearestX;
      final dy = y - nearestY;
      if (dx * dx + dy * dy > radius * radius) {
        image.setPixelRgba(x, y, 0, 0, 0, 0);
      }
    }
  }
}

void _clipCircle(img.Image image) {
  final size = image.width;
  final center = size / 2;
  final radius = size / 2;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final dx = x + 0.5 - center;
      final dy = y + 0.5 - center;
      if (dx * dx + dy * dy > radius * radius) {
        image.setPixelRgba(x, y, 0, 0, 0, 0);
      }
    }
  }
}

int _lerp(int a, int b, double t) => (a + (b - a) * t).round();
