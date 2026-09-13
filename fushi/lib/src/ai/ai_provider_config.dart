/// Configuration value objects for the BYOK AI Explanation feature.
///
/// Mirrors the reference extension's `ai.*` options subtree
/// (`data/schemas/options-schema.json:1389-1508`, GPL-3.0, Copyright (C)
/// 2023-2025 Yomitan Authors). Every `wire` string below is the **persisted**
/// value and is chosen to equal the reference's, so a user's settings mean the
/// same thing in both products and so the request builders can be compared
/// against upstream field by field. See `docs/agent/ai-explanation.md` §5.1.
///
/// Deliberately immutable and Flutter-free: this is the input to the prompt
/// renderer and the request builders, and it doubles as part of the cache key,
/// so deriving a signature from it has to be cheap and exact.
library;

import 'dart:convert';

import 'package:fushi/src/ai/ai_prompt_renderer.dart';

/// The four supported providers.
enum AiProvider {
  openai('openai'),
  gemini('gemini'),
  deepseek('deepseek'),

  /// Any OpenAI-compatible endpoint the user supplies, including OpenRouter.
  custom('custom');

  const AiProvider(this.wire);

  /// Persisted value. Never rename: it is user data.
  final String wire;

  /// Parses a persisted value, falling back to the reference default.
  static AiProvider fromWire(String? value) {
    for (final AiProvider provider in AiProvider.values) {
      if (provider.wire == value) return provider;
    }
    return AiProvider.openai;
  }
}

/// Whether to ask the model to think, to tell it not to, or to say nothing.
///
/// [unset] is the reference's empty string: it means "send no thinking field at
/// all", which is materially different from explicitly enabling or disabling it.
enum AiThinkingMode {
  unset(''),
  enabled('enabled'),
  disabled('disabled');

  const AiThinkingMode(this.wire);
  final String wire;

  static AiThinkingMode fromWire(String? value) {
    for (final AiThinkingMode mode in AiThinkingMode.values) {
      if (mode.wire == value) return mode;
    }
    return AiThinkingMode.unset;
  }
}

/// How hard the model should think, when the endpoint understands the concept.
enum AiThinkingIntensity {
  unset(''),
  high('high'),
  max('max'),

  /// Defer to a free-text value, which may be a word, an integer or a JSON
  /// object — see `docs/agent/ai-explanation.md` §5.4.
  custom('custom');

  const AiThinkingIntensity(this.wire);
  final String wire;

  static AiThinkingIntensity fromWire(String? value) {
    for (final AiThinkingIntensity intensity in AiThinkingIntensity.values) {
      if (intensity.wire == value) return intensity;
    }
    return AiThinkingIntensity.unset;
  }
}

/// Gemini's own thinking scale, a separate axis from [AiThinkingMode].
///
/// Persisted upper-case because that is the casing the Gemini API expects in
/// `generationConfig.thinkingConfig.thinkingLevel`.
enum AiGeminiThinkingLevel {
  unset(''),
  minimal('MINIMAL'),
  low('LOW'),
  medium('MEDIUM'),
  high('HIGH');

  const AiGeminiThinkingLevel(this.wire);
  final String wire;

  static AiGeminiThinkingLevel fromWire(String? value) {
    for (final AiGeminiThinkingLevel level in AiGeminiThinkingLevel.values) {
      if (level.wire == value) return level;
    }
    return AiGeminiThinkingLevel.unset;
  }
}

/// OpenRouter provider-routing strategy.
///
/// Only meaningful when the custom endpoint really is OpenRouter; on any other
/// host these settings are inert, exactly as upstream.
enum AiProviderRoutingMode {
  unset(''),

  /// Prioritise the listed providers (`provider.order`).
  order('order'),

  /// Restrict to the listed providers (`provider.only`).
  only('only'),

  /// Exclude the listed providers (`provider.ignore`).
  ignore('ignore');

  const AiProviderRoutingMode(this.wire);
  final String wire;

  static AiProviderRoutingMode fromWire(String? value) {
    for (final AiProviderRoutingMode mode in AiProviderRoutingMode.values) {
      if (mode.wire == value) return mode;
    }
    return AiProviderRoutingMode.unset;
  }
}

/// Reference defaults, kept in one place so the settings UI, the config object
/// and the tests cannot drift apart.
abstract final class AiDefaults {
  static const AiProvider provider = AiProvider.openai;
  static const String openaiModel = 'gpt-4o-mini';
  static const String geminiModel = 'gemini-2.5-flash';
  static const double temperature = 0.7;
  static const bool autoGenerateOnLookup = true;
  static const bool streamResponse = false;
  static const bool cancelPendingRequests = true;
  static const bool unknownWordFallback = false;
  static const bool providerAllowFallbacks = true;
  static const String userPrompt = kAiDefaultUserPrompt;
  static const String systemPrompt = '';

  /// Clamp applied to every temperature that reaches a provider.
  ///
  /// The reference clamps to `[0, 2]` and substitutes `0.7` for anything that is
  /// not a finite number (`ai-provider.js:79-84`); a value outside the range is
  /// a hard error on some endpoints, so this is a correctness guard, not polish.
  static double clampTemperature(double? value) {
    if (value == null || !value.isFinite) return temperature;
    return value.clamp(0.0, 2.0);
  }
}

/// Everything the request builders need, minus the credential.
///
/// API keys are **not** fields here on purpose: this object is compared for
/// cache keys, passed across layers and may end up in a debug trace, and a
/// credential that never enters it cannot leak from it. The client reads the key
/// from the credential store at send time. See `docs/agent/ai-explanation.md`
/// §9.
class AiProviderConfig {
  const AiProviderConfig({
    this.provider = AiDefaults.provider,
    this.openaiModel = AiDefaults.openaiModel,
    this.geminiModel = AiDefaults.geminiModel,
    this.geminiThinkingLevel = AiGeminiThinkingLevel.unset,
    this.deepseekModel = '',
    this.deepseekThinkingMode = AiThinkingMode.unset,
    this.deepseekThinkingIntensity = AiThinkingIntensity.unset,
    this.customEndpoint = '',
    this.customModel = '',
    this.customRoutingMode = AiProviderRoutingMode.unset,
    this.customRoutingSlugs = '',
    this.customAllowFallbacks = AiDefaults.providerAllowFallbacks,
    this.customThinkingMode = AiThinkingMode.unset,
    this.customThinkingIntensity = AiThinkingIntensity.unset,
    this.customThinkingValue = '',
    this.customRequestBodyJson = '',
    this.userPrompt = AiDefaults.userPrompt,
    this.systemPrompt = AiDefaults.systemPrompt,
    this.temperature = AiDefaults.temperature,
    this.autoGenerateOnLookup = AiDefaults.autoGenerateOnLookup,
    this.streamResponse = AiDefaults.streamResponse,
    this.cancelPendingRequests = AiDefaults.cancelPendingRequests,
    this.unknownWordFallback = AiDefaults.unknownWordFallback,
  });

  final AiProvider provider;

  final String openaiModel;

  final String geminiModel;
  final AiGeminiThinkingLevel geminiThinkingLevel;

  final String deepseekModel;
  final AiThinkingMode deepseekThinkingMode;
  final AiThinkingIntensity deepseekThinkingIntensity;

  /// Used verbatim — no path is ever appended. The user supplies the full
  /// `/v1/chat/completions` URL, matching the reference.
  final String customEndpoint;
  final String customModel;
  final AiProviderRoutingMode customRoutingMode;

  /// Comma- or newline-separated OpenRouter provider slugs.
  final String customRoutingSlugs;
  final bool customAllowFallbacks;
  final AiThinkingMode customThinkingMode;
  final AiThinkingIntensity customThinkingIntensity;

  /// Free-text intensity: a word, an integer, or a JSON object.
  final String customThinkingValue;

  /// Raw JSON deep-merged over the generated request body.
  final String customRequestBodyJson;

  final String userPrompt;
  final String systemPrompt;
  final double temperature;

  final bool autoGenerateOnLookup;
  final bool streamResponse;
  final bool cancelPendingRequests;
  final bool unknownWordFallback;

  /// The model id that will actually be sent for [provider].
  ///
  /// Empty for DeepSeek and Custom when the user has not set one; [isConfigured]
  /// rejects that before a request is built.
  String get activeModel {
    switch (provider) {
      case AiProvider.openai:
        return openaiModel;
      case AiProvider.gemini:
        return geminiModel;
      case AiProvider.deepseek:
        return deepseekModel;
      case AiProvider.custom:
        return customModel;
    }
  }

  /// Whether this provider still needs a model id before it can be used.
  ///
  /// OpenAI and Gemini ship usable defaults; DeepSeek and Custom do not.
  /// Mirrors `AIExplanationGenerator._isProviderConfigured`
  /// (`ai-explanation-generator.js:296-308`), which is stricter than the
  /// provider classes' own `isConfigured()` — upstream the generator's check
  /// runs first, so it is the one that decides observable behaviour.
  bool get requiresModel =>
      provider == AiProvider.deepseek || provider == AiProvider.custom;

  /// Whether the configuration is complete enough to send a request, given that
  /// a non-empty API key is present.
  ///
  /// The key lives in the credential store, so its presence is passed in rather
  /// than read from here.
  bool isConfigured({required bool hasApiKey}) {
    if (!hasApiKey) return false;
    if (provider == AiProvider.custom && customEndpoint.trim().isEmpty) {
      return false;
    }
    if (requiresModel && activeModel.trim().isEmpty) return false;
    return true;
  }

  /// The parts of the configuration that change the generated answer.
  ///
  /// This is the provider/model/prompt half of the cache key. **Divergence from
  /// the reference** (`docs/agent/ai-explanation.md` §8.3): upstream keys only
  /// on `[profileIndex, term, sentence]`, so changing the model or the prompt
  /// keeps returning the previous answer for up to 60 seconds. Including the
  /// generation context here is what makes "change the model, look the word up
  /// again" actually produce a new answer.
  ///
  /// JSON-encoded rather than delimiter-joined so that no prompt content can
  /// forge a field boundary. The API key is intentionally absent: it does not
  /// change the answer, and leaving it out keeps cache keys safe to log.
  String get generationSignature {
    final List<Object?> parts = <Object?>[
      provider.wire,
      activeModel,
      userPrompt,
      systemPrompt,
      AiDefaults.clampTemperature(temperature),
    ];
    // Only the active provider's knobs participate: a Gemini thinking level
    // cannot change an OpenAI answer, and folding it in would evict the cache on
    // an edit that changes nothing about the outgoing request.
    if (provider == AiProvider.gemini) {
      parts.add(geminiThinkingLevel.wire);
    } else if (provider == AiProvider.deepseek) {
      parts
        ..add(deepseekThinkingMode.wire)
        ..add(deepseekThinkingIntensity.wire);
    } else if (provider == AiProvider.custom) {
      parts
        ..add(customEndpoint)
        ..add(customRoutingMode.wire)
        ..add(customRoutingSlugs)
        ..add(customAllowFallbacks)
        ..add(customThinkingMode.wire)
        ..add(customThinkingIntensity.wire)
        ..add(customThinkingValue)
        ..add(customRequestBodyJson);
    }
    return jsonEncode(parts);
  }
}
