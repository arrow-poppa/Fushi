/// Reads and writes the AI Explanation behaviour settings.
///
/// Built on [PrefStore] rather than on `PreferencesRepository` so the AI layer
/// stays free of Flutter and can be unit-tested with a map-backed fake. See
/// `docs/agent/ai-explanation.md` §6.
///
/// Credentials are **not** here — they live behind [AiCredentialStore], which
/// exists precisely so the rules that apply only to them are reviewable in one
/// place. The two credential-bearing values that are also request configuration
/// (the custom endpoint and the custom request body JSON) are read here because
/// the request builder needs them, but they are registered as device-local in
/// `PrefRedactionPolicy` just like the API keys.
library;

import 'package:fushi/src/ai/ai_credential_store.dart';
import 'package:fushi/src/ai/ai_pref_keys.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

/// Loads an [AiProviderConfig] from, and writes it back to, the preference
/// table.
class AiSettingsStore {
  const AiSettingsStore(this._prefs);

  final PrefStore _prefs;

  /// Whether the user has switched the feature on at all.
  ///
  /// Derived rather than stored: the feature is on exactly when a provider has
  /// a usable configuration. There is no separate master switch because a
  /// half-configured one is the state that produces confusing "why is nothing
  /// happening" reports.
  bool isEnabled(AiCredentialStore credentials) {
    final AiProviderConfig config = read();
    return config.isConfigured(
        hasApiKey: credentials.hasApiKey(config.provider));
  }

  /// Reads the whole configuration.
  ///
  /// Cheap enough to call per lookup: it is a handful of map reads against the
  /// in-memory preference cache, with no allocation beyond the config object.
  AiProviderConfig read() {
    return AiProviderConfig(
      provider: AiProvider.fromWire(_string(AiPrefKeys.provider)),
      openaiModel:
          _string(AiPrefKeys.openaiModel, AiDefaults.openaiModel),
      geminiModel:
          _string(AiPrefKeys.geminiModel, AiDefaults.geminiModel),
      geminiThinkingLevel: AiGeminiThinkingLevel.fromWire(
          _string(AiPrefKeys.geminiThinkingLevel)),
      deepseekModel: _string(AiPrefKeys.deepseekModel),
      deepseekThinkingMode:
          AiThinkingMode.fromWire(_string(AiPrefKeys.deepseekThinkingMode)),
      deepseekThinkingIntensity: AiThinkingIntensity.fromWire(
          _string(AiPrefKeys.deepseekThinkingIntensity)),
      customEndpoint: _string(AiPrefKeys.customEndpoint),
      customModel: _string(AiPrefKeys.customModel),
      customRoutingMode: AiProviderRoutingMode.fromWire(
          _string(AiPrefKeys.customRoutingMode)),
      customRoutingSlugs: _string(AiPrefKeys.customRoutingSlugs),
      customAllowFallbacks: _bool(AiPrefKeys.customRoutingAllowFallbacks,
          AiDefaults.providerAllowFallbacks),
      customThinkingMode:
          AiThinkingMode.fromWire(_string(AiPrefKeys.customThinkingMode)),
      customThinkingIntensity: AiThinkingIntensity.fromWire(
          _string(AiPrefKeys.customThinkingIntensity)),
      customThinkingValue: _string(AiPrefKeys.customThinkingValue),
      customRequestBodyJson: _string(AiPrefKeys.customRequestBodyJson),
      userPrompt: _string(AiPrefKeys.prompt, AiDefaults.userPrompt),
      systemPrompt: _string(AiPrefKeys.systemPrompt),
      temperature: _temperature(),
      autoGenerateOnLookup:
          _bool(AiPrefKeys.autoGenerate, AiDefaults.autoGenerateOnLookup),
      streamResponse: _bool(AiPrefKeys.stream, AiDefaults.streamResponse),
      cancelPendingRequests: _bool(
          AiPrefKeys.cancelPending, AiDefaults.cancelPendingRequests),
      unknownWordFallback:
          _bool(AiPrefKeys.unknownFallback, AiDefaults.unknownWordFallback),
    );
  }

  Future<void> setProvider(AiProvider value) =>
      _prefs.setPref(AiPrefKeys.provider, value.wire);

  Future<void> setAutoGenerate(bool value) =>
      _prefs.setPref(AiPrefKeys.autoGenerate, value);

  Future<void> setStreamResponse(bool value) =>
      _prefs.setPref(AiPrefKeys.stream, value);

  Future<void> setCancelPending(bool value) =>
      _prefs.setPref(AiPrefKeys.cancelPending, value);

  Future<void> setUnknownWordFallback(bool value) =>
      _prefs.setPref(AiPrefKeys.unknownFallback, value);

  Future<void> setUserPrompt(String value) =>
      _prefs.setPref(AiPrefKeys.prompt, value);

  Future<void> setSystemPrompt(String value) =>
      _prefs.setPref(AiPrefKeys.systemPrompt, value);

  /// Stores the temperature, clamped.
  ///
  /// Clamped on write as well as on read: an out-of-range value is rejected by
  /// some endpoints, and storing one would leave the user with a provider that
  /// silently fails until they notice the number.
  Future<void> setTemperature(double value) =>
      _prefs.setPref(AiPrefKeys.temperature, AiDefaults.clampTemperature(value));

  Future<void> setOpenaiModel(String value) =>
      _prefs.setPref(AiPrefKeys.openaiModel, value.trim());

  Future<void> setGeminiModel(String value) =>
      _prefs.setPref(AiPrefKeys.geminiModel, value.trim());

  Future<void> setGeminiThinkingLevel(AiGeminiThinkingLevel value) =>
      _prefs.setPref(AiPrefKeys.geminiThinkingLevel, value.wire);

  Future<void> setDeepseekModel(String value) =>
      _prefs.setPref(AiPrefKeys.deepseekModel, value.trim());

  Future<void> setDeepseekThinkingMode(AiThinkingMode value) =>
      _prefs.setPref(AiPrefKeys.deepseekThinkingMode, value.wire);

  Future<void> setDeepseekThinkingIntensity(AiThinkingIntensity value) =>
      _prefs.setPref(AiPrefKeys.deepseekThinkingIntensity, value.wire);

  Future<void> setCustomEndpoint(String value) =>
      _prefs.setPref(AiPrefKeys.customEndpoint, value.trim());

  Future<void> setCustomModel(String value) =>
      _prefs.setPref(AiPrefKeys.customModel, value.trim());

  Future<void> setCustomRoutingMode(AiProviderRoutingMode value) =>
      _prefs.setPref(AiPrefKeys.customRoutingMode, value.wire);

  Future<void> setCustomRoutingSlugs(String value) =>
      _prefs.setPref(AiPrefKeys.customRoutingSlugs, value);

  Future<void> setCustomAllowFallbacks(bool value) =>
      _prefs.setPref(AiPrefKeys.customRoutingAllowFallbacks, value);

  Future<void> setCustomThinkingMode(AiThinkingMode value) =>
      _prefs.setPref(AiPrefKeys.customThinkingMode, value.wire);

  Future<void> setCustomThinkingIntensity(AiThinkingIntensity value) =>
      _prefs.setPref(AiPrefKeys.customThinkingIntensity, value.wire);

  Future<void> setCustomThinkingValue(String value) =>
      _prefs.setPref(AiPrefKeys.customThinkingValue, value.trim());

  /// Stores the Custom Request Body JSON.
  ///
  /// Trimmed only. Validation happens where it can produce a useful message —
  /// the settings UI validates eagerly so a typo is caught while the user is
  /// looking at the field, and the request builder rejects it again before any
  /// network call so a bad value can never reach a provider.
  Future<void> setCustomRequestBodyJson(String value) =>
      _prefs.setPref(AiPrefKeys.customRequestBodyJson, value.trim());

  String _string(String key, [String fallback = '']) {
    final Object? value = _prefs.getPref(key, defaultValue: fallback);
    return value is String ? value : fallback;
  }

  bool _bool(String key, bool fallback) {
    final Object? value = _prefs.getPref(key, defaultValue: fallback);
    return value is bool ? value : fallback;
  }

  /// Reads the temperature defensively.
  ///
  /// Stored values outlive code: the preference table is untyped, an older build
  /// or a hand-edited row can leave an int or a string here, and a lookup must
  /// not throw because of it.
  double _temperature() {
    final Object? value =
        _prefs.getPref(AiPrefKeys.temperature, defaultValue: AiDefaults.temperature);
    if (value is double) return AiDefaults.clampTemperature(value);
    if (value is int) return AiDefaults.clampTemperature(value.toDouble());
    if (value is String) {
      // Accept a comma decimal separator, as the reference's settings field
      // does — a lot of locales type 0,7.
      return AiDefaults.clampTemperature(
          double.tryParse(value.trim().replaceAll(',', '.')));
    }
    return AiDefaults.temperature;
  }
}
