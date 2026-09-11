import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_credential_store.dart';
import 'package:fushi/src/ai/ai_pref_keys.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_settings_store.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

/// The `preferences` table is untyped and outlives the code that wrote it: an
/// older build, a restored backup or a hand-edited row can leave an int where a
/// double is expected, or a string where a bool is. A lookup must never throw
/// because of that, so every read here is defensive and every defensive path is
/// pinned below.
///
/// The credential tests also pin the key-per-provider mapping, because getting
/// it wrong would send one provider's key to another — a live credential leak to
/// a third party rather than a mere bug.
///
/// See `docs/agent/ai-explanation.md` §5.1 and §9.
void main() {
  late _FakePrefs prefs;
  late AiSettingsStore settings;
  late PrefsAiCredentialStore credentials;

  setUp(() {
    prefs = _FakePrefs();
    settings = AiSettingsStore(prefs);
    credentials = PrefsAiCredentialStore(prefs);
  });

  group('defaults', () {
    test('an empty preference table yields the reference defaults', () {
      final AiProviderConfig config = settings.read();
      expect(config.provider, AiProvider.openai);
      expect(config.openaiModel, 'gpt-4o-mini');
      expect(config.geminiModel, 'gemini-2.5-flash');
      expect(config.temperature, 0.7);
      expect(config.autoGenerateOnLookup, isTrue);
      expect(config.streamResponse, isFalse);
      expect(config.cancelPendingRequests, isTrue);
      expect(config.unknownWordFallback, isFalse);
      expect(config.customAllowFallbacks, isTrue);
      expect(config.userPrompt, AiDefaults.userPrompt);
      expect(config.systemPrompt, isEmpty);
    });
  });

  group('round-trip', () {
    test('every behaviour setter is read back', () async {
      await settings.setProvider(AiProvider.deepseek);
      await settings.setAutoGenerate(false);
      await settings.setStreamResponse(true);
      await settings.setCancelPending(false);
      await settings.setUnknownWordFallback(true);
      await settings.setUserPrompt('my {{target}}');
      await settings.setSystemPrompt('be terse');
      await settings.setTemperature(1.25);

      final AiProviderConfig config = settings.read();
      expect(config.provider, AiProvider.deepseek);
      expect(config.autoGenerateOnLookup, isFalse);
      expect(config.streamResponse, isTrue);
      expect(config.cancelPendingRequests, isFalse);
      expect(config.unknownWordFallback, isTrue);
      expect(config.userPrompt, 'my {{target}}');
      expect(config.systemPrompt, 'be terse');
      expect(config.temperature, 1.25);
    });

    test('every provider-specific setter is read back', () async {
      await settings.setOpenaiModel('gpt-4o');
      await settings.setGeminiModel('gemini-3-pro-preview');
      await settings.setGeminiThinkingLevel(AiGeminiThinkingLevel.high);
      await settings.setDeepseekModel('deepseek-chat');
      await settings.setDeepseekThinkingMode(AiThinkingMode.enabled);
      await settings.setDeepseekThinkingIntensity(AiThinkingIntensity.max);
      await settings.setCustomEndpoint('https://openrouter.ai/api/v1/x');
      await settings.setCustomModel('vendor/model');
      await settings.setCustomRoutingMode(AiProviderRoutingMode.only);
      await settings.setCustomRoutingSlugs('a, b');
      await settings.setCustomAllowFallbacks(false);
      await settings.setCustomThinkingMode(AiThinkingMode.disabled);
      await settings.setCustomThinkingIntensity(AiThinkingIntensity.custom);
      await settings.setCustomThinkingValue('2000');
      await settings.setCustomRequestBodyJson('{"top_p":0.5}');

      final AiProviderConfig config = settings.read();
      expect(config.openaiModel, 'gpt-4o');
      expect(config.geminiModel, 'gemini-3-pro-preview');
      expect(config.geminiThinkingLevel, AiGeminiThinkingLevel.high);
      expect(config.deepseekModel, 'deepseek-chat');
      expect(config.deepseekThinkingMode, AiThinkingMode.enabled);
      expect(config.deepseekThinkingIntensity, AiThinkingIntensity.max);
      expect(config.customEndpoint, 'https://openrouter.ai/api/v1/x');
      expect(config.customModel, 'vendor/model');
      expect(config.customRoutingMode, AiProviderRoutingMode.only);
      expect(config.customRoutingSlugs, 'a, b');
      expect(config.customAllowFallbacks, isFalse);
      expect(config.customThinkingMode, AiThinkingMode.disabled);
      expect(config.customThinkingIntensity, AiThinkingIntensity.custom);
      expect(config.customThinkingValue, '2000');
      expect(config.customRequestBodyJson, '{"top_p":0.5}');
    });

    test('models and endpoints are trimmed on write', () async {
      await settings.setCustomEndpoint('  https://x.test/v1  ');
      await settings.setDeepseekModel('  m  ');
      expect(settings.read().customEndpoint, 'https://x.test/v1');
      expect(settings.read().deepseekModel, 'm');
    });

    test('prompts keep their whitespace and newlines', () async {
      // A prompt is content, not an identifier: trimming it would silently
      // change what the user asked the model to do.
      await settings.setUserPrompt('line one\n  indented\n');
      expect(settings.read().userPrompt, 'line one\n  indented\n');
    });
  });

  group('temperature is read defensively', () {
    test('clamps on write', () async {
      await settings.setTemperature(99);
      expect(settings.read().temperature, 2.0);
      await settings.setTemperature(-5);
      expect(settings.read().temperature, 0.0);
    });

    test('accepts an int left by an older build', () {
      prefs.values[AiPrefKeys.temperature] = 1;
      expect(settings.read().temperature, 1.0);
    });

    test('accepts a string, including a comma decimal separator', () {
      prefs.values[AiPrefKeys.temperature] = '0,4';
      expect(settings.read().temperature, closeTo(0.4, 1e-9),
          reason: 'many locales type a comma');
      prefs.values[AiPrefKeys.temperature] = ' 1.5 ';
      expect(settings.read().temperature, 1.5);
    });

    test('falls back to the default for junk', () {
      prefs.values[AiPrefKeys.temperature] = 'hot';
      expect(settings.read().temperature, 0.7);
      prefs.values[AiPrefKeys.temperature] = <String>['nope'];
      expect(settings.read().temperature, 0.7);
    });
  });

  group('other reads are defensive too', () {
    test('a wrong-typed bool falls back rather than throwing', () {
      prefs.values[AiPrefKeys.autoGenerate] = 'yes';
      expect(settings.read().autoGenerateOnLookup, isTrue);
    });

    test('a wrong-typed string falls back', () {
      prefs.values[AiPrefKeys.prompt] = 42;
      expect(settings.read().userPrompt, AiDefaults.userPrompt);
    });

    test('an unknown enum wire value falls back to unset', () {
      prefs.values[AiPrefKeys.customThinkingMode] = 'sideways';
      expect(settings.read().customThinkingMode, AiThinkingMode.unset);
    });
  });

  group('credentials', () {
    test('each provider maps to its own key', () {
      // Getting this wrong would send one provider's key to another — a live
      // credential handed to a third party.
      expect(PrefsAiCredentialStore.keyFor(AiProvider.openai),
          AiPrefKeys.openaiApiKey);
      expect(PrefsAiCredentialStore.keyFor(AiProvider.gemini),
          AiPrefKeys.geminiApiKey);
      expect(PrefsAiCredentialStore.keyFor(AiProvider.deepseek),
          AiPrefKeys.deepseekApiKey);
      expect(PrefsAiCredentialStore.keyFor(AiProvider.custom),
          AiPrefKeys.customApiKey);
      expect(
        AiProvider.values
            .map(PrefsAiCredentialStore.keyFor)
            .toSet()
            .length,
        AiProvider.values.length,
        reason: 'no two providers may share a credential key',
      );
    });

    test('round-trips and trims', () async {
      await credentials.writeApiKey(AiProvider.openai, '  sk-test\n');
      expect(credentials.readApiKey(AiProvider.openai), 'sk-test');
      expect(credentials.hasApiKey(AiProvider.openai), isTrue);
    });

    test('an unset or blank key is not usable', () async {
      expect(credentials.hasApiKey(AiProvider.gemini), isFalse);
      await credentials.writeApiKey(AiProvider.gemini, '   ');
      expect(credentials.hasApiKey(AiProvider.gemini), isFalse);
    });

    test('clearing forgets the key', () async {
      await credentials.writeApiKey(AiProvider.custom, 'k');
      await credentials.clearApiKey(AiProvider.custom);
      expect(credentials.readApiKey(AiProvider.custom), isEmpty);
      expect(credentials.hasApiKey(AiProvider.custom), isFalse);
    });

    test('writing one provider does not touch another', () async {
      await credentials.writeApiKey(AiProvider.openai, 'a');
      await credentials.writeApiKey(AiProvider.deepseek, 'b');
      expect(credentials.readApiKey(AiProvider.openai), 'a');
      expect(credentials.readApiKey(AiProvider.deepseek), 'b');
      expect(credentials.readApiKey(AiProvider.gemini), isEmpty);
    });

    test('every credential key is declared in AiPrefKeys.credentials', () {
      for (final AiProvider provider in AiProvider.values) {
        expect(AiPrefKeys.credentials,
            contains(PrefsAiCredentialStore.keyFor(provider)));
      }
    });
  });

  group('isEnabled', () {
    test('is false until a key is present', () async {
      expect(settings.isEnabled(credentials), isFalse);
      await credentials.writeApiKey(AiProvider.openai, 'k');
      expect(settings.isEnabled(credentials), isTrue,
          reason: 'OpenAI ships a usable default model');
    });

    test('needs a model for DeepSeek and an endpoint for Custom', () async {
      await settings.setProvider(AiProvider.deepseek);
      await credentials.writeApiKey(AiProvider.deepseek, 'k');
      expect(settings.isEnabled(credentials), isFalse);
      await settings.setDeepseekModel('deepseek-chat');
      expect(settings.isEnabled(credentials), isTrue);

      await settings.setProvider(AiProvider.custom);
      await credentials.writeApiKey(AiProvider.custom, 'k');
      await settings.setCustomModel('m');
      expect(settings.isEnabled(credentials), isFalse,
          reason: 'no endpoint yet');
      await settings.setCustomEndpoint('https://x.test/v1/chat/completions');
      expect(settings.isEnabled(credentials), isTrue);
    });

    test('checks the key of the selected provider, not any key', () async {
      // Configuring OpenAI then switching to Gemini must not look enabled.
      await credentials.writeApiKey(AiProvider.openai, 'k');
      await settings.setProvider(AiProvider.gemini);
      expect(settings.isEnabled(credentials), isFalse);
    });
  });
}

/// A map-backed [PrefStore], matching the untyped shape of the real table.
class _FakePrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async {
    values[key] = value;
  }
}
