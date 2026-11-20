import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_credential_store.dart';
import 'package:fushi/src/ai/ai_explanation_client.dart';
import 'package:fushi/src/ai/ai_explanation_controller.dart';
import 'package:fushi/src/ai/ai_explanation_repository.dart';
import 'package:fushi/src/ai/ai_explanation_cache.dart';
import 'package:fushi/src/ai/ai_explanation_result.dart';
import 'package:fushi/src/ai/ai_prompt_renderer.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_settings_store.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

/// The controller is the decision table between "a word appeared in the popup"
/// and "a request goes out", and every branch of it costs the user money or
/// costs them an answer.
///
/// The two that matter most: auto-generation off must send **nothing** (the box
/// appears with a generate action and no network happens), and a result
/// belonging to a word the user has already moved past must never paint — that
/// would put one word's explanation under another word, and mine it onto the
/// wrong card.
///
/// Driven through the real repository with a fake transport, so cache, dedup and
/// cancellation are exercised for real rather than mocked away.
///
/// See `docs/agent/ai-explanation.md` §6 and §10.
void main() {
  late _FakePrefs prefs;
  late AiSettingsStore settings;
  late PrefsAiCredentialStore credentials;
  late _FakeClient client;
  late AiExplanationRepository repository;
  late List<AiExplanationResult> seen;
  late AiExplanationController controller;

  /// Configures a usable OpenAI provider, which is the shortest path to "ready".
  Future<void> configure({
    bool autoGenerate = true,
    bool cancelPending = true,
    bool stream = false,
    String apiKey = 'k',
  }) async {
    if (apiKey.isNotEmpty) {
      await credentials.writeApiKey(AiProvider.openai, apiKey);
    }
    await settings.setAutoGenerate(autoGenerate);
    await settings.setCancelPending(cancelPending);
    await settings.setStreamResponse(stream);
  }

  void build() {
    seen = <AiExplanationResult>[];
    controller = AiExplanationController(
      repository: repository,
      settings: settings,
      credentials: credentials,
      onResult: seen.add,
    );
  }

  setUp(() {
    prefs = _FakePrefs();
    settings = AiSettingsStore(prefs);
    credentials = PrefsAiCredentialStore(prefs);
    client = _FakeClient()..answer = 'the answer';
    repository = AiExplanationRepository(client: client);
    build();
  });

  tearDown(() {
    controller.dispose();
    repository.dispose();
  });

  const AiLookupTarget word = AiLookupTarget(
    term: '猫',
    sentence: '猫が好きです。',
    profileId: 'p1',
  );

  /// Lets the repository's async work settle.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  group('not configured', () {
    test('reports notConfigured and sends nothing', () async {
      final AiExplanationResult first = controller.onLookup(word);
      await settle();
      expect(first.status, AiExplanationStatus.notConfigured);
      expect(client.generateCalls, 0, reason: 'no key means no request');
    });

    test('a key for another provider does not count', () async {
      await credentials.writeApiKey(AiProvider.gemini, 'g');
      controller.onLookup(word);
      await settle();
      expect(seen.last.status, AiExplanationStatus.notConfigured);
      expect(client.generateCalls, 0);
    });
  });

  group('auto generation', () {
    test('on: asks and finishes with the answer', () async {
      await configure();
      final AiExplanationResult first = controller.onLookup(word);
      expect(first.status, AiExplanationStatus.loading);
      await settle();
      expect(client.generateCalls, 1);
      expect(seen.last.status, AiExplanationStatus.done);
      expect(seen.last.text, 'the answer');
    });

    test('off: shows the manual state and sends nothing', () async {
      // The explicit requirement, and the reference is equally explicit: the box
      // appears, no request goes out, the user generates on demand.
      await configure(autoGenerate: false);
      final AiExplanationResult first = controller.onLookup(word);
      await settle();
      expect(first.status, AiExplanationStatus.manual);
      expect(client.generateCalls, 0);
    });

    test('off: regenerate is what actually generates', () async {
      await configure(autoGenerate: false);
      controller.onLookup(word);
      await settle();
      expect(client.generateCalls, 0);

      controller.regenerate();
      await settle();
      expect(client.generateCalls, 1);
      expect(seen.last.text, 'the answer');
    });

    test('an empty term is never asked about', () async {
      await configure();
      controller.onLookup(const AiLookupTarget(term: '   '));
      await settle();
      expect(client.generateCalls, 0);
    });

    test('an empty sentence still generates', () async {
      // Three surfaces genuinely have no context; they must not be dead.
      await configure();
      controller.onLookup(const AiLookupTarget(term: '猫'));
      await settle();
      expect(client.generateCalls, 1);
      expect(seen.last.status, AiExplanationStatus.done);
    });
  });

  group('cache', () {
    test('a second lookup of the same word costs nothing', () async {
      await configure();
      controller.onLookup(word);
      await settle();
      expect(client.generateCalls, 1);

      build();
      final AiExplanationResult again = controller.onLookup(word);
      expect(
        again.status,
        AiExplanationStatus.done,
        reason: 'a cached answer renders immediately, with no loading flash',
      );
      expect(client.generateCalls, 1);
    });

    test('changing the prompt invalidates it', () async {
      // The §8.3 divergence, end to end: upstream would serve the old answer.
      await configure();
      controller.onLookup(word);
      await settle();

      await settings.setUserPrompt('completely different {{target}}');
      build();
      controller.onLookup(word);
      await settle();
      expect(client.generateCalls, 2);
    });

    test('a different Profile does not share answers', () async {
      await configure();
      controller.onLookup(word);
      await settle();

      build();
      controller.onLookup(
        const AiLookupTarget(term: '猫', sentence: '猫が好きです。', profileId: 'p2'),
      );
      await settle();
      expect(client.generateCalls, 2);
    });

    test('regenerate bypasses the cache', () async {
      await configure();
      controller.onLookup(word);
      await settle();
      client.answer = 'a fresh answer';

      controller.regenerate();
      await settle();
      expect(client.generateCalls, 2);
      expect(seen.last.text, 'a fresh answer');
    });
  });

  group('superseded lookups never paint', () {
    test('a slow answer for the previous word is dropped', () async {
      // The failure this prevents: word A's explanation appearing under word B,
      // and being mined onto B's card.
      await configure(cancelPending: false);
      client.delay = const Duration(milliseconds: 60);

      controller.onLookup(word);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      controller.onLookup(
        const AiLookupTarget(term: '犬', sentence: '犬も好きです。', profileId: 'p1'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // Whatever the last state is, it belongs to the second word: nothing from
      // the first lookup may arrive after the switch.
      final int switchIndex = seen.lastIndexWhere(
        (AiExplanationResult r) => r.status == AiExplanationStatus.loading,
      );
      for (final AiExplanationResult r in seen.sublist(switchIndex)) {
        expect(r.status, isNot(AiExplanationStatus.streaming));
      }
      expect(seen.last.status, AiExplanationStatus.done);
    });

    test('with cancel-pending on, the previous request is abandoned', () async {
      await configure(cancelPending: true);
      client.delay = const Duration(milliseconds: 60);

      controller.onLookup(word);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(repository.hasPending, isTrue);

      controller.onLookup(const AiLookupTarget(term: '犬', profileId: 'p1'));
      // The previous key is gone; only the new one is in flight.
      expect(repository.pendingKeys.length, 1);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
  });

  group('explicit cancel', () {
    test('aborts and reports cancelled even with the setting off', () async {
      // The setting governs implicit abandonment. A button the user just
      // pressed is not implicit.
      await configure(cancelPending: false);
      client.delay = const Duration(milliseconds: 80);

      controller.onLookup(word);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final AiExplanationResult cancelled = controller.cancel();

      expect(cancelled.status, AiExplanationStatus.cancelled);
      expect(repository.hasPending, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        seen.last.status,
        AiExplanationStatus.cancelled,
        reason: 'nothing may arrive after the user cancelled',
      );
    });

    test('a cancelled answer is not cached', () async {
      await configure(cancelPending: false);
      client.delay = const Duration(milliseconds: 80);
      controller.onLookup(word);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      controller.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      client.delay = Duration.zero;
      build();
      controller.onLookup(word);
      await settle();
      expect(
        client.generateCalls,
        2,
        reason: 'must ask again, not serve a stub',
      );
    });
  });

  group('dismissal', () {
    test('cancels pending work when the setting is on', () async {
      await configure(cancelPending: true);
      client.delay = const Duration(milliseconds: 80);
      controller.onLookup(word);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      controller.onDismissed();
      expect(repository.hasPending, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });

    test('leaves it running when the setting is off', () async {
      // Deliberate: the answer finishes into the cache so re-opening the word is
      // instant. It simply can never paint another word.
      await configure(cancelPending: false);
      client.delay = const Duration(milliseconds: 60);
      controller.onLookup(word);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      controller.onDismissed();
      expect(repository.hasPending, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(repository.cached(_keyOf(word, settings.read())), 'the answer');
    });
  });

  group('streaming', () {
    test('forwards accumulated text then done', () async {
      await configure(stream: true);
      client.deltas = <String>['Hel', 'lo'];
      controller.onLookup(word);
      await settle();

      final List<String> streamed = seen
          .where(
            (AiExplanationResult r) =>
                r.status == AiExplanationStatus.streaming,
          )
          .map((AiExplanationResult r) => r.text)
          .toList();
      expect(streamed, <String>['Hel', 'Hello']);
      expect(seen.last.status, AiExplanationStatus.done);
      expect(seen.last.text, 'Hello');
    });
  });
}

String _keyOf(AiLookupTarget t, AiProviderConfig config) =>
    buildAiExplanationCacheKeyForTest(t, config);

/// Mirrors the controller's key construction so a test can read the cache.
String buildAiExplanationCacheKeyForTest(
  AiLookupTarget t,
  AiProviderConfig config,
) {
  return buildAiExplanationCacheKey(
    profileId: t.profileId,
    target: t.term,
    sentence: t.sentence,
    config: config,
  );
}

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

class _FakeClient extends AiExplanationClient {
  _FakeClient() : super();

  String answer = '';
  List<String> deltas = <String>[];
  Duration delay = Duration.zero;
  int generateCalls = 0;
  int streamCalls = 0;

  @override
  Future<String> generate({
    required AiProviderConfig config,
    required AiRenderedPrompts prompts,
    required String apiKey,
    Future<void>? abortSignal,
  }) async {
    generateCalls++;
    bool aborted = false;
    unawaited(
      abortSignal?.whenComplete(() => aborted = true) ?? Future<void>.value(),
    );
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (aborted) throw Exception('aborted');
    return answer;
  }

  @override
  Stream<String> generateStream({
    required AiProviderConfig config,
    required AiRenderedPrompts prompts,
    required String apiKey,
    Future<void>? abortSignal,
  }) async* {
    streamCalls++;
    generateCalls++;
    bool aborted = false;
    unawaited(
      abortSignal?.whenComplete(() => aborted = true) ?? Future<void>.value(),
    );
    for (final String delta in deltas) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (aborted) return;
      yield delta;
    }
  }
}
