/// Response extraction for every provider.
///
/// Ported from the reference extension's `_stringifyMessageContent`,
/// `_extractOpenAIStreamDelta` and `_extractGeminiText`
/// (`js/comm/ai-provider.js:200-221`, `:367-378`, `:721-730`, GPL-3.0,
/// Copyright (C) 2023-2025 Yomitan Authors). See
/// `docs/agent/ai-explanation.md` §5.3 and §5.6.
///
/// Gateways are inconsistent about response shape — some send a plain string,
/// some an array of typed parts, some the legacy completion `text` field — so
/// these helpers accept all of them and never throw on a shape they do not
/// recognise: an unparseable chunk yields empty text rather than killing a
/// stream that is otherwise fine.
///
/// Every extractor returns the **raw** text. Deciding what to show when that is
/// empty is the controller's job, so the user-visible "no explanation" string
/// can go through i18n instead of being hardcoded here.
library;

import 'package:fushi/src/ai/ai_request_builder.dart';

abstract final class AiResponseParser {
  /// Flattens the many shapes an OpenAI-compatible `content` field can take.
  ///
  /// String → itself. Array → each part flattened and concatenated with **no**
  /// separator (parts are token fragments, not lines). Object → its `text`, else
  /// its `content`. Anything else → empty.
  static String stringifyMessageContent(Object? content) {
    if (content is String) return content;
    if (content is List) {
      final StringBuffer buffer = StringBuffer();
      for (final Object? part in content) {
        if (part is String) {
          buffer.write(part);
        } else if (part is Map) {
          buffer.write(_textOrContent(part));
        }
      }
      return buffer.toString();
    }
    if (content is Map) return _textOrContent(content);
    return '';
  }

  static String _textOrContent(Map<Object?, Object?> record) {
    final Object? text = record['text'];
    if (text is String) return text;
    final Object? nested = record['content'];
    if (nested is String) return nested;
    return '';
  }

  /// Extracts the incremental text of one OpenAI-compatible stream chunk.
  ///
  /// `delta.reasoning_content` and `delta.reasoning` are deliberately ignored:
  /// they are the model thinking out loud, not the answer, and showing them
  /// would leak chain-of-thought into the popup.
  static String extractOpenAiStreamDelta(Object? payload) {
    final Map<Object?, Object?>? choice = _firstChoice(payload);
    if (choice == null) return '';
    final Object? delta = choice['delta'];
    if (delta is Map) {
      final Object? content = delta['content'];
      if (content == null) return '';
      return stringifyMessageContent(content);
    }
    // Legacy completion-style streams.
    final Object? text = choice['text'];
    return text is String ? text : '';
  }

  /// Extracts the answer from a non-streaming OpenAI-compatible response.
  ///
  /// Precedence matches upstream: `message.content` first, then the legacy
  /// `text` field. An error object carried *inside* the choice is thrown rather
  /// than rendered, because some gateways return HTTP 200 with a per-choice
  /// error and the user would otherwise see a blank explanation.
  static String extractOpenAiMessage(Object? data) {
    final Map<Object?, Object?>? choice = _firstChoice(data);
    if (choice == null) return '';

    final Object? error = choice['error'];
    if (error is Map) {
      final Object? message = error['message'];
      throw AiRequestException(
        message is String && message.isNotEmpty
            ? message
            : 'The AI provider returned an error.',
      );
    }

    final Object? message = choice['message'];
    if (message is Map) {
      final Object? content = message['content'];
      if (content != null) return stringifyMessageContent(content);
    }
    final Object? text = choice['text'];
    return text is String ? text : '';
  }

  /// Extracts answer text from one Gemini payload, streaming or not.
  ///
  /// Walks **all** parts and skips any marked `thought: true`.
  ///
  /// **Divergence from the reference** (`docs/agent/ai-explanation.md` §8.7):
  /// upstream applies this filter only on the streaming path; its non-streaming
  /// path reads `parts[0].text` blindly, so a thinking Gemini 3 model with
  /// streaming off can return its internal reasoning as the explanation. The
  /// same filter belongs on both paths.
  static String extractGeminiText(Object? payload) {
    if (payload is! Map) return '';
    final Object? candidates = payload['candidates'];
    if (candidates is! List || candidates.isEmpty) return '';
    final Object? first = candidates.first;
    if (first is! Map) return '';
    final Object? content = first['content'];
    if (content is! Map) return '';
    final Object? parts = content['parts'];
    if (parts is! List) return '';

    final StringBuffer buffer = StringBuffer();
    for (final Object? part in parts) {
      if (part is! Map) continue;
      if (part['thought'] == true) continue;
      final Object? text = part['text'];
      if (text is String) buffer.write(text);
    }
    return buffer.toString();
  }

  /// Pulls a provider error message out of an error response body.
  ///
  /// Returns null when the body carries no usable message, so the caller can
  /// fall back to the HTTP status. The result is provider-authored text and is
  /// shown to the user, so callers must not concatenate it with anything
  /// sensitive.
  static String? extractErrorMessage(Object? data) {
    if (data is! Map) return null;
    final Object? error = data['error'];
    if (error is Map) {
      final Object? message = error['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    if (error is String && error.isNotEmpty) return error;
    final Object? message = data['message'];
    if (message is String && message.isNotEmpty) return message;
    return null;
  }

  static Map<Object?, Object?>? _firstChoice(Object? payload) {
    if (payload is! Map) return null;
    final Object? choices = payload['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final Object? first = choices.first;
    return first is Map ? first : null;
  }
}
