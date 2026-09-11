/// The state of one AI explanation, as the popup needs to render it.
///
/// Mirrors the states the reference extension renders
/// (`js/display/ai-explanation-generator.js:318-392` and the error mapping at
/// `:227-255`, GPL-3.0, Copyright (C) 2023-2025 Yomitan Authors). See
/// `docs/agent/ai-explanation.md` §10.
///
/// The user-visible wording is **not** here: every string the popup shows goes
/// through i18n, so this layer carries a status and, for failures, a reason the
/// UI maps to a translated message.
library;

/// What the popup should be showing.
enum AiExplanationStatus {
  /// No provider configured, or no API key. The box appears and explains how to
  /// fix it; no request is made.
  notConfigured,

  /// Auto-generation is off and nothing is cached: the box appears with a
  /// generate action and **no request is sent**.
  manual,

  /// A request is in flight and no text has arrived yet.
  loading,

  /// Text is arriving. [AiExplanationResult.text] is the accumulated answer.
  streaming,

  /// Finished successfully.
  done,

  /// The 30 s inactivity timeout fired.
  timedOut,

  /// The request failed.
  failed,

  /// Superseded or deliberately abandoned. Renders nothing new — the popup
  /// keeps whatever it was showing, matching the reference.
  cancelled,
}

/// Why a request failed, so the UI can pick a translated message without
/// string-matching an exception.
enum AiExplanationFailure {
  /// The provider answered with an error.
  provider,

  /// The user's configuration cannot produce a valid request (bad endpoint,
  /// malformed Custom Request Body JSON).
  configuration,

  /// Anything else — network down, DNS, TLS.
  unknown,
}

/// An immutable snapshot of one explanation.
class AiExplanationResult {
  const AiExplanationResult({
    required this.status,
    this.text = '',
    this.failure,
    this.providerMessage,
  });

  const AiExplanationResult.notConfigured()
    : status = AiExplanationStatus.notConfigured,
      text = '',
      failure = null,
      providerMessage = null;

  const AiExplanationResult.manual()
    : status = AiExplanationStatus.manual,
      text = '',
      failure = null,
      providerMessage = null;

  const AiExplanationResult.loading()
    : status = AiExplanationStatus.loading,
      text = '',
      failure = null,
      providerMessage = null;

  const AiExplanationResult.streaming(this.text)
    : status = AiExplanationStatus.streaming,
      failure = null,
      providerMessage = null;

  const AiExplanationResult.done(this.text)
    : status = AiExplanationStatus.done,
      failure = null,
      providerMessage = null;

  const AiExplanationResult.timedOut()
    : status = AiExplanationStatus.timedOut,
      text = '',
      failure = null,
      providerMessage = null;

  const AiExplanationResult.cancelled()
    : status = AiExplanationStatus.cancelled,
      text = '',
      failure = null,
      providerMessage = null;

  const AiExplanationResult.failed(this.failure, {this.providerMessage})
    : status = AiExplanationStatus.failed,
      text = '';

  final AiExplanationStatus status;

  /// The answer so far (while streaming) or in full (when done). Empty in every
  /// other state.
  final String text;

  final AiExplanationFailure? failure;

  /// Provider-authored error text, already sanitised — it never contains a
  /// credential, a request body or a full Gemini URL. May be shown alongside a
  /// translated message.
  final String? providerMessage;

  /// Whether a request is still running.
  bool get isActive =>
      status == AiExplanationStatus.loading ||
      status == AiExplanationStatus.streaming;

  /// Whether this is a terminal state that should stop the spinner.
  bool get isTerminal =>
      status == AiExplanationStatus.done ||
      status == AiExplanationStatus.failed ||
      status == AiExplanationStatus.timedOut ||
      status == AiExplanationStatus.cancelled;

  /// Whether the answer is worth caching. Errors, timeouts and partial
  /// cancelled answers deliberately are not.
  bool get isCacheable =>
      status == AiExplanationStatus.done && text.trim().isNotEmpty;
}
