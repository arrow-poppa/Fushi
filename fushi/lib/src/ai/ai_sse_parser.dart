/// Incremental Server-Sent Events decoder for the BYOK AI Explanation feature.
///
/// Ported from the reference extension's `_readSseStream`
/// (`js/comm/ai-provider.js:325-360`, GPL-3.0, Copyright (C) 2023-2025 Yomitan
/// Authors). The framing rules are reproduced **exactly**, because they are the
/// contract every provider gateway is already being served against; see
/// `docs/agent/ai-explanation.md` §5.6.
///
/// This is the repository's first SSE consumer — nothing else in the tree parses
/// `text/event-stream`. It is deliberately pure: no I/O, no timers, no Flutter.
/// The caller decodes bytes to text (`stream.transform(utf8.decoder)` handles
/// multi-byte sequences split across network chunks) and feeds strings here.
///
/// Usage:
/// ```dart
/// final AiSseParser parser = AiSseParser();
/// await for (final String chunk in textStream) {
///   for (final String payload in parser.addChunk(chunk)) { handle(payload); }
/// }
/// for (final String payload in parser.close()) { handle(payload); }
/// ```
library;

/// Event separators recognised between SSE events.
///
/// Only these three forms, matching the reference. Mixed endings such as
/// `\r\n\n` are **not** separators: the buffer keeps growing and is flushed as
/// one residual event by [close]. Alternation order matters — at a given offset
/// `\r\n\r\n` is preferred over `\n\n` over `\r\r`, exactly as the JS engine
/// resolves it, so a `\r\n\r\n` boundary is never split into `\r\r` + stray
/// bytes.
final RegExp _eventSeparator = RegExp(r'\r\n\r\n|\n\n|\r\r');

/// Line separators **inside** one event. Broader than [_eventSeparator]: a lone
/// `\r` or `\n` ends a field line without ending the event.
final RegExp _lineSeparator = RegExp(r'\r\n|\n|\r');

/// Exactly one leading space after `data:` is part of the framing, not the
/// payload. Two spaces must leave one behind (SSE spec), so this strips one and
/// only one.
final RegExp _singleLeadingSpace = RegExp(r'^ ');

/// Feed it decoded text, get back completed SSE payloads.
///
/// One returned string = one event's joined `data:` lines. Events carrying no
/// `data:` line (`: keep-alive` comments, bare `event:` / `id:` / `retry:`
/// frames) yield nothing at all, which is what makes keep-alives free.
class AiSseParser {
  final StringBuffer _buffer = StringBuffer();

  /// Whether anything is still buffered. Used by tests and by the client to tell
  /// "clean end" from "truncated mid-event".
  bool get hasBufferedData => _buffer.isNotEmpty;

  /// Consumes one decoded chunk and returns every event completed by it.
  ///
  /// A chunk may complete several events, part of one, or none — an event split
  /// across arbitrarily many chunks is reassembled here.
  List<String> addChunk(String chunk) {
    if (chunk.isEmpty) return const <String>[];
    _buffer.write(chunk);

    String working = _buffer.toString();
    final List<String> payloads = <String>[];

    // Re-scan from offset 0 each time, as the reference does: the regex has no
    // /g and no lastIndex, so the earliest separator always wins.
    for (;;) {
      final Match? match = _eventSeparator.firstMatch(working);
      if (match == null) break;
      final String? payload = _extractPayload(
        working.substring(0, match.start),
      );
      if (payload != null) payloads.add(payload);
      working = working.substring(match.end);
    }

    _buffer
      ..clear()
      ..write(working);
    return payloads;
  }

  /// Flushes the tail once the stream has ended.
  ///
  /// Some gateways close without the trailing blank line, so a residual buffer
  /// is a real final event rather than garbage — but only when it holds
  /// something other than whitespace, matching the reference's
  /// `buffer.trim().length > 0` guard.
  List<String> close() {
    final String residual = _buffer.toString();
    _buffer.clear();
    if (residual.trim().isEmpty) return const <String>[];
    final String? payload = _extractPayload(residual);
    return payload == null ? const <String>[] : <String>[payload];
  }

  /// Joins one raw event's `data:` lines, or returns null when it has none.
  static String? _extractPayload(String rawEvent) {
    final List<String> dataLines = <String>[];
    for (final String line in rawEvent.split(_lineSeparator)) {
      // Anything else (`event:`, `id:`, `retry:`, `: comment`) carries no text.
      // A bare `data` with no colon is not a data line either.
      if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).replaceFirst(_singleLeadingSpace, ''));
      }
    }
    if (dataLines.isEmpty) return null;
    return dataLines.join('\n');
  }
}
