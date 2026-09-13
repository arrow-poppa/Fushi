import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_gemini_request.dart';
import 'package:fushi/src/ai/ai_prompt_renderer.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_request_builder.dart';

/// Gemini's routing is the least obvious part of the whole feature: two of the
/// model ids offered in the reference's dropdown silently target a **different
/// host** from the rest, an undocumented `low-thinking` substring rewrites the
/// model id outright, and the request body shape differs between the two hosts.
///
/// None of that is discoverable from the settings UI, so it is pinned here. The
/// full 360-case matrix (18 model ids x 5 thinking levels x streaming x system
/// prompt) was diffed against the reference implementation and matched exactly;
/// this file keeps the cases a future edit is most likely to break.
///
/// See `docs/agent/ai-explanation.md` §5.3.
void main() {
  AiRenderedPrompts prompts({String system = ''}) => AiPromptRenderer.render(
    userTemplate: 'explain {{target}}',
    systemTemplate: system,
    target: 'word',
    sentence: 'ctx',
  );

  AiGeminiRoute route(
    String model, [
    AiGeminiThinkingLevel level = AiGeminiThinkingLevel.unset,
  ]) => AiGeminiRequestBuilder.resolveRoute(
    modelId: model,
    configuredLevel: level,
  );

  group('model id sanitisation', () {
    test('empty falls back to the default model', () {
      expect(route('').apiModelId, 'gemini-2.5-flash');
    });

    test('strips a models/ prefix', () {
      expect(route('models/gemini-2.5-flash').apiModelId, 'gemini-2.5-flash');
    });

    test('strips a -latest suffix', () {
      expect(route('gemini-2.5-flash-latest').apiModelId, 'gemini-2.5-flash');
    });

    test('strips a -vertex suffix and switches host', () {
      final AiGeminiRoute r = route('gemini-3-flash-preview-vertex');
      expect(r.apiModelId, 'gemini-3-flash-preview');
      expect(r.useVertexExpress, isTrue);
    });

    test('a low-thinking model id is rewritten and forced onto Vertex', () {
      // Undocumented in the UI: any id containing `low-thinking` becomes
      // gemini-3-flash-preview regardless of what the user typed.
      final AiGeminiRoute r = route('gemini-low-thinking');
      expect(r.apiModelId, 'gemini-3-flash-preview');
      expect(r.useVertexExpress, isTrue);
      expect(
        r.thinkingLevel,
        'LOW',
        reason: 'low-thinking defaults the level to LOW',
      );
    });
  });

  group('host selection', () {
    test('the public API is the default host', () {
      expect(route('gemini-2.5-flash').useVertexExpress, isFalse);
    });

    test('the Pro previews are forced onto Vertex without any suffix', () {
      expect(route('gemini-3-pro-preview').useVertexExpress, isTrue);
      expect(route('gemini-3-pro-image-preview').useVertexExpress, isTrue);
    });

    test('a plain 3.1 pro preview stays on the public API', () {
      expect(
        route('gemini-3.1-pro-preview').useVertexExpress,
        isFalse,
        reason: 'only the -vertex variant switches host',
      );
    });
  });

  group('thinking level normalisation', () {
    test('non-Gemini-3 models never carry a thinking level', () {
      expect(
        route('gemini-2.5-pro', AiGeminiThinkingLevel.high).thinkingLevel,
        isEmpty,
      );
      expect(
        route('gemini-2.0-flash', AiGeminiThinkingLevel.medium).thinkingLevel,
        isEmpty,
      );
    });

    test('Gemini 3 models keep the configured level', () {
      expect(
        route(
          'gemini-3-flash-preview',
          AiGeminiThinkingLevel.medium,
        ).thinkingLevel,
        'MEDIUM',
      );
    });

    test('the Pro previews fold MINIMAL to LOW and MEDIUM to HIGH', () {
      // They accept only LOW and HIGH, so the others must be mapped rather than
      // sent and rejected.
      for (final String model in <String>[
        'gemini-3-pro-preview',
        'gemini-3.1-pro-preview',
      ]) {
        expect(
          route(model, AiGeminiThinkingLevel.minimal).thinkingLevel,
          'LOW',
          reason: '$model folds MINIMAL to LOW',
        );
        expect(
          route(model, AiGeminiThinkingLevel.medium).thinkingLevel,
          'HIGH',
          reason: '$model folds MEDIUM to HIGH',
        );
        expect(route(model, AiGeminiThinkingLevel.low).thinkingLevel, 'LOW');
        expect(route(model, AiGeminiThinkingLevel.high).thinkingLevel, 'HIGH');
        expect(
          route(model, AiGeminiThinkingLevel.unset).thinkingLevel,
          isEmpty,
        );
      }
    });
  });

  group('URL construction', () {
    AiHttpRequest build(String model, {required bool stream}) =>
        AiGeminiRequestBuilder.build(
          config: AiProviderConfig(
            provider: AiProvider.gemini,
            geminiModel: model,
          ),
          prompts: prompts(),
          apiKey: 'SECRET-KEY',
          stream: stream,
        );

    test('non-streaming uses generateContent on the public host', () {
      expect(
        build('gemini-2.5-flash', stream: false).url,
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-2.5-flash:generateContent?key=SECRET-KEY',
      );
    });

    test('streaming uses streamGenerateContent with alt=sse', () {
      expect(
        build('gemini-2.5-flash', stream: true).url,
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-2.5-flash:streamGenerateContent?alt=sse&key=SECRET-KEY',
      );
    });

    test('a Vertex model uses the aiplatform host', () {
      expect(
        build('gemini-3-pro-preview', stream: false).url,
        startsWith(
          'https://aiplatform.googleapis.com/v1/publishers/google/'
          'models/gemini-3-pro-preview:generateContent',
        ),
      );
    });

    test('authenticates with a query parameter and no auth header', () {
      final AiHttpRequest request = build('gemini-2.5-flash', stream: false);
      expect(
        request.headers.containsKey('Authorization'),
        isFalse,
        reason: 'Gemini offers no header alternative',
      );
      expect(request.url, contains('key=SECRET-KEY'));
    });

    test('safeUrl redacts the key so the URL can be logged', () {
      // The whole point: Gemini URLs are secrets, and anything that reports a
      // request must use safeUrl.
      final AiHttpRequest request = build('gemini-2.5-flash', stream: true);
      expect(request.safeUrl, isNot(contains('SECRET-KEY')));
      expect(request.safeUrl, contains('key=%3Credacted%3E'));
      expect(
        request.safeUrl,
        contains('alt=sse'),
        reason: 'non-credential parameters stay readable',
      );
    });
  });

  group('request body', () {
    Map<String, Object?> body(String model, {String system = ''}) =>
        AiGeminiRequestBuilder.build(
          config: AiProviderConfig(
            provider: AiProvider.gemini,
            geminiModel: model,
          ),
          prompts: prompts(system: system),
          apiKey: 'k',
          stream: false,
        ).body;

    test('the public API body omits the content role', () {
      final List<Object?> contents =
          body('gemini-2.5-flash')['contents']! as List<Object?>;
      final Map<String, Object?> first =
          contents.single as Map<String, Object?>;
      expect(first.containsKey('role'), isFalse);
      expect(first['parts'], <Object?>[
        <String, Object?>{'text': 'explain word'},
      ]);
    });

    test('the Vertex body names the content role', () {
      // The two hosts are different services; this asymmetry is real.
      final List<Object?> contents =
          body('gemini-3-pro-preview')['contents']! as List<Object?>;
      expect((contents.single as Map<String, Object?>)['role'], 'user');
    });

    test('omits systemInstruction when there is no system prompt', () {
      expect(
        body('gemini-2.5-flash').containsKey('systemInstruction'),
        isFalse,
      );
    });

    test('includes systemInstruction when one is set', () {
      expect(
        body('gemini-2.5-flash', system: 'be terse')['systemInstruction'],
        <String, Object?>{
          'parts': <Object?>[
            <String, Object?>{'text': 'be terse'},
          ],
        },
      );
    });

    test('adds thinkingConfig only for a Gemini 3 model with a level', () {
      Map<String, Object?> gen(String model, AiGeminiThinkingLevel level) =>
          AiGeminiRequestBuilder.buildBody(
                prompts: prompts(),
                route: AiGeminiRequestBuilder.resolveRoute(
                  modelId: model,
                  configuredLevel: level,
                ),
                temperature: 0.7,
              )['generationConfig']!
              as Map<String, Object?>;

      expect(
        gen('gemini-3-flash-preview', AiGeminiThinkingLevel.high),
        <String, Object?>{
          'temperature': 0.7,
          'thinkingConfig': <String, Object?>{'thinkingLevel': 'HIGH'},
        },
      );
      expect(
        gen('gemini-2.5-flash', AiGeminiThinkingLevel.high),
        <String, Object?>{'temperature': 0.7},
        reason: 'a 2.x model must not receive thinkingConfig',
      );
      expect(
        gen('gemini-3-flash-preview', AiGeminiThinkingLevel.unset),
        <String, Object?>{'temperature': 0.7},
        reason: 'no level means let the API default apply',
      );
    });

    test('clamps the temperature', () {
      final Map<String, Object?> gen =
          AiGeminiRequestBuilder.buildBody(
                prompts: prompts(),
                route: AiGeminiRequestBuilder.resolveRoute(
                  modelId: 'gemini-2.5-flash',
                  configuredLevel: AiGeminiThinkingLevel.unset,
                ),
                temperature: 99,
              )['generationConfig']!
              as Map<String, Object?>;
      expect(gen['temperature'], 2.0);
    });
  });
}
