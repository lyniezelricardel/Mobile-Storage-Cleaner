import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:mobile_storage_cleaner/services/ai_enhance_service.dart';

void main() {
  group('prepareAiUploadBytes', () {
    test('fits a landscape photo inside the 1536 px / 1 MP limits', () {
      final source = img.Image(width: 3000, height: 2000);
      img.fill(source, color: img.ColorRgb8(90, 120, 160));
      final encoded = img.encodeJpg(source, quality: 95);

      final prepared = prepareAiUploadBytes(encoded);
      final decoded = img.decodeJpg(prepared);

      expect(decoded, isNotNull);
      expect(decoded!.width, lessThanOrEqualTo(1536));
      expect(decoded.height, lessThanOrEqualTo(1536));
      expect(
        decoded.width * decoded.height,
        lessThanOrEqualTo(AiEnhanceService.maxInputPixels),
      );
      expect(decoded.width / decoded.height, closeTo(1.5, 0.01));
    });

    test('fits a tall photo without stretching it', () {
      final source = img.Image(width: 1200, height: 2400);
      img.fill(source, color: img.ColorRgb8(50, 80, 110));
      final encoded = img.encodeJpg(source, quality: 95);

      final prepared = prepareAiUploadBytes(encoded);
      final decoded = img.decodeJpg(prepared)!;

      expect(decoded.height, lessThanOrEqualTo(1536));
      expect(
        decoded.width * decoded.height,
        lessThanOrEqualTo(AiEnhanceService.maxInputPixels),
      );
      expect(decoded.width / decoded.height, closeTo(0.5, 0.01));
    });

    test('keeps an already-small image at its original size', () {
      final source = img.Image(width: 800, height: 600);
      img.fill(source, color: img.ColorRgb8(20, 40, 60));
      final encoded = img.encodeJpg(source, quality: 95);

      final decoded = img.decodeJpg(prepareAiUploadBytes(encoded))!;

      expect(decoded.width, 800);
      expect(decoded.height, 600);
    });

    test('rejects bytes that are not an image', () {
      expect(
        () => prepareAiUploadBytes(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('buildAiResultPreview', () {
    test('bounds the preview but reports the full dimensions', () {
      final source = img.Image(width: 4000, height: 3000);
      img.fill(source, color: img.ColorRgb8(120, 90, 60));
      final encoded = img.encodeJpg(source, quality: 90);

      final preview = buildAiResultPreview(encoded);
      final decoded = img.decodeJpg(preview.bytes)!;

      expect(preview.width, 4000);
      expect(preview.height, 3000);
      expect(decoded.width, AiEnhanceService.previewMaxSize);
      expect(decoded.height, 1500);
    });
  });

  group('parseBalanceBody', () {
    test('reads the credits field', () {
      expect(AiEnhanceService.parseBalanceBody('{"credits": 25}'), 25);
      expect(AiEnhanceService.parseBalanceBody('{"credits": 6.5}'), 6.5);
    });

    test('rejects an unexpected payload', () {
      expect(
        () => AiEnhanceService.parseBalanceBody('{"error": "nope"}'),
        throwsA(
          isA<AiEnhanceException>().having(
            (error) => error.kind,
            'kind',
            AiEnhanceError.invalidResponse,
          ),
        ),
      );
    });
  });

  group('errorForStatus', () {
    test('maps account and image failures without charging credits', () {
      final expected = {
        401: AiEnhanceError.auth,
        402: AiEnhanceError.noCredits,
        403: AiEnhanceError.moderation,
        413: AiEnhanceError.tooLarge,
        422: AiEnhanceError.unsupported,
        429: AiEnhanceError.rateLimited,
        500: AiEnhanceError.server,
        503: AiEnhanceError.server,
      };

      expected.forEach((status, kind) {
        final error = AiEnhanceService.errorForStatus(status);
        expect(error.kind, kind, reason: 'status $status');
        expect(error.statusCode, status);
        expect(error.creditsCharged, isFalse, reason: 'status $status');
        expect(error.message, isNotEmpty);
      });
    });
  });

  group('upscale request', () {
    Uint8List sourceJpeg() {
      final source = img.Image(width: 400, height: 300);
      img.fill(source, color: img.ColorRgb8(80, 110, 140));
      return img.encodeJpg(source, quality: 95);
    }

    test('uses the documented Accept header and returns a preview', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        final result = img.Image(width: 640, height: 480);
        img.fill(result, color: img.ColorRgb8(90, 120, 150));
        return http.Response.bytes(
          img.encodeJpg(result, quality: 90),
          200,
          headers: {'content-type': 'image/jpeg'},
        );
      });
      final service = AiEnhanceService(client: client);
      addTearDown(service.dispose);

      final result = await service.upscale(
        apiKey: 'sk-test-key',
        imageBytes: sourceJpeg(),
      );

      expect(captured.url, Uri.parse(AiEnhanceService.upscaleUrl));
      expect(captured.headers['Authorization'], 'Bearer sk-test-key');
      // Stability rejects `image/jpeg` here with a 400.
      expect(captured.headers['Accept'], 'image/*');
      expect(
        captured.headers['Content-Type'],
        startsWith('multipart/form-data'),
      );
      // The multipart body contains the JPEG bytes, so decode it as latin1.
      final body = latin1.decode(captured.bodyBytes);
      expect(body, contains('name="output_format"'));
      expect(body, contains('jpeg'));
      expect(body, contains('name="image"'));
      expect(result.fullBytes, isNotEmpty);
      expect(result.previewBytes, isNotEmpty);
      expect(result.width, 640);
      expect(result.height, 480);
    });

    test('surfaces the server detail when Stability returns 400', () async {
      final client = MockClient((request) async {
        return http.Response(
          '{"errors":["Invalid output_format: expected jpeg, png or webp"],'
          '"id":"abc"}',
          400,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = AiEnhanceService(client: client);
      addTearDown(service.dispose);

      await expectLater(
        service.upscale(apiKey: 'sk-test-key', imageBytes: sourceJpeg()),
        throwsA(
          isA<AiEnhanceException>()
              .having(
                (error) => error.kind,
                'kind',
                AiEnhanceError.invalidResponse,
              )
              .having((error) => error.statusCode, 'statusCode', 400)
              .having(
                (error) => error.message,
                'message',
                contains('Invalid output_format'),
              )
              .having(
                (error) => error.creditsCharged,
                'creditsCharged',
                isFalse,
              ),
        ),
      );
    });

    test('parses the errors array without leaking unrelated JSON', () {
      final error = AiEnhanceService.errorForStatus(
        422,
        body: '{"errors":["Image dimensions are too small."],"id":"x"}',
      );

      expect(error.kind, AiEnhanceError.unsupported);
      expect(error.statusCode, 422);
      expect(error.message, contains('Image dimensions are too small.'));
      expect(error.message, isNot(contains('"id"')));
    });
  });

  group('fetchBalance', () {
    test('sends the key and returns the balance', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('{"credits": 25}', 200);
      });
      final service = AiEnhanceService(client: client);
      addTearDown(service.dispose);

      final credits = await service.fetchBalance(apiKey: 'sk-test-key');

      expect(credits, 25);
      expect(captured.url, Uri.parse(AiEnhanceService.balanceUrl));
      expect(captured.headers['Authorization'], 'Bearer sk-test-key');
    });

    test('maps a rejected key to an auth error', () async {
      final client = MockClient((request) async {
        return http.Response('{"errors": ["invalid key"]}', 401);
      });
      final service = AiEnhanceService(client: client);
      addTearDown(service.dispose);

      expect(
        () => service.fetchBalance(apiKey: 'sk-bad'),
        throwsA(
          isA<AiEnhanceException>().having(
            (error) => error.kind,
            'kind',
            AiEnhanceError.auth,
          ),
        ),
      );
    });
  });
}
