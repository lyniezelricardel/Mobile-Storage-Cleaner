import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img;

/// Why an AI enhancement or balance request failed.
enum AiEnhanceError {
  auth,
  noCredits,
  moderation,
  tooLarge,
  unsupported,
  rateLimited,
  server,
  network,
  invalidResponse,
}

/// A user-readable AI enhancement failure.
class AiEnhanceException implements Exception {
  final AiEnhanceError kind;
  final String message;
  final int? statusCode;

  /// Stability AI only charges credits when an upscale succeeds.
  final bool creditsCharged;

  const AiEnhanceException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.creditsCharged = false,
  });

  @override
  String toString() => message;
}

/// The full 4x result plus a display-sized preview.
///
/// [fullBytes] is kept for saving to the gallery at full resolution. The
/// preview avoids decoding a large 4x image into the UI isolate.
class AiUpscaleResult {
  final Uint8List fullBytes;
  final Uint8List previewBytes;
  final int width;
  final int height;

  const AiUpscaleResult({
    required this.fullBytes,
    required this.previewBytes,
    required this.width,
    required this.height,
  });
}

/// Talks to Stability AI's Fast Upscaler.
///
/// The service only ever sends the photo when the user explicitly confirms an
/// AI enhancement. Smart Enhance never touches this code path.
class AiEnhanceService {
  static const String upscaleUrl =
      'https://api.stability.ai/v2beta/stable-image/upscale/fast';
  static const String balanceUrl = 'https://api.stability.ai/v1/user/balance';

  /// Stability AI charges 2 credits for each successful fast upscale.
  static const int creditsPerEnhance = 2;

  /// Input limits documented by the Fast Upscaler endpoint.
  static const int maxInputSide = 1536;
  static const int maxInputPixels = 1048576;

  /// The result preview is large enough to compare, but cheap to decode.
  static const int previewMaxSize = 2000;

  static const Duration requestTimeout = Duration(seconds: 90);

  final http.Client _client;

  AiEnhanceService({http.Client? client}) : _client = client ?? http.Client();

  void dispose() {
    _client.close();
  }

  /// Returns the account's current credit balance.
  Future<double> fetchBalance({required String apiKey}) async {
    final http.Response response;
    try {
      response = await _client
          .get(
            Uri.parse(balanceUrl),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Accept': 'application/json',
            },
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw const AiEnhanceException(
        kind: AiEnhanceError.network,
        message:
            'Stability AI did not respond in time. Check your connection and '
            'try again.',
      );
    } on SocketException {
      throw const AiEnhanceException(
        kind: AiEnhanceError.network,
        message:
            'Could not reach Stability AI. Check your internet connection.',
      );
    } on http.ClientException {
      throw const AiEnhanceException(
        kind: AiEnhanceError.network,
        message:
            'Could not reach Stability AI. Check your internet connection.',
      );
    }

    if (response.statusCode == 401) {
      throw errorForStatus(401);
    }
    if (response.statusCode != 200) {
      throw errorForStatus(response.statusCode, body: response.body);
    }
    return parseBalanceBody(response.body);
  }

  /// Sends [imageBytes] to Stability AI and returns the 4x upscaled copy.
  Future<AiUpscaleResult> upscale({
    required String apiKey,
    required Uint8List imageBytes,
  }) async {
    final prepared = await compute(
      prepareAiUploadBytes,
      imageBytes,
      debugLabel: 'ai-input',
    );

    final request = http.MultipartRequest('POST', Uri.parse(upscaleUrl))
      ..headers['Authorization'] = 'Bearer $apiKey'
      // Stability only accepts `image/*` or `application/json` here. Sending
      // `image/jpeg` is rejected with a 400 before the image is processed.
      ..headers['Accept'] = 'image/*'
      ..fields['output_format'] = 'jpeg'
      ..files.add(
        http.MultipartFile.fromBytes(
          'image',
          prepared,
          filename: 'photo.jpg',
          contentType: MediaType('image', 'jpeg'),
        ),
      );

    final http.Response response;
    try {
      final streamed = await _client.send(request).timeout(requestTimeout);
      response = await http.Response.fromStream(
        streamed,
      ).timeout(requestTimeout);
    } on TimeoutException {
      throw const AiEnhanceException(
        kind: AiEnhanceError.network,
        message:
            'Stability AI did not respond in time. No credits were charged. '
            'Try again when your connection is stable.',
      );
    } on SocketException {
      throw const AiEnhanceException(
        kind: AiEnhanceError.network,
        message:
            'Could not reach Stability AI. No credits were charged. Check your '
            'internet connection.',
      );
    } on http.ClientException {
      throw const AiEnhanceException(
        kind: AiEnhanceError.network,
        message:
            'Could not reach Stability AI. No credits were charged. Check your '
            'internet connection.',
      );
    }

    if (response.statusCode != 200) {
      throw errorForStatus(response.statusCode, body: response.body);
    }
    if (response.bodyBytes.isEmpty) {
      throw const AiEnhanceException(
        kind: AiEnhanceError.invalidResponse,
        message:
            'Stability AI returned an empty result. No credits were charged.',
      );
    }

    final preview = await compute(
      buildAiResultPreview,
      response.bodyBytes,
      debugLabel: 'ai-preview',
    );
    return AiUpscaleResult(
      fullBytes: response.bodyBytes,
      previewBytes: preview.bytes,
      width: preview.width,
      height: preview.height,
    );
  }

  /// Parses the `{ "credits": 25 }` balance payload.
  static double parseBalanceBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final credits = decoded['credits'];
        if (credits is num) return credits.toDouble();
      }
    } catch (_) {
      // Falls through to the shared error below.
    }
    throw const AiEnhanceException(
      kind: AiEnhanceError.invalidResponse,
      message: 'Stability AI returned an unexpected balance. Try again.',
    );
  }

  /// Maps an HTTP status to a clear message. Only a successful upscale costs
  /// credits, so failures always report [AiEnhanceException.creditsCharged] as
  /// false. When [body] is supplied, Stability's own error detail is included
  /// for 400/422 responses so the UI can explain what was rejected.
  static AiEnhanceException errorForStatus(int statusCode, {String? body}) {
    switch (statusCode) {
      case 400:
        final detail = _serverErrorDetail(body);
        return AiEnhanceException(
          kind: AiEnhanceError.invalidResponse,
          message: detail == null
              ? 'Stability AI rejected the request (400). No credits were '
                    'charged.'
              : 'Stability AI rejected the request: $detail No credits were '
                    'charged.',
          statusCode: 400,
        );
      case 401:
        return const AiEnhanceException(
          kind: AiEnhanceError.auth,
          message:
              'The Stability AI key was rejected. Open AI settings and check '
              'the key.',
          statusCode: 401,
        );
      case 402:
        return const AiEnhanceException(
          kind: AiEnhanceError.noCredits,
          message:
              'This Stability AI account is out of credits. Add credits or '
              'use Smart Enhance instead.',
          statusCode: 402,
        );
      case 403:
        return const AiEnhanceException(
          kind: AiEnhanceError.moderation,
          message:
              'Stability AI blocked this image (content policy). No credits '
              'were charged. Try another photo or use Smart Enhance.',
          statusCode: 403,
        );
      case 413:
        return const AiEnhanceException(
          kind: AiEnhanceError.tooLarge,
          message:
              'The photo is still too large for Stability AI after resizing. '
              'No credits were charged.',
          statusCode: 413,
        );
      case 422:
        final detail = _serverErrorDetail(body);
        return AiEnhanceException(
          kind: AiEnhanceError.unsupported,
          message: detail == null
              ? 'Stability AI could not process this image. No credits were '
                    'charged. Try a different photo.'
              : 'Stability AI could not process this image: $detail No credits '
                    'were charged. Try a different photo.',
          statusCode: 422,
        );
      case 429:
        return const AiEnhanceException(
          kind: AiEnhanceError.rateLimited,
          message:
              'Too many requests reached Stability AI. Wait a moment, then '
              'try again. No credits were charged.',
          statusCode: 429,
        );
      default:
        if (statusCode >= 500) {
          return AiEnhanceException(
            kind: AiEnhanceError.server,
            message:
                'Stability AI had a server error ($statusCode). Try again '
                'later. No credits were charged.',
            statusCode: statusCode,
          );
        }
        return AiEnhanceException(
          kind: AiEnhanceError.invalidResponse,
          message:
              'Stability AI returned an unexpected response ($statusCode). No '
              'credits were charged.',
          statusCode: statusCode,
        );
    }
  }

  static String? _serverErrorDetail(String? body) {
    if (body == null || body.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final errors = decoded['errors'];
        if (errors is List) {
          final text = errors.whereType<String>().join(' ').trim();
          if (text.isNotEmpty) {
            return text.length <= 180 ? text : '${text.substring(0, 180)}…';
          }
        }
      }
    } catch (_) {
      // The status alone is still useful when the body is not valid JSON.
    }
    return null;
  }
}

/// Resizes a photo so it satisfies the Fast Upscaler input limits.
///
/// The API accepts at most 1536 px per side and 1,048,576 pixels total. The
/// photo is re-encoded as JPEG at high quality before upload.
Uint8List prepareAiUploadBytes(Uint8List sourceBytes) {
  var image = img.decodeImage(sourceBytes);
  if (image == null) {
    throw const FormatException('This photo could not be decoded.');
  }
  image = img.bakeOrientation(image);

  final longestSide = math.max(image.width, image.height);
  final totalPixels = image.width * image.height;
  final scale = math.min(
    1.0,
    math.min(
      AiEnhanceService.maxInputSide / longestSide,
      math.sqrt(AiEnhanceService.maxInputPixels / totalPixels),
    ),
  );

  if (scale < 1) {
    final width = math.max(1, (image.width * scale).floor());
    final height = math.max(1, (image.height * scale).floor());
    image = img.copyResize(
      image,
      width: width,
      height: height,
      interpolation: img.Interpolation.average,
    );
  }
  return img.encodeJpg(image, quality: 92);
}

/// Display preview handed to the UI after an AI upscale.
class AiResultPreview {
  final Uint8List bytes;
  final int width;
  final int height;

  const AiResultPreview({
    required this.bytes,
    required this.width,
    required this.height,
  });
}

/// Builds a bounded preview while retaining the full output dimensions.
AiResultPreview buildAiResultPreview(Uint8List fullBytes) {
  var image = img.decodeImage(fullBytes);
  if (image == null) {
    throw const FormatException('The AI result could not be decoded.');
  }
  image = img.bakeOrientation(image);
  final width = image.width;
  final height = image.height;
  final longest = math.max(width, height);
  if (longest > AiEnhanceService.previewMaxSize) {
    final scale = AiEnhanceService.previewMaxSize / longest;
    image = img.copyResize(
      image,
      width: math.max(1, (width * scale).round()),
      interpolation: img.Interpolation.average,
    );
  }
  return AiResultPreview(
    bytes: img.encodeJpg(image, quality: 90),
    width: width,
    height: height,
  );
}
