/// Request construction for the OpenAI-compatible providers (OpenAI, DeepSeek
/// and any Custom endpoint including OpenRouter).
///
/// Ported from the reference extension's provider classes
/// (`js/comm/ai-provider.js`, GPL-3.0, Copyright (C) 2023-2025 Yomitan
/// Authors); the per-field contracts and the reasoning mapping table are in
/// `docs/agent/ai-explanation.md` §5.3-§5.5.
///
/// Everything here is pure: it turns a config plus rendered prompts into a URL,
/// headers and a JSON body. No I/O, so the whole wire format is unit-testable
/// without a network — which matters for a BYOK feature where a malformed body
/// costs the user real money to discover.
library;

import 'dart:convert';

import 'package:fushi/src/ai/ai_prompt_renderer.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';

/// Thrown when the user's configuration cannot produce a valid request.
///
/// Carries a message that is safe to show: it never embeds a credential, an
/// Authorization header or a full request body.
class AiRequestException implements Exception {
  const AiRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// OpenAI's fixed Chat Completions endpoint. The reference hardcodes it and
/// offers no override; a user who needs a different host uses the Custom
/// provider.
const String kOpenAiEndpoint = 'https://api.openai.com/v1/chat/completions';

/// DeepSeek's fixed endpoint. Note there is **no** `/v1` segment — adding one
/// 404s.
const String kDeepSeekEndpoint = 'https://api.deepseek.com/chat/completions';

/// Identifies this app to OpenRouter's dashboard.
///
/// **Divergence from the reference** (`docs/agent/ai-explanation.md` §8.6):
/// upstream sends `HTTP-Referer: https://yomitan.wiki/` and
/// `X-OpenRouter-Title: Yomitan`. Fushi must not claim to be Yomitan, and
/// `X-OpenRouter-Title` is not even the header OpenRouter documents — the
/// documented one is `X-Title`, so upstream's app name never actually shows up.
/// The referer is the public project URL and deliberately carries nothing about
/// the user.
const String kOpenRouterRefererHeader = 'https://github.com/hajisensai/Fushi';
const String kOpenRouterTitleHeader = 'Fushi';

/// A fully-built HTTP request, ready for the client to send.
class AiHttpRequest {
  const AiHttpRequest({
    required this.url,
    required this.headers,
    required this.body,
  });

  final String url;

  /// Includes the Authorization header — **never log this map**.
  final Map<String, String> headers;

  final Map<String, Object?> body;

  /// The encoded body. Also never safe to log: it contains the user's prompts.
  String encodeBody() => jsonEncode(body);

  /// The URL with any credential-bearing query parameter removed.
  ///
  /// Gemini is the one provider that authenticates with `?key=<apiKey>` rather
  /// than a header, so its URL *is* a secret. Anything that reports a request —
  /// a log line, an error message, a bug report — must use this and never
  /// [url]. See `docs/agent/ai-explanation.md` §9.
  String get safeUrl {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return '<invalid url>';
    if (uri.queryParameters.isEmpty) return uri.toString();
    final Map<String, String> safe = <String, String>{
      for (final MapEntry<String, String> e in uri.queryParameters.entries)
        e.key: _credentialQueryKeys.contains(e.key.toLowerCase())
            ? '<redacted>'
            : e.value,
    };
    return uri.replace(queryParameters: safe).toString();
  }

  static const Set<String> _credentialQueryKeys = <String>{
    'key',
    'api_key',
    'apikey',
    'access_token',
    'token',
  };
}

/// Pure helpers shared by every OpenAI-compatible provider.
abstract final class AiRequestBuilder {
  /// Whether [endpoint] really is OpenRouter.
  ///
  /// **Divergence from the reference** (`docs/agent/ai-explanation.md` §8.4):
  /// upstream uses `hostname.endsWith('openrouter.ai')`, which also matches
  /// `evil-openrouter.ai` and `notopenrouter.ai` — and being treated as
  /// OpenRouter means the request grows identifying headers and reasoning
  /// fields aimed at a host the user did not intend. Matching the registrable
  /// domain or a true subdomain closes that.
  static bool isOpenRouterEndpoint(String endpoint) {
    final Uri? uri = Uri.tryParse(endpoint.trim());
    if (uri == null || !uri.hasAuthority) return false;
    final String host = uri.host.toLowerCase();
    return host == 'openrouter.ai' || host.endsWith('.openrouter.ai');
  }

  /// Splits the OpenRouter provider slug list.
  ///
  /// Comma- and/or newline-separated, trimmed, empties dropped — matching
  /// `ai-provider.js:231-233`.
  static List<String> parseProviderSlugs(String raw) {
    return raw
        .split(RegExp(r'[\n,]+'))
        .map((String slug) => slug.trim())
        .where((String slug) => slug.isNotEmpty)
        .toList();
  }

  /// Builds the `messages` array.
  ///
  /// A request is never produced without a user message: [AiPromptRenderer]
  /// guarantees a non-empty user prompt, and an empty system prompt omits the
  /// system message entirely rather than sending `content: ""`.
  static List<Map<String, String>> buildMessages(AiRenderedPrompts prompts) {
    return <Map<String, String>>[
      if (prompts.hasSystemPrompt)
        <String, String>{'role': 'system', 'content': prompts.systemPrompt},
      <String, String>{'role': 'user', 'content': prompts.userPrompt},
    ];
  }

  /// Parses the free-text Custom Thinking Intensity Value.
  ///
  /// Ported verbatim from `_parseCustomReasoningValue`
  /// (`ai-provider.js:139-156`), including the fall-through: a value that starts
  /// with `{` but is not a valid JSON **object** becomes an `effort` string
  /// containing the braces, rather than an error.
  static Map<String, Object?> parseCustomReasoningValue(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) return <String, Object?>{};
    if (RegExp(r'^\d+$').hasMatch(trimmed)) {
      return <String, Object?>{'max_tokens': int.parse(trimmed)};
    }
    if (trimmed.startsWith('{')) {
      try {
        final Object? parsed = jsonDecode(trimmed);
        if (parsed is Map<String, Object?>) return parsed;
        if (parsed is Map) return Map<String, Object?>.from(parsed);
      } on FormatException {
        // Fall through to effort below for invalid JSON, as upstream does.
      }
    }
    return <String, Object?>{'effort': trimmed == 'max' ? 'xhigh' : trimmed};
  }

  /// Applies thinking / reasoning options to [body].
  ///
  /// Two completely different shapes depending on the host — see the mapping
  /// table in `docs/agent/ai-explanation.md` §5.4. Note that `max` becomes
  /// `xhigh` **only** on OpenRouter; elsewhere it is sent through unchanged.
  static void applyReasoningOptions(
    Map<String, Object?> body, {
    required AiThinkingMode thinkingMode,
    required AiThinkingIntensity thinkingIntensity,
    required String customThinkingValue,
    required bool isOpenRouter,
  }) {
    final String customValue = customThinkingValue.trim();
    final String effectiveIntensity =
        thinkingIntensity == AiThinkingIntensity.custom
            ? customValue
            : thinkingIntensity.wire;
    final bool hasThinkingMode = thinkingMode == AiThinkingMode.enabled ||
        thinkingMode == AiThinkingMode.disabled;
    final bool hasIntensity = effectiveIntensity.isNotEmpty;

    // Neither axis set means the user never asked for thinking control, and the
    // request must stay byte-identical to one from a build without the feature.
    if (!hasThinkingMode && !hasIntensity) return;

    if (isOpenRouter) {
      final Map<String, Object?> reasoning = <String, Object?>{};
      if (thinkingMode == AiThinkingMode.disabled) {
        reasoning['effort'] = 'none';
      } else if (thinkingIntensity == AiThinkingIntensity.custom &&
          customValue.isNotEmpty) {
        reasoning.addAll(parseCustomReasoningValue(customValue));
      } else if (hasIntensity) {
        reasoning['effort'] =
            effectiveIntensity == 'max' ? 'xhigh' : effectiveIntensity;
      } else if (hasThinkingMode) {
        reasoning['enabled'] = true;
      }
      // Unconditional, and deliberately after the custom merge: internal
      // thinking must never reach the popup, so a user-supplied
      // `{"exclude": false}` here is overridden.
      reasoning['exclude'] = true;
      body['reasoning'] = reasoning;
      return;
    }

    if (hasThinkingMode) {
      body['thinking'] = <String, Object?>{'type': thinkingMode.wire};
    }
    if (thinkingMode != AiThinkingMode.disabled && hasIntensity) {
      body['reasoning_effort'] = effectiveIntensity;
    }
  }

  /// Applies OpenRouter provider routing to [body].
  ///
  /// Inert on every other host, matching upstream. Note that because
  /// `allow_fallbacks` is always a boolean, an OpenRouter request carries at
  /// minimum `provider: {allow_fallbacks: true}` even with routing left on
  /// Default and no slugs listed.
  static void applyOpenRouterProviderOptions(
    Map<String, Object?> body, {
    required AiProviderRoutingMode routingMode,
    required String routingSlugs,
    required bool allowFallbacks,
    required bool isOpenRouter,
  }) {
    if (!isOpenRouter) return;

    final List<String> slugs = parseProviderSlugs(routingSlugs);
    final Map<String, Object?> provider = <String, Object?>{};

    if (slugs.isNotEmpty) {
      switch (routingMode) {
        case AiProviderRoutingMode.order:
          provider['order'] = slugs;
        case AiProviderRoutingMode.only:
          provider['only'] = slugs;
        case AiProviderRoutingMode.ignore:
          provider['ignore'] = slugs;
        case AiProviderRoutingMode.unset:
          break;
      }
    }

    provider['allow_fallbacks'] = allowFallbacks;

    if (provider.isNotEmpty) body['provider'] = provider;
  }

  /// Deep-merges the user's Custom Request Body JSON over [body].
  ///
  /// Validation matches `_applyCustomRequestBodyJson`
  /// (`ai-provider.js:162-175`): only a top-level JSON **object** is accepted;
  /// an array, `null`, a scalar or malformed JSON throws **before** any network
  /// call, so a typo costs nothing.
  static void applyCustomRequestBodyJson(
    Map<String, Object?> body,
    String rawJson,
  ) {
    final String raw = rawJson.trim();
    if (raw.isEmpty) return;

    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException catch (error) {
      throw AiRequestException(
        'Invalid Custom Request Body JSON: ${error.message}',
      );
    }
    if (parsed is! Map) {
      throw const AiRequestException(
        'Invalid Custom Request Body JSON: expected a JSON object.',
      );
    }
    deepMergeRequestBody(body, Map<String, Object?>.from(parsed));
  }

  /// Recursively merges [source] into [target].
  ///
  /// Two plain objects at the same key merge; anything else overwrites. Arrays
  /// are **never** concatenated — a custom `messages` array replaces the
  /// generated one wholesale — and an explicit `null` overwrites rather than
  /// deleting the key. Matches `_mergeRequestBody` (`ai-provider.js:181-193`).
  static void deepMergeRequestBody(
    Map<String, Object?> target,
    Map<String, Object?> source,
  ) {
    source.forEach((String key, Object? value) {
      final Object? existing = target[key];
      if (existing is Map && value is Map) {
        final Map<String, Object?> existingMap =
            existing is Map<String, Object?>
                ? existing
                : Map<String, Object?>.from(existing);
        deepMergeRequestBody(existingMap, Map<String, Object?>.from(value));
        target[key] = existingMap;
      } else {
        target[key] = value;
      }
    });
  }

  /// Builds the OpenAI request.
  ///
  /// The non-streaming body has **no** `stream` key at all, matching upstream;
  /// reasoning, routing and custom-body options are never applied to OpenAI.
  static AiHttpRequest buildOpenAi({
    required AiProviderConfig config,
    required AiRenderedPrompts prompts,
    required String apiKey,
    required bool stream,
  }) {
    final Map<String, Object?> body = <String, Object?>{
      'model': config.openaiModel.isEmpty
          ? AiDefaults.openaiModel
          : config.openaiModel,
      'messages': buildMessages(prompts),
      'temperature': AiDefaults.clampTemperature(config.temperature),
      if (stream) 'stream': true,
    };
    return AiHttpRequest(
      url: kOpenAiEndpoint,
      headers: <String, String>{
        'Content-Type': 'application/json',
        // Trimmed, unlike upstream: OpenAI is the one provider whose key is not
        // trimmed there, so a key pasted with a trailing newline fails only on
        // OpenAI. That is a bug, not a contract.
        'Authorization': 'Bearer ${apiKey.trim()}',
      },
      body: body,
    );
  }

  /// Builds the DeepSeek request.
  ///
  /// DeepSeek always carries an explicit `stream` field (unlike OpenAI), and its
  /// thinking options always take the non-OpenRouter shape because it has no
  /// user-supplied endpoint to be OpenRouter.
  static AiHttpRequest buildDeepSeek({
    required AiProviderConfig config,
    required AiRenderedPrompts prompts,
    required String apiKey,
    required bool stream,
  }) {
    final Map<String, Object?> body = <String, Object?>{
      'model': config.deepseekModel.trim(),
      'messages': buildMessages(prompts),
      'stream': stream,
      'temperature': AiDefaults.clampTemperature(config.temperature),
    };
    applyReasoningOptions(
      body,
      thinkingMode: config.deepseekThinkingMode,
      thinkingIntensity: config.deepseekThinkingIntensity,
      customThinkingValue: '',
      isOpenRouter: false,
    );
    return AiHttpRequest(
      url: kDeepSeekEndpoint,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${apiKey.trim()}',
      },
      body: body,
    );
  }

  /// Builds the Custom / OpenRouter request.
  ///
  /// Order is load-bearing and matches upstream: base body, then reasoning, then
  /// provider routing, then the user's custom JSON merged over all of it — and
  /// only **after** that is `stream` assigned, so a stored `"stream": false`
  /// cannot silently disable a streaming the user turned on.
  ///
  /// The endpoint is used verbatim; no path is ever appended.
  static AiHttpRequest buildCustom({
    required AiProviderConfig config,
    required AiRenderedPrompts prompts,
    required String apiKey,
    required bool stream,
  }) {
    final String endpoint = config.customEndpoint.trim();
    final Uri? uri = Uri.tryParse(endpoint);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw const AiRequestException(
        'The custom endpoint must be a full URL, for example '
        'https://api.example.com/v1/chat/completions',
      );
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw AiRequestException(
        'Unsupported endpoint scheme "${uri.scheme}": use https (or http for a '
        'local endpoint).',
      );
    }

    final bool isOpenRouter = isOpenRouterEndpoint(endpoint);

    final Map<String, Object?> body = <String, Object?>{
      'model': config.customModel.isEmpty
          ? AiDefaults.openaiModel
          : config.customModel,
      'messages': buildMessages(prompts),
      'temperature': AiDefaults.clampTemperature(config.temperature),
    };
    applyReasoningOptions(
      body,
      thinkingMode: config.customThinkingMode,
      thinkingIntensity: config.customThinkingIntensity,
      customThinkingValue: config.customThinkingValue,
      isOpenRouter: isOpenRouter,
    );
    applyOpenRouterProviderOptions(
      body,
      routingMode: config.customRoutingMode,
      routingSlugs: config.customRoutingSlugs,
      allowFallbacks: config.customAllowFallbacks,
      isOpenRouter: isOpenRouter,
    );
    applyCustomRequestBodyJson(body, config.customRequestBodyJson);
    if (stream) body['stream'] = true;

    return AiHttpRequest(
      url: endpoint,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${apiKey.trim()}',
        if (isOpenRouter) ...<String, String>{
          'HTTP-Referer': kOpenRouterRefererHeader,
          'X-Title': kOpenRouterTitleHeader,
        },
      },
      body: body,
    );
  }
}
