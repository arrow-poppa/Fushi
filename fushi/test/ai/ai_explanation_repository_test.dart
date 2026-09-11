import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_explanation_cache.dart';
import 'package:fushi/src/ai/ai_explanation_client.dart';
import 'package:fushi/src/ai/ai_explanation_repository.dart';
import 'package:fushi/src/ai/ai_explanation_result.dart';
import 'package:fushi/src/ai/ai_prompt_renderer.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_request_builder.dart';

/// Every rule in [AiExplanationRepository] exists so a BYOK user is not billed
/// for something they will never see, so these are cost-correctness tests as
/// much as behaviour tests.
///
/// The most consequential group is the non-streaming retry: it is the **only**
/// automatic retry in the whole feature, it must fire exactly once, and it must
/// not fire at all once text has arrived, once the request is cancelled, or once
/// it has timed out. See `docs/agent/ai-explanation.md` §5.6.1 and §5.7.
void main() {
  /// Records every call so a test can assert the provider was not hit twice.
  _FakeClient fake() => _FakeClient();

  AiRenderedPrompts prompts() => AiPromptRenderer.render(
        userTemplate: 'explain {{target}}',
        systemTemplate: '',
        target: 'word',
        sentence: 'ctx',
      );

  AiProviderConfig config({bool stream = false}) =>
      AiProviderConfig(streamResponse: stream);

  AiExplanationRepository repo(
    _FakeClient client, {
    Duration timeout = const Duration(seconds: 30),
    AiExplanationCache? cache,
  }) =>
      AiExplanationRepository(
          client: client, cache: cache, inactivityTimeout: timeout);

  Future<List<AiExplanationResult>> collect(
    AiExplanationRepository repository, {
    bool stream = false,
    String key = 'k',
    bool force = false,
  }) =>
      repository
          .explain(
            cacheKey: key,
            config: config(stream: stream),
            prompts: prompts(),
            apiKey: 'api',
            force: force,
          )
          .toList();

  group('cache', () {
    test('a fresh hit answers without touching the provider', () async {
      final _FakeClient client = fake()..answer = 'first';
      final AiExplanationRepository repository = repo(client);

      await collect(repository);
      expect(client.generateCalls, 1);

      final List<AiExplanationResult> second = await collect(repository);
      expect(client.generateCalls, 1, reason: 'the cache must absorb this one');
      expect(second.last.status, AiExplanationStatus.done);
      expect(second.last.text, 'first');
    });

    test('a stale entry is refetched', () async {
      DateTime now = DateTime(2026);
      final AiExplanationCache cache =
          AiExplanationCache(now: () => now, ttl: const Duration(minutes: 1));
      final _FakeClient client = fake()..answer = 'a';
      final AiExplanationRepository repository = repo(client, cache: cache);

      await collect(repository);
      now = now.add(const Duration(seconds: 61));
      client.answer = 'b';
      final List<AiExplanationResult> again = await collect(repository);

      expect(client.generateCalls, 2);
      expect(again.last.text, 'b');
    });

    test('failures are never cached', () async {
      final _FakeClient client = fake()
        ..error = const AiProviderException(
            providerLabel: 'Custom', providerMessage: 'boom');
      final AiExplanationRepository repository = repo(client);

      final List<AiExplanationResult> first = await collect(repository);
      expect(first.last.status, AiExplanationStatus.failed);

      client
        ..error = null
        ..answer = 'recovered';
      final List<AiExplanationResult> second = await collect(repository);
      expect(second.last.text, 'recovered',
          reason: 'a cached error would make the failure sticky for a minute');
      expect(client.generateCalls, 2);
    });

    test('an empty answer is not cached', () async {
      final _FakeClient client = fake()..answer = '   ';
      final AiExplanationRepository repository = repo(client);

      await collect(repository);
      await collect(repository);
      expect(client.generateCalls, 2);
    });
  });

  group('dedup and regenerate', () {
    test('a second request for the same key joins the first', () async {
      final _FakeClient client = fake()
        ..answer = 'shared'
        ..delay = const Duration(milliseconds: 40);
      final AiExplanationRepository repository = repo(client);

      final Future<List<AiExplanationResult>> a = collect(repository);
      final Future<List<AiExplanationResult>> b = collect(repository);
      final List<List<AiExplanationResult>> both =
          await Future.wait<List<AiExplanationResult>>(
              <Future<List<AiExplanationResult>>>[a, b]);

      expect(client.generateCalls, 1,
          reason: 'a popup that re-renders must not pay twice');
      expect(both[0].last.text, 'shared');
      expect(both[1].last.text, 'shared',
          reason: 'the joiner sees the same answer');
    });

    test('force bypasses the cache and re-asks', () async {
      final _FakeClient client = fake()..answer = 'one';
      final AiExplanationRepository repository = repo(client);

      await collect(repository);
      client.answer = 'two';
      final List<AiExplanationResult> regenerated =
          await collect(repository, force: true);

      expect(client.generateCalls, 2);
      expect(regenerated.last.text, 'two');
    });

    test('different keys do not share an answer', () async {
      final _FakeClient client = fake()..answer = 'x';
      final AiExplanationRepository repository = repo(client);

      await collect(repository, key: 'a');
      await collect(repository, key: 'b');
      expect(client.generateCalls, 2);
    });
  });

  group('streaming', () {
    test('accumulates deltas and finishes with the whole answer', () async {
      final _FakeClient client = fake()
        ..deltas = <String>['Hel', 'lo', ' world'];
      final AiExplanationRepository repository = repo(client);

      final List<AiExplanationResult> results =
          await collect(repository, stream: true);

      expect(results.first.status, AiExplanationStatus.loading);
      expect(
        results
            .where((AiExplanationResult r) =>
                r.status == AiExplanationStatus.streaming)
            .map((AiExplanationResult r) => r.text),
        <String>['Hel', 'Hello', 'Hello world'],
        reason: 'each update carries the accumulated answer, not the delta',
      );
      expect(results.last.status, AiExplanationStatus.done);
      expect(results.last.text, 'Hello world');
    });

    test('the streamed answer is cached', () async {
      final _FakeClient client = fake()..deltas = <String>['a', 'b'];
      final AiExplanationRepository repository = repo(client);

      await collect(repository, stream: true);
      final List<AiExplanationResult> second =
          await collect(repository, stream: true);

      expect(client.streamCalls, 1);
      expect(second.last.text, 'ab');
    });
  });

  group('non-streaming retry (the only automatic retry)', () {
    test('falls back once when the stream fails before any text', () async {
      final _FakeClient client = fake()
        ..streamError = Exception('endpoint cannot stream')
        ..answer = 'via fallback';
      final AiExplanationRepository repository = repo(client);

      final List<AiExplanationResult> results =
          await collect(repository, stream: true);

      expect(client.streamCalls, 1);
      expect(client.generateCalls, 1, reason: 'exactly one retry');
      expect(results.last.status, AiExplanationStatus.done);
      expect(results.last.text, 'via fallback');
    });

    test('does NOT fall back once text has already arrived', () async {
      // The guard that protects the user's wallet: re-asking would bill a second
      // full generation for an answer they already partly saw.
      final _FakeClient client = fake()
        ..deltas = <String>['partial']
        ..streamError = Exception('died mid-stream')
        ..answer = 'must not be used';
      final AiExplanationRepository repository = repo(client);

      final List<AiExplanationResult> results =
          await collect(repository, stream: true);

      expect(client.generateCalls, 0,
          reason: 'text arrived, so the failure is surfaced, not retried');
      expect(results.last.status, AiExplanationStatus.failed);
    });

    test('retries at most once — a failing fallback is not retried again',
        () async {
      final _FakeClient client = fake()
        ..streamError = Exception('no stream')
        ..error = const AiProviderException(
            providerLabel: 'Custom', providerMessage: 'still broken');
      final AiExplanationRepository repository = repo(client);

      final List<AiExplanationResult> results =
          await collect(repository, stream: true);

      expect(client.generateCalls, 1, reason: 'no second retry');
      expect(results.last.status, AiExplanationStatus.failed);
      expect(results.last.providerMessage, 'still broken');
    });

    test('does not fall back after a cancel', () async {
      final _FakeClient client = fake()
        ..streamDelay = const Duration(milliseconds: 60)
        ..streamError = Exception('boom')
        ..answer = 'must not be used';
      final AiExplanationRepository repository = repo(client);

      final List<AiExplanationResult> seen = <AiExplanationResult>[];
      final StreamSubscription<AiExplanationResult> sub = repository
          .explain(
              cacheKey: 'k',
              config: config(stream: true),
              prompts: prompts(),
              apiKey: 'api')
          .listen(seen.add);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      repository.cancelAll();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await sub.cancel();

      expect(client.generateCalls, 0,
          reason: 'an abandoned request must not start another one');
      expect(seen.last.status, AiExplanationStatus.cancelled);
    });
  });

  group('cancellation', () {
    test('cancelAll reports cancelled and caches nothing', () async {
      final _FakeClient client = fake()
        ..deltas = <String>['half']
        ..streamDelay = const Duration(milliseconds: 80);
      final AiExplanationRepository repository = repo(client);

      final List<AiExplanationResult> seen = <AiExplanationResult>[];
      final StreamSubscription<AiExplanationResult> sub = repository
          .explain(
              cacheKey: 'k',
              config: config(stream: true),
              prompts: prompts(),
              apiKey: 'api')
          .listen(seen.add);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      repository.cancelAll();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await sub.cancel();

      expect(seen.last.status, AiExplanationStatus.cancelled);
      expect(repository.cached('k'), isNull,
          reason: 'a partial abandoned answer must not be cached');
      expect(repository.hasPending, isFalse);
    });

    test('cancelExcept spares the named key', () async {
      final _FakeClient client = fake()
        ..answer = 'x'
        ..delay = const Duration(milliseconds: 60);
      final AiExplanationRepository repository = repo(client);

      final StreamSubscription<AiExplanationResult> keep = repository
          .explain(
              cacheKey: 'keep',
              config: config(),
              prompts: prompts(),
              apiKey: 'api')
          .listen((_) {});
      final StreamSubscription<AiExplanationResult> drop = repository
          .explain(
              cacheKey: 'drop',
              config: config(),
              prompts: prompts(),
              apiKey: 'api')
          .listen((_) {});

      await Future<void>.delayed(const Duration(milliseconds: 10));
      repository.cancelExcept('keep');

      expect(repository.pendingKeys, <String>['keep']);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await keep.cancel();
      await drop.cancel();
    });
  });

  group('inactivity timeout', () {
    test('a stalled request times out', () async {
      final _FakeClient client = fake()
        ..answer = 'too late'
        ..delay = const Duration(milliseconds: 300);
      final AiExplanationRepository repository =
          repo(client, timeout: const Duration(milliseconds: 40));

      final List<AiExplanationResult> results = await collect(repository);

      expect(results.last.status, AiExplanationStatus.timedOut);
      expect(repository.cached('k'), isNull);
    });

    test('a chunk re-arms the timeout, so a long answer is not cut off',
        () async {
      // Four chunks 30 ms apart with a 50 ms timeout: the total 120 ms far
      // exceeds the timeout, but no single gap does.
      final _FakeClient client = fake()
        ..deltas = <String>['a', 'b', 'c', 'd']
        ..streamDelay = const Duration(milliseconds: 30);
      final AiExplanationRepository repository =
          repo(client, timeout: const Duration(milliseconds: 50));

      final List<AiExplanationResult> results =
          await collect(repository, stream: true);

      expect(results.last.status, AiExplanationStatus.done,
          reason: 'the timeout measures inactivity, not total duration');
      expect(results.last.text, 'abcd');
    });

    test('a timeout is distinct from a cancellation', () async {
      final _FakeClient client = fake()
        ..answer = 'x'
        ..delay = const Duration(milliseconds: 300);
      final AiExplanationRepository repository =
          repo(client, timeout: const Duration(milliseconds: 40));

      final List<AiExplanationResult> results = await collect(repository);
      expect(results.last.status, isNot(AiExplanationStatus.cancelled));
      expect(results.last.status, AiExplanationStatus.timedOut);
    });
  });

  group('error mapping', () {
    test('a provider error keeps its sanitised message', () async {
      final _FakeClient client = fake()
        ..error = const AiProviderException(
            providerLabel: 'OpenAI',
            statusCode: 401,
            providerMessage: 'Incorrect API key provided');
      final AiExplanationRepository repository = repo(client);

      final List<AiExplanationResult> results = await collect(repository);
      expect(results.last.failure, AiExplanationFailure.provider);
      expect(results.last.providerMessage, 'Incorrect API key provided');
    });

    test('a configuration error is reported as such', () async {
      final _FakeClient client = fake()
        ..error = const AiRequestException(
            'Invalid Custom Request Body JSON: expected a JSON object.');
      final AiExplanationRepository repository = repo(client);

      final List<AiExplanationResult> results = await collect(repository);
      expect(results.last.failure, AiExplanationFailure.configuration);
    });

    test('an unknown transport error carries no provider text', () async {
      // Nothing from a raw socket/TLS failure is safe to surface verbatim.
      final _FakeClient client = fake()..error = Exception('SocketException: ...');
      final AiExplanationRepository repository = repo(client);

      final List<AiExplanationResult> results = await collect(repository);
      expect(results.last.failure, AiExplanationFailure.unknown);
      expect(results.last.providerMessage, isNull);
    });
  });

  group('lifecycle', () {
    test('a late subscriber sees the state so far', () async {
      final _FakeClient client = fake()
        ..deltas = <String>['a', 'b']
        ..streamDelay = const Duration(milliseconds: 30);
      final AiExplanationRepository repository = repo(client);

      final Stream<AiExplanationResult> first = repository.explain(
          cacheKey: 'k',
          config: config(stream: true),
          prompts: prompts(),
          apiKey: 'api');
      final StreamSubscription<AiExplanationResult> sub = first.listen((_) {});

      await Future<void>.delayed(const Duration(milliseconds: 40));
      final List<AiExplanationResult> joined = await repository
          .explain(
              cacheKey: 'k',
              config: config(stream: true),
              prompts: prompts(),
              apiKey: 'api')
          .toList();

      expect(joined.first.text, isNotEmpty,
          reason: 'a popup that re-rendered must not see a blank box');
      expect(joined.last.status, AiExplanationStatus.done);
      await sub.cancel();
    });

    test('dispose clears pending work and the cache', () async {
      final _FakeClient client = fake()..answer = 'x';
      final AiExplanationRepository repository = repo(client);

      await collect(repository);
      expect(repository.cached('k'), 'x');
      repository.dispose();
      expect(repository.cached('k'), isNull);
      expect(repository.hasPending, isFalse);
    });
  });
}

/// A stand-in for the transport, so these tests exercise policy only.
class _FakeClient extends AiExplanationClient {
  _FakeClient() : super();

  String answer = '';
  List<String> deltas = <String>[];
  Exception? error;
  Exception? streamError;
  Duration delay = Duration.zero;
  Duration streamDelay = Duration.zero;

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
    unawaited(abortSignal?.whenComplete(() => aborted = true) ??
        Future<void>.value());
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (aborted) throw Exception('aborted');
    final Exception? failure = error;
    if (failure != null) throw failure;
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
    bool aborted = false;
    unawaited(abortSignal?.whenComplete(() => aborted = true) ??
        Future<void>.value());
    for (final String delta in deltas) {
      if (streamDelay > Duration.zero) await Future<void>.delayed(streamDelay);
      if (aborted) return;
      yield delta;
    }
    final Exception? failure = streamError;
    if (failure != null) {
      if (streamDelay > Duration.zero) await Future<void>.delayed(streamDelay);
      if (aborted) return;
      throw failure;
    }
  }
}
