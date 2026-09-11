import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_prompt_renderer.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';

/// [AiProviderConfig] decides which endpoint is called, with which model, and
/// whether a request may be sent at all — and its [AiProviderConfig.generationSignature]
/// is half of the cache key, so a field missing from the signature means a user
/// changes a setting and keeps getting the old answer.
///
/// The `wire` strings are user data: they are what sits in the `preferences`
/// table, and they match the reference extension's persisted values so a
/// migrating user's settings keep their meaning. Renaming one is a data
/// migration, not a refactor — hence the round-trip test.
void main() {
  group('wire values match the reference and round-trip', () {
    test('provider wire values', () {
      expect(AiProvider.openai.wire, 'openai');
      expect(AiProvider.gemini.wire, 'gemini');
      expect(AiProvider.deepseek.wire, 'deepseek');
      expect(AiProvider.custom.wire, 'custom');
    });

    test('thinking mode and intensity wire values', () {
      expect(AiThinkingMode.unset.wire, '');
      expect(AiThinkingMode.enabled.wire, 'enabled');
      expect(AiThinkingMode.disabled.wire, 'disabled');
      expect(AiThinkingIntensity.unset.wire, '');
      expect(AiThinkingIntensity.high.wire, 'high');
      expect(AiThinkingIntensity.max.wire, 'max');
      expect(AiThinkingIntensity.custom.wire, 'custom');
    });

    test('gemini thinking levels are upper-case as the API expects', () {
      expect(AiGeminiThinkingLevel.unset.wire, '');
      expect(AiGeminiThinkingLevel.minimal.wire, 'MINIMAL');
      expect(AiGeminiThinkingLevel.low.wire, 'LOW');
      expect(AiGeminiThinkingLevel.medium.wire, 'MEDIUM');
      expect(AiGeminiThinkingLevel.high.wire, 'HIGH');
    });

    test('routing mode wire values', () {
      expect(AiProviderRoutingMode.unset.wire, '');
      expect(AiProviderRoutingMode.order.wire, 'order');
      expect(AiProviderRoutingMode.only.wire, 'only');
      expect(AiProviderRoutingMode.ignore.wire, 'ignore');
    });

    test('every enum round-trips through its wire value', () {
      for (final AiProvider v in AiProvider.values) {
        expect(AiProvider.fromWire(v.wire), v);
      }
      for (final AiThinkingMode v in AiThinkingMode.values) {
        expect(AiThinkingMode.fromWire(v.wire), v);
      }
      for (final AiThinkingIntensity v in AiThinkingIntensity.values) {
        expect(AiThinkingIntensity.fromWire(v.wire), v);
      }
      for (final AiGeminiThinkingLevel v in AiGeminiThinkingLevel.values) {
        expect(AiGeminiThinkingLevel.fromWire(v.wire), v);
      }
      for (final AiProviderRoutingMode v in AiProviderRoutingMode.values) {
        expect(AiProviderRoutingMode.fromWire(v.wire), v);
      }
    });

    test('unknown and null wire values fall back, never throw', () {
      // Stored settings outlive code. A value written by a newer build must
      // degrade to the default rather than crash the popup.
      expect(AiProvider.fromWire('nope'), AiProvider.openai);
      expect(AiProvider.fromWire(null), AiProvider.openai);
      expect(AiThinkingMode.fromWire('sideways'), AiThinkingMode.unset);
      expect(AiThinkingIntensity.fromWire(null), AiThinkingIntensity.unset);
      expect(AiGeminiThinkingLevel.fromWire('high'), AiGeminiThinkingLevel.unset,
          reason: 'gemini levels are upper-case; lower-case is not a match');
      expect(AiProviderRoutingMode.fromWire('x'), AiProviderRoutingMode.unset);
    });
  });

  group('defaults match the reference', () {
    test('scalar defaults', () {
      expect(AiDefaults.provider, AiProvider.openai);
      expect(AiDefaults.openaiModel, 'gpt-4o-mini');
      expect(AiDefaults.geminiModel, 'gemini-2.5-flash');
      expect(AiDefaults.temperature, 0.7);
      expect(AiDefaults.autoGenerateOnLookup, isTrue);
      expect(AiDefaults.streamResponse, isFalse,
          reason: 'streaming is opt-in upstream');
      expect(AiDefaults.cancelPendingRequests, isTrue);
      expect(AiDefaults.unknownWordFallback, isFalse,
          reason: 'the unknown-word fallback is opt-in upstream');
      expect(AiDefaults.providerAllowFallbacks, isTrue);
      expect(AiDefaults.userPrompt, kAiDefaultUserPrompt);
      expect(AiDefaults.systemPrompt, isEmpty);
    });

    test('a default-constructed config uses them', () {
      const AiProviderConfig config = AiProviderConfig();
      expect(config.provider, AiProvider.openai);
      expect(config.activeModel, 'gpt-4o-mini');
      expect(config.temperature, 0.7);
      expect(config.userPrompt, kAiDefaultUserPrompt);
    });
  });

  group('temperature clamping', () {
    test('clamps to the provider-accepted range', () {
      // Out-of-range values are a hard error on some endpoints, so this is a
      // correctness guard rather than cosmetic.
      expect(AiDefaults.clampTemperature(-1), 0.0);
      expect(AiDefaults.clampTemperature(0), 0.0);
      expect(AiDefaults.clampTemperature(1.3), 1.3);
      expect(AiDefaults.clampTemperature(2), 2.0);
      expect(AiDefaults.clampTemperature(99), 2.0);
    });

    test('non-finite and missing values fall back to the default', () {
      expect(AiDefaults.clampTemperature(null), 0.7);
      expect(AiDefaults.clampTemperature(double.nan), 0.7);
      expect(AiDefaults.clampTemperature(double.infinity), 0.7);
      expect(AiDefaults.clampTemperature(double.negativeInfinity), 0.7);
    });
  });

  group('activeModel', () {
    test('selects the model belonging to the active provider', () {
      const AiProviderConfig config = AiProviderConfig(
        openaiModel: 'gpt-o',
        geminiModel: 'gem',
        deepseekModel: 'ds',
        customModel: 'cus',
      );
      expect(config.activeModel, 'gpt-o');
      const Map<AiProvider, String> expected = <AiProvider, String>{
        AiProvider.openai: 'gpt-o',
        AiProvider.gemini: 'gem',
        AiProvider.deepseek: 'ds',
        AiProvider.custom: 'cus',
      };
      for (final AiProvider provider in AiProvider.values) {
        expect(
          AiProviderConfig(
            provider: provider,
            openaiModel: 'gpt-o',
            geminiModel: 'gem',
            deepseekModel: 'ds',
            customModel: 'cus',
          ).activeModel,
          expected[provider],
          reason: 'activeModel must follow the selected provider',
        );
      }
    });
  });

  group('isConfigured', () {
    test('a missing API key is disqualifying for every provider', () {
      for (final AiProvider provider in AiProvider.values) {
        expect(
          AiProviderConfig(
            provider: provider,
            deepseekModel: 'm',
            customModel: 'm',
            customEndpoint: 'https://example.com/v1/chat/completions',
          ).isConfigured(hasApiKey: false),
          isFalse,
          reason: '$provider must not be usable without a key',
        );
      }
    });

    test('OpenAI and Gemini are usable on their default models alone', () {
      expect(const AiProviderConfig(provider: AiProvider.openai)
          .isConfigured(hasApiKey: true), isTrue);
      expect(const AiProviderConfig(provider: AiProvider.gemini)
          .isConfigured(hasApiKey: true), isTrue);
    });

    test('DeepSeek additionally requires a model id', () {
      // Matches the reference generator's stricter check, which is the one that
      // decides observable behaviour upstream.
      expect(const AiProviderConfig(provider: AiProvider.deepseek)
          .isConfigured(hasApiKey: true), isFalse);
      expect(const AiProviderConfig(
              provider: AiProvider.deepseek, deepseekModel: 'deepseek-chat')
          .isConfigured(hasApiKey: true), isTrue);
      expect(const AiProviderConfig(
              provider: AiProvider.deepseek, deepseekModel: '   ')
          .isConfigured(hasApiKey: true), isFalse,
          reason: 'whitespace is not a model id');
    });

    test('Custom requires both an endpoint and a model id', () {
      const String url = 'https://api.example.com/v1/chat/completions';
      expect(const AiProviderConfig(provider: AiProvider.custom)
          .isConfigured(hasApiKey: true), isFalse);
      expect(const AiProviderConfig(
              provider: AiProvider.custom, customEndpoint: url)
          .isConfigured(hasApiKey: true), isFalse,
          reason: 'endpoint without model is incomplete');
      expect(const AiProviderConfig(
              provider: AiProvider.custom, customModel: 'm')
          .isConfigured(hasApiKey: true), isFalse,
          reason: 'model without endpoint is incomplete');
      expect(const AiProviderConfig(
              provider: AiProvider.custom, customEndpoint: url, customModel: 'm')
          .isConfigured(hasApiKey: true), isTrue);
    });
  });

  group('generationSignature (cache-key divergence §8.3)', () {
    const AiProviderConfig base = AiProviderConfig();

    test('is stable for an unchanged config', () {
      expect(base.generationSignature,
          const AiProviderConfig().generationSignature);
    });

    test('changes when the model changes', () {
      // This is the whole point of the divergence: upstream keys only on
      // [profile, term, sentence], so switching model returns the old answer.
      expect(
        const AiProviderConfig(openaiModel: 'gpt-4o').generationSignature,
        isNot(base.generationSignature),
      );
    });

    test('changes when the provider changes', () {
      expect(
        const AiProviderConfig(provider: AiProvider.gemini).generationSignature,
        isNot(base.generationSignature),
      );
    });

    test('changes when either prompt changes', () {
      expect(const AiProviderConfig(userPrompt: 'other').generationSignature,
          isNot(base.generationSignature));
      expect(const AiProviderConfig(systemPrompt: 'be terse').generationSignature,
          isNot(base.generationSignature));
    });

    test('changes when the temperature changes', () {
      expect(const AiProviderConfig(temperature: 1.5).generationSignature,
          isNot(base.generationSignature));
    });

    test('uses the clamped temperature, so out-of-range values collapse', () {
      // 3.0 and 99.0 both clamp to 2.0 and genuinely produce the same request,
      // so they must share a cache entry rather than thrash it.
      expect(const AiProviderConfig(temperature: 3).generationSignature,
          const AiProviderConfig(temperature: 99).generationSignature);
    });

    test('ignores settings that belong to another provider', () {
      // A Gemini thinking level cannot change an OpenAI answer; including it
      // would evict the cache on an irrelevant edit.
      expect(
        const AiProviderConfig(
          geminiThinkingLevel: AiGeminiThinkingLevel.high,
          deepseekModel: 'ds',
          customEndpoint: 'https://example.com',
        ).generationSignature,
        base.generationSignature,
      );
    });

    test('tracks every custom-provider knob that changes the request', () {
      const AiProviderConfig custom = AiProviderConfig(
        provider: AiProvider.custom,
        customEndpoint: 'https://openrouter.ai/api/v1/chat/completions',
        customModel: 'some/model',
      );
      final String baseline = custom.generationSignature;
      final List<AiProviderConfig> variants = <AiProviderConfig>[
        const AiProviderConfig(
            provider: AiProvider.custom,
            customEndpoint: 'https://openrouter.ai/api/v1/chat/completions',
            customModel: 'some/model',
            customRoutingMode: AiProviderRoutingMode.only),
        const AiProviderConfig(
            provider: AiProvider.custom,
            customEndpoint: 'https://openrouter.ai/api/v1/chat/completions',
            customModel: 'some/model',
            customRoutingSlugs: 'fireworks'),
        const AiProviderConfig(
            provider: AiProvider.custom,
            customEndpoint: 'https://openrouter.ai/api/v1/chat/completions',
            customModel: 'some/model',
            customAllowFallbacks: false),
        const AiProviderConfig(
            provider: AiProvider.custom,
            customEndpoint: 'https://openrouter.ai/api/v1/chat/completions',
            customModel: 'some/model',
            customThinkingMode: AiThinkingMode.enabled),
        const AiProviderConfig(
            provider: AiProvider.custom,
            customEndpoint: 'https://openrouter.ai/api/v1/chat/completions',
            customModel: 'some/model',
            customThinkingIntensity: AiThinkingIntensity.max),
        const AiProviderConfig(
            provider: AiProvider.custom,
            customEndpoint: 'https://openrouter.ai/api/v1/chat/completions',
            customModel: 'some/model',
            customThinkingValue: '2000'),
        const AiProviderConfig(
            provider: AiProvider.custom,
            customEndpoint: 'https://openrouter.ai/api/v1/chat/completions',
            customModel: 'some/model',
            customRequestBodyJson: '{"top_p":0.5}'),
      ];
      for (final AiProviderConfig variant in variants) {
        expect(variant.generationSignature, isNot(baseline),
            reason: 'a knob that changes the outgoing request must change the '
                'cache key, otherwise the old answer is served');
      }
    });

    test('prompt content cannot forge a field boundary', () {
      // JSON-encoded rather than delimiter-joined, so a prompt containing the
      // separator cannot collide with a different configuration.
      expect(
        const AiProviderConfig(userPrompt: 'a", "b').generationSignature,
        isNot(const AiProviderConfig(userPrompt: 'a', systemPrompt: 'b')
            .generationSignature),
      );
    });
  });
}
