import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// State of the Stability AI key used by the AI enhancement mode.
class AiKeyInfo {
  /// The effective key, or null when no key is available.
  final String? key;

  /// True when [key] came from the build-time demo key instead of the user.
  final bool fromBuild;

  /// True when the user saved an override in secure storage.
  final bool hasStoredOverride;

  const AiKeyInfo({
    required this.key,
    required this.fromBuild,
    required this.hasStoredOverride,
  });

  bool get hasKey => key != null && key!.trim().isNotEmpty;
}

/// A cached Stability AI balance, kept so the editor can show a balance even
/// when the device is briefly offline.
class CachedCreditBalance {
  final double credits;
  final DateTime updatedAt;

  const CachedCreditBalance({required this.credits, required this.updatedAt});
}

/// Persists the AI enhancement key, upload consent, and a cached balance.
///
/// The key itself lives in Android's Keystore-backed secure storage. A
/// build-time demo key is used only when the user has not saved an override.
class AiEnhanceSettings {
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );

  static const String _apiKeyStorageKey = 'stability_api_key_v1';
  static const String _consentKey = 'ai_upload_consent_v1';
  static const String _creditsKey = 'stability_credits_v1';
  static const String _creditsUpdatedKey = 'stability_credits_updated_v1';

  /// Prefilled at build time with
  /// `--dart-define-from-file=secrets.json` for the class demo.
  static const String compiledApiKey = String.fromEnvironment(
    'STABILITY_API_KEY',
  );

  static bool get hasBuildKey => compiledApiKey.trim().isNotEmpty;

  static Future<AiKeyInfo> loadKeyInfo() async {
    String? stored;
    try {
      stored = (await _secureStorage.read(key: _apiKeyStorageKey))?.trim();
    } catch (_) {
      // Secure storage can fail on a locked device; the build key still works.
    }
    if (stored != null && stored.isNotEmpty) {
      return AiKeyInfo(key: stored, fromBuild: false, hasStoredOverride: true);
    }

    final buildKey = compiledApiKey.trim();
    if (buildKey.isNotEmpty) {
      return AiKeyInfo(
        key: buildKey,
        fromBuild: true,
        hasStoredOverride: false,
      );
    }
    return const AiKeyInfo(
      key: null,
      fromBuild: false,
      hasStoredOverride: false,
    );
  }

  static Future<void> saveApiKey(String key) async {
    await _secureStorage.write(key: _apiKeyStorageKey, value: key.trim());
  }

  static Future<void> clearStoredApiKey() async {
    try {
      await _secureStorage.delete(key: _apiKeyStorageKey);
    } catch (_) {
      // Nothing to remove.
    }
  }

  static Future<bool> isUploadConsentGranted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_consentKey) ?? false;
  }

  static Future<void> grantUploadConsent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_consentKey, true);
  }

  static Future<CachedCreditBalance?> loadCachedCredits() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_creditsKey);
    if (raw == null) return null;
    final credits = double.tryParse(raw);
    if (credits == null) return null;
    final millis = prefs.getInt(_creditsUpdatedKey);
    return CachedCreditBalance(
      credits: credits,
      updatedAt: millis == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.fromMillisecondsSinceEpoch(millis),
    );
  }

  static Future<void> cacheCredits(double credits) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_creditsKey, credits.toString());
    await prefs.setInt(
      _creditsUpdatedKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Shows only enough of a key to recognize it, never the full secret.
  static String maskKey(String key) {
    final trimmed = key.trim();
    if (trimmed.length <= 8) return '••••••••';
    final prefix = trimmed.substring(0, 3);
    final suffix = trimmed.substring(trimmed.length - 4);
    return '$prefix••••••••$suffix';
  }

  static String formatCredits(double credits) {
    if (credits == credits.roundToDouble()) {
      return credits.toStringAsFixed(0);
    }
    return credits.toStringAsFixed(1);
  }
}
