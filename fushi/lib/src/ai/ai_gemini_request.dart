/// Gemini request construction.
///
/// Gemini is the odd one out: it authenticates with a query parameter instead of
/// a header, it has two different hosts reached by undocumented model-id
/// suffixes, and its request body shape differs between those two hosts. Ported
/// from `GeminiProvider._resolveRoute` / `_buildRequestBody`
/// (`js/comm/ai-provider.js:594-714`, GPL-3.0, Copyright (C) 2023-2025 Yomitan
/// Authors). See `docs/agent/ai-explanation.md` §5.3.
library;

import 'package:fushi/src/ai/ai_prompt_renderer.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_request_builder.dart';

/// Host for the public Gemini API.
const String kGeminiApiBase =
    'https://generativelanguage.googleapis.com/v1beta/models';

/// Host for the Vertex AI Express route, reached by the `-vertex` model suffix
/// and forced for a few preview models.
const String kGeminiVertexBase =
    'https://aiplatform.googleapis.com/v1/publishers/google/models';

/// The resolved routing decision for one Gemini model id.
///
/// Exposed separately from the request so the settings UI and the tests can
/// reason about "which host will this model actually hit", which is not obvious
/// from the dropdown: two of the offered options silently target a different
/// host from the rest.
class AiGeminiRoute {
  const AiGeminiRoute({
    required this.apiModelId,
    required this.useVertexExpress,
    required this.isGemini3Model,
    required this.thinkingLevel,
  });

  /// The model id actually sent, after stripping `models/`, `-latest` and
  /// `-vertex`, and after the `low-thinking` rewrite.
  final String apiModelId;

  final bool useVertexExpress;

  /// Only Gemini 3.x models accept a thinking configuration.
  final bool isGemini3Model;

  /// Upper-case level, or empty meaning "send no thinkingConfig at all".
  final String thinkingLevel;
}

abstract final class AiGeminiRequestBuilder {
  /// Resolves model id, host and effective thinking level.
  ///
  /// The order of these rules is load-bearing and reproduced exactly; several
  /// are undocumented in the settings UI:
  ///
  /// - a `models/` prefix and a `-latest` suffix are stripped;
  /// - a `-vertex` suffix selects the Vertex Express host;
  /// - a model id *containing* `low-thinking` is rewritten to
  ///   `gemini-3-flash-preview`, forced onto Vertex, and defaulted to `LOW`;
  /// - `gemini-3-pro-preview` and `gemini-3-pro-image-preview` are forced onto
  ///   Vertex regardless of suffix;
  /// - the Pro previews accept only `LOW` and `HIGH`, so `MINIMAL` folds to
  ///   `LOW`, `MEDIUM` folds to `HIGH`, and anything else is dropped;
  /// - a non-Gemini-3 model never carries a thinking level.
  static AiGeminiRoute resolveRoute({
    required String modelId,
    required AiGeminiThinkingLevel configuredLevel,
  }) {
    final String raw =
        modelId.trim().isEmpty ? AiDefaults.geminiModel : modelId.trim();

    String working = raw.startsWith('models/') ? raw.substring(7) : raw;
    bool useVertex = false;

    if (working.endsWith('-latest')) {
      working = working.substring(0, working.length - '-latest'.length);
    }
    if (working.endsWith('-vertex')) {
      working = working.substring(0, working.length - '-vertex'.length);
      useVertex = true;
    }

    final bool isLowThinking = working.contains('low-thinking');
    final String apiModelId =
        isLowThinking ? 'gemini-3-flash-preview' : working;
    if (isLowThinking) useVertex = true;

    if (apiModelId == 'gemini-3-pro-preview' ||
        apiModelId == 'gemini-3-pro-image-preview') {
      useVertex = true;
    }

    final bool isGemini3Model = apiModelId.contains('gemini-3');

    String level = configuredLevel.wire.toUpperCase();
    if (isLowThinking && level.isEmpty) level = 'LOW';

    if (apiModelId == 'gemini-3-pro-preview' ||
        apiModelId == 'gemini-3.1-pro-preview') {
      if (level == 'MINIMAL') {
        level = 'LOW';
      } else if (level == 'MEDIUM') {
        level = 'HIGH';
      } else if (level.isNotEmpty && level != 'LOW' && level != 'HIGH') {
        level = '';
      }
    }

    if (!isGemini3Model || level.isEmpty) level = '';

    return AiGeminiRoute(
      apiModelId: apiModelId,
      useVertexExpress: useVertex,
      isGemini3Model: isGemini3Model,
      thinkingLevel: level,
    );
  }

  /// Builds the request body.
  ///
  /// The two hosts take different shapes: the Vertex Express body names the
  /// content role (`role: 'user'`) and the public Gemini API body omits it.
  /// Reproduced rather than unified, because these are two different services.
  static Map<String, Object?> buildBody({
    required AiRenderedPrompts prompts,
    required AiGeminiRoute route,
    required double temperature,
  }) {
    final Map<String, Object?> generationConfig = <String, Object?>{
      'temperature': AiDefaults.clampTemperature(temperature),
    };
    if (route.thinkingLevel.isNotEmpty && route.isGemini3Model) {
      generationConfig['thinkingConfig'] = <String, Object?>{
        'thinkingLevel': route.thinkingLevel,
      };
    }

    return <String, Object?>{
      'contents': <Object?>[
        <String, Object?>{
          if (route.useVertexExpress) 'role': 'user',
          'parts': <Object?>[
            <String, Object?>{'text': prompts.userPrompt},
          ],
        },
      ],
      'generationConfig': generationConfig,
      if (prompts.hasSystemPrompt)
        'systemInstruction': <String, Object?>{
          'parts': <Object?>[
            <String, Object?>{'text': prompts.systemPrompt},
          ],
        },
    };
  }

  /// Builds the full Gemini request.
  ///
  /// 🔴 The returned [AiHttpRequest.url] contains the API key as a query
  /// parameter — Gemini offers no header alternative. Never log it; use
  /// [AiHttpRequest.safeUrl].
  static AiHttpRequest build({
    required AiProviderConfig config,
    required AiRenderedPrompts prompts,
    required String apiKey,
    required bool stream,
  }) {
    final AiGeminiRoute route = resolveRoute(
      modelId: config.geminiModel,
      configuredLevel: config.geminiThinkingLevel,
    );

    final String method = stream ? 'streamGenerateContent' : 'generateContent';
    final String base =
        route.useVertexExpress ? kGeminiVertexBase : kGeminiApiBase;
    final String query = Uri(queryParameters: <String, String>{
      if (stream) 'alt': 'sse',
      'key': apiKey.trim(),
    }).query;

    return AiHttpRequest(
      url: '$base/${route.apiModelId}:$method?$query',
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: buildBody(
        prompts: prompts,
        route: route,
        temperature: config.temperature,
      ),
    );
  }
}
