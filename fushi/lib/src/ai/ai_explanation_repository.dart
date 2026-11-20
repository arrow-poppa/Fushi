/// Orchestration for AI explanations: cache, dedup, timeout, cancellation and
/// the single non-streaming retry.
///
/// Ported from the reference extension's `AIExplanationGenerator`
/// (`js/display/ai-explanation-generator.js`, GPL-3.0, Copyright (C) 2023-2025
/// Yomitan Authors). See `docs/agent/ai-explanation.md` §5.6.1 and §5.7.
///
/// This is where BYOK policy lives, and the reason it is separate from the
/// transport: every rule here exists so the user is not charged for something
/// they will never see. A re-render must not restart a request; a superseded
/// answer must not repaint a different word; a partial answer must not be
/// cached; and there is exactly one automatic retry in the whole feature.
library;

import 'dart:async';

import 'package:fushi/src/ai/ai_explanation_cache.dart';
import 'package:fushi/src/ai/ai_explanation_client.dart';
import 'package:fushi/src/ai/ai_explanation_result.dart';
import 'package:fushi/src/ai/ai_prompt_renderer.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_request_builder.dart';

/// Inactivity timeout for one request.
///
/// Re-armed on every streamed chunk, so a long answer is never cut off — only a
/// genuinely stalled connection is. It aborts rather than races, so a stalled
/// call drops its connection instead of leaving the model generating tokens
/// nobody will read. Always active, independent of the cancel-on-close setting.
const Duration kAiInactivityTimeout = Duration(seconds: 30);

/// Owns every in-flight explanation.
class AiExplanationRepository {
  AiExplanationRepository({
    required AiExplanationClient client,
    AiExplanationCache? cache,
    this.inactivityTimeout = kAiInactivityTimeout,
  }) : _client = client,
       _cache = cache ?? AiExplanationCache();

  final AiExplanationClient _client;
  final AiExplanationCache _cache;
  final Duration inactivityTimeout;

  final Map<String, _Pending> _pending = <String, _Pending>{};

  /// Whether any request is still running.
  bool get hasPending => _pending.isNotEmpty;

  /// Keys of the requests currently in flight. Test-facing.
  Iterable<String> get pendingKeys => _pending.keys;

  /// The cached answer for [cacheKey], if one is still fresh.
  ///
  /// Lets the caller render a finished explanation immediately on re-open
  /// without touching the network.
  String? cached(String cacheKey) => _cache.read(cacheKey);

  /// Starts, joins, or answers from cache.
  ///
  /// The returned stream replays the current state first, so a popup that
  /// re-rendered mid-answer sees the text so far rather than a blank box.
  ///
  /// When a request for the same key is already running this **joins** it
  /// rather than restarting — a popup that redraws while the mouse moves would
  /// otherwise never finish one. [force] is the regenerate path: it drops the
  /// cache entry, abandons the running request and starts fresh.
  Stream<AiExplanationResult> explain({
    required String cacheKey,
    required AiProviderConfig config,
    required AiRenderedPrompts prompts,
    required String apiKey,
    bool force = false,
  }) {
    if (force) {
      _cache.invalidate(cacheKey);
      _abort(cacheKey);
    } else {
      final _Pending? existing = _pending[cacheKey];
      if (existing != null) return existing.subscribe();

      final String? hit = _cache.read(cacheKey);
      if (hit != null) {
        return Stream<AiExplanationResult>.value(AiExplanationResult.done(hit));
      }
    }

    final _Pending pending = _Pending(cacheKey);
    _pending[cacheKey] = pending;
    final Stream<AiExplanationResult> stream = pending.subscribe();
    // Not awaited: the caller consumes the stream.
    unawaited(
      _run(pending: pending, config: config, prompts: prompts, apiKey: apiKey),
    );
    return stream;
  }

  /// Abandons every in-flight request.
  ///
  /// The popup-dismissed / surface-hidden path, used only when the user leaves
  /// "cancel unfinished requests" on. A cancelled request reports
  /// [AiExplanationStatus.cancelled], which renders nothing new: abandoning a
  /// request is normal operation, not an error.
  void cancelAll() {
    for (final String key in _pending.keys.toList()) {
      _abort(key);
    }
  }

  /// Abandons the request for [cacheKey], if one is running.
  ///
  /// The explicit-cancel path: the user pressed the button for *this* word, so
  /// only this word's request stops. Other surfaces keep theirs.
  void cancel(String cacheKey) => _abort(cacheKey);

  /// Abandons every in-flight request except [cacheKey].
  ///
  /// The new-lookup path: the word now on screen keeps generating, the rest
  /// stop.
  void cancelExcept(String cacheKey) {
    for (final String key in _pending.keys.toList()) {
      if (key != cacheKey) _abort(key);
    }
  }

  /// Releases everything. Call from the owner's dispose.
  void dispose() {
    cancelAll();
    _cache.clear();
  }

  void _abort(String key) {
    final _Pending? pending = _pending.remove(key);
    if (pending == null) return;
    pending.cancelled = true;
    // Completing the abort signal closes the HTTP client, which is what
    // actually stops the provider generating.
    pending.triggerAbort();
    pending.finish(const AiExplanationResult.cancelled());
    pending.close();
  }

  /// Whether [pending] is still the live request for its key.
  ///
  /// The reference's identity check: a forced restart replaces the map entry,
  /// and the old run must then write nothing.
  bool _isCurrent(_Pending pending) => _pending[pending.key] == pending;

  Future<void> _run({
    required _Pending pending,
    required AiProviderConfig config,
    required AiRenderedPrompts prompts,
    required String apiKey,
  }) async {
    // No loading emit here: _Pending starts in the loading state and
    // subscribe() replays it, so emitting again would deliver it twice.
    pending.armTimeout(inactivityTimeout);

    try {
      if (config.streamResponse) {
        await _runStreaming(
          pending: pending,
          config: config,
          prompts: prompts,
          apiKey: apiKey,
        );
      } else {
        final String text = await _client.generate(
          config: config,
          prompts: prompts,
          apiKey: apiKey,
          abortSignal: pending.abortSignal,
        );
        pending.buffer
          ..clear()
          ..write(text);
      }

      pending.clearTimeout();

      if (pending.timedOut) {
        pending.finish(const AiExplanationResult.timedOut());
        return;
      }
      // A cancellation landing between the last chunk and here must not
      // resurrect the answer over whatever the popup shows now.
      if (pending.cancelled || !_isCurrent(pending)) return;

      final String text = pending.buffer.toString().trim();
      // Partial cancelled answers and empty answers are deliberately not
      // cached, so a later lookup starts clean.
      _cache.write(pending.key, text);
      pending.finish(AiExplanationResult.done(text));
    } on Object catch (error) {
      // Flags first: an abort closes the HTTP client, which surfaces as a
      // transport error, and that must be read as "timed out" or "cancelled"
      // rather than reported as a failure.
      if (pending.timedOut) {
        pending.finish(const AiExplanationResult.timedOut());
      } else if (pending.cancelled || !_isCurrent(pending)) {
        // Normal operation: the popup closed or another word was looked up.
      } else if (error is AiProviderException) {
        pending.finish(
          AiExplanationResult.failed(
            AiExplanationFailure.provider,
            providerMessage: error.providerMessage,
          ),
        );
      } else if (error is AiRequestException) {
        pending.finish(
          AiExplanationResult.failed(
            AiExplanationFailure.configuration,
            providerMessage: error.message,
          ),
        );
      } else {
        // Network down, DNS, TLS: nothing here is safe to surface verbatim.
        pending.finish(
          const AiExplanationResult.failed(AiExplanationFailure.unknown),
        );
      }
    } finally {
      pending.clearTimeout();
      // Only drop the entry if it is still ours; a forced restart already
      // replaced it.
      if (_isCurrent(pending)) _pending.remove(pending.key);
      pending.close();
    }
  }

  /// Runs the streaming attempt, with the single non-streaming retry.
  Future<void> _runStreaming({
    required _Pending pending,
    required AiProviderConfig config,
    required AiRenderedPrompts prompts,
    required String apiKey,
  }) async {
    int receivedLength = 0;
    try {
      final Stream<String> deltas = _client.generateStream(
        config: config,
        prompts: prompts,
        apiKey: apiKey,
        abortSignal: pending.abortSignal,
      );
      await for (final String delta in deltas) {
        // A chunk belonging to a request already replaced or cancelled must not
        // reach the display — and must not count as "text received", which is
        // what keeps the retry guard below honest.
        if (pending.cancelled || pending.timedOut || !_isCurrent(pending)) {
          return;
        }
        receivedLength += delta.length;
        pending.buffer.write(delta);
        // Every chunk restarts the timeout: a long answer is not a stalled one.
        pending.armTimeout(inactivityTimeout);
        pending.emit(AiExplanationResult.streaming(pending.buffer.toString()));
      }
    } on Object {
      // The four guards, exactly as upstream (§5.6.1). Any one of them true
      // means rethrow: never silently re-issue a request the user is already
      // being billed for, and never restart one they abandoned.
      if (receivedLength > 0 ||
          pending.cancelled ||
          pending.timedOut ||
          !_isCurrent(pending)) {
        rethrow;
      }

      // An endpoint which cannot stream should still answer. Exactly one retry,
      // and it gets a full fresh timeout window rather than the remains of the
      // streaming attempt's.
      pending.armTimeout(inactivityTimeout);
      final String text = await _client.generate(
        config: config,
        prompts: prompts,
        apiKey: apiKey,
        abortSignal: pending.abortSignal,
      );
      pending.buffer
        ..clear()
        ..write(text);
    }
  }
}

/// One in-flight explanation.
class _Pending {
  _Pending(this.key);

  final String key;

  final StringBuffer buffer = StringBuffer();

  /// One controller per subscriber rather than a broadcast controller.
  ///
  /// A broadcast stream has a gap between "replay the current state" and
  /// "subscribe to later events" in which an emission is lost — and the lost one
  /// could be the terminal state, leaving the popup spinning forever. Fanning
  /// out explicitly removes the gap.
  final List<StreamController<AiExplanationResult>> _subscribers =
      <StreamController<AiExplanationResult>>[];

  final Completer<void> _abort = Completer<void>();

  AiExplanationResult _last = const AiExplanationResult.loading();

  Timer? _timer;

  bool cancelled = false;
  bool timedOut = false;
  bool isFinished = false;

  /// Completes when the request is abandoned; the client closes its connection.
  Future<void> get abortSignal => _abort.future;

  void triggerAbort() {
    if (!_abort.isCompleted) _abort.complete();
  }

  /// A stream that starts with the current state and then follows.
  Stream<AiExplanationResult> subscribe() {
    final StreamController<AiExplanationResult> controller =
        StreamController<AiExplanationResult>();
    controller.add(_last);
    if (isFinished) {
      controller.close();
    } else {
      _subscribers.add(controller);
      controller.onCancel = () => _subscribers.remove(controller);
    }
    return controller.stream;
  }

  void emit(AiExplanationResult result) {
    _last = result;
    for (final StreamController<AiExplanationResult> c
        in _subscribers.toList()) {
      if (!c.isClosed) c.add(result);
    }
  }

  void finish(AiExplanationResult result) {
    if (isFinished) return;
    isFinished = true;
    emit(result);
  }

  void armTimeout(Duration timeout) {
    _timer?.cancel();
    _timer = Timer(timeout, () {
      _timer = null;
      timedOut = true;
      triggerAbort();
    });
  }

  void clearTimeout() {
    _timer?.cancel();
    _timer = null;
  }

  void close() {
    clearTimeout();
    triggerAbort();
    for (final StreamController<AiExplanationResult> c
        in _subscribers.toList()) {
      if (!c.isClosed) c.close();
    }
    _subscribers.clear();
  }
}
