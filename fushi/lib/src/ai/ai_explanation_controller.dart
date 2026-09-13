/// Drives one popup's AI explanation: decides whether to ask, forwards state,
/// and ties the request to the lookup's lifecycle.
///
/// Mirrors the reference extension's display-side orchestration
/// (`js/display/display.js:239-313`, `:1584-1606`, GPL-3.0, Copyright (C)
/// 2023-2025 Yomitan Authors). See `docs/agent/ai-explanation.md` §6 and §10.
///
/// Flutter-free on purpose: it takes a callback instead of owning a widget, so
/// the whole decision table — configured or not, auto or manual, cached or
/// fresh, superseded or current — is unit-testable without pumping a frame.
library;

import 'dart:async';

import 'package:fushi/src/ai/ai_credential_store.dart';
import 'package:fushi/src/ai/ai_explanation_cache.dart';
import 'package:fushi/src/ai/ai_explanation_repository.dart';
import 'package:fushi/src/ai/ai_explanation_result.dart';
import 'package:fushi/src/ai/ai_prompt_renderer.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_settings_store.dart';

/// One lookup's identity, as far as the AI layer is concerned.
class AiLookupTarget {
  const AiLookupTarget({
    required this.term,
    this.sentence = '',
    this.profileId = '',
  });

  /// The headword being explained.
  final String term;

  /// Surrounding context, or empty. Several surfaces genuinely have none (the
  /// home Dictionary tab, the floating dictionary window, nested popups), and
  /// an empty sentence must stay valid rather than block the request.
  final String sentence;

  /// Scopes the cache so two Profiles with different prompts never share an
  /// answer.
  final String profileId;

  bool get isUsable => term.trim().isNotEmpty;
}

/// Owns the AI explanation for a single popup surface.
class AiExplanationController {
  AiExplanationController({
    required AiExplanationRepository repository,
    required AiSettingsStore settings,
    required AiCredentialStore credentials,
    required void Function(AiExplanationResult result) onResult,
  }) : _repository = repository,
       _settings = settings,
       _credentials = credentials,
       _onResult = onResult;

  final AiExplanationRepository _repository;
  final AiSettingsStore _settings;
  final AiCredentialStore _credentials;
  final void Function(AiExplanationResult result) _onResult;

  StreamSubscription<AiExplanationResult>? _subscription;
  AiLookupTarget? _target;
  String? _cacheKey;

  /// Bumped on every lookup, regenerate and cancel.
  ///
  /// The repository already refuses to let a superseded request write, but the
  /// controller needs its own token too: a result can already be travelling
  /// through the stream when the user looks up a different word, and painting
  /// it would put one word's explanation under another word.
  int _generation = 0;

  /// The last state handed to the UI, so a re-render can restore without
  /// asking again.
  AiExplanationResult get current => _current;
  AiExplanationResult _current = const AiExplanationResult.cancelled();

  /// Whether a request is running for the current lookup.
  bool get isActive => _current.isActive;

  /// Called when the popup shows a new word.
  ///
  /// Returns the state to render immediately; later states arrive through the
  /// callback.
  AiExplanationResult onLookup(AiLookupTarget target) {
    final AiProviderConfig config = _settings.read();

    _generation++;
    _subscription?.cancel();
    _subscription = null;
    _target = target;
    _cacheKey = null;

    if (!target.isUsable) {
      return _publish(const AiExplanationResult.cancelled());
    }

    final String apiKey = _credentials.readApiKey(config.provider);
    if (!config.isConfigured(hasApiKey: apiKey.isNotEmpty)) {
      if (config.cancelPendingRequests) {
        _repository.cancelAll();
      }
      return _publish(const AiExplanationResult.notConfigured());
    }

    final String key = _keyFor(target, config);
    _cacheKey = key;

    // Abandoning the previous word's request is gated on the user's setting.
    // With it off the request finishes into the cache — it just can never paint
    // another word, which the generation token above enforces.
    if (config.cancelPendingRequests) _repository.cancelExcept(key);

    // A cached answer renders instantly and costs nothing. This is what makes
    // re-opening a word you just looked at feel free.
    final String? cached = _repository.cached(key);
    if (cached != null) return _publish(AiExplanationResult.done(cached));

    // Auto-generation off: show the box with a generate action and send
    // nothing at all. The reference is explicit that no request goes out here.
    if (!config.autoGenerateOnLookup) {
      return _publish(const AiExplanationResult.manual());
    }

    return _start(config: config, apiKey: apiKey, key: key, force: false);
  }

  /// The regenerate action, and the generate action in the manual state — one
  /// button, and the forced path is right for both.
  AiExplanationResult regenerate() {
    final AiLookupTarget? target = _target;
    if (target == null || !target.isUsable) return _current;

    final AiProviderConfig config = _settings.read();
    final String apiKey = _credentials.readApiKey(config.provider);
    if (!config.isConfigured(hasApiKey: apiKey.isNotEmpty)) {
      return _publish(const AiExplanationResult.notConfigured());
    }

    _generation++;
    _subscription?.cancel();
    _subscription = null;

    final String key = _keyFor(target, config);
    _cacheKey = key;
    return _start(config: config, apiKey: apiKey, key: key, force: true);
  }

  /// The explicit cancel action.
  ///
  /// Always aborts, regardless of the "cancel unfinished requests" setting:
  /// that setting governs **implicit** abandonment (closing the popup, looking
  /// up another word), not a button the user just pressed. Only this word's
  /// request stops — other surfaces keep theirs.
  AiExplanationResult cancel() {
    _generation++;
    _subscription?.cancel();
    _subscription = null;
    final String? key = _cacheKey;
    if (key != null) _repository.cancel(key);
    return _publish(const AiExplanationResult.cancelled());
  }

  /// Called when the popup goes away.
  void onDismissed() {
    _generation++;
    _subscription?.cancel();
    _subscription = null;
    if (_settings.read().cancelPendingRequests) _repository.cancelAll();
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }

  String _keyFor(AiLookupTarget target, AiProviderConfig config) =>
      buildAiExplanationCacheKey(
        profileId: target.profileId,
        target: target.term,
        sentence: target.sentence,
        config: config,
      );

  AiExplanationResult _start({
    required AiProviderConfig config,
    required String apiKey,
    required String key,
    required bool force,
  }) {
    final AiLookupTarget target = _target!;
    final int generation = _generation;

    final AiRenderedPrompts prompts = AiPromptRenderer.render(
      userTemplate: config.userPrompt,
      systemTemplate: config.systemPrompt,
      target: target.term,
      sentence: target.sentence,
    );

    _subscription = _repository
        .explain(
          cacheKey: key,
          config: config,
          prompts: prompts,
          apiKey: apiKey,
          force: force,
        )
        .listen((AiExplanationResult result) {
          // A result belonging to a lookup the user has already moved past must not
          // paint. The repository guards its own identity; this guards ours.
          if (generation != _generation) return;
          _publish(result);
        });

    return _publish(const AiExplanationResult.loading());
  }

  AiExplanationResult _publish(AiExplanationResult result) {
    _current = result;
    _onResult(result);
    return result;
  }
}
