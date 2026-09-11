import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_sse_parser.dart';

/// [AiSseParser] is the repository's only `text/event-stream` decoder, and the
/// AI explanation is the only thing that streams — so every framing quirk a
/// provider gateway might emit has to be pinned here rather than discovered on a
/// user's device mid-answer.
///
/// The framing rules are ported verbatim from the reference extension
/// (`js/comm/ai-provider.js:325-360`); the cases below are the ones where a
/// naive re-implementation silently diverges: chunk boundaries that fall inside
/// an event, `\r\r` separators, the single-space strip after `data:`, multi-line
/// data joins, and a stream that ends without a trailing blank line.
///
/// See `docs/agent/ai-explanation.md` §5.6.
void main() {
  /// Feeds the whole payload as one chunk and drains the tail.
  List<String> parseWhole(String input) {
    final AiSseParser parser = AiSseParser();
    return <String>[...parser.addChunk(input), ...parser.close()];
  }

  /// Feeds the payload one character at a time — the worst case a network can
  /// produce, and the one that catches any reliance on chunk alignment.
  List<String> parseCharByChar(String input) {
    final AiSseParser parser = AiSseParser();
    final List<String> out = <String>[];
    for (final int rune in input.runes) {
      out.addAll(parser.addChunk(String.fromCharCode(rune)));
    }
    out.addAll(parser.close());
    return out;
  }

  group('event separators', () {
    test('splits on LF LF', () {
      expect(parseWhole('data: a\n\ndata: b\n\n'), <String>['a', 'b']);
    });

    test('splits on CRLF CRLF', () {
      expect(parseWhole('data: a\r\n\r\ndata: b\r\n\r\n'), <String>['a', 'b']);
    });

    test('splits on CR CR', () {
      expect(parseWhole('data: a\r\rdata: b\r\r'), <String>['a', 'b']);
    });

    test('prefers CRLFCRLF over CRCR at the same offset', () {
      // Alternation order matters: if `\r\r` won, the boundary would be split
      // and a stray `\n` would be prepended to the next event's first line,
      // which stops it matching `data:` at all.
      expect(parseWhole('data: a\r\n\r\ndata: b\r\n\r\n'), <String>['a', 'b'],
          reason: 'a CRLFCRLF boundary must not be consumed as CRCR');
    });
  });

  group('chunk fragmentation', () {
    test('reassembles an event split across chunks', () {
      final AiSseParser parser = AiSseParser();
      expect(parser.addChunk('data: hel'), isEmpty,
          reason: 'no separator yet, so nothing is complete');
      expect(parser.addChunk('lo'), isEmpty);
      expect(parser.addChunk('\n\n'), <String>['hello']);
    });

    test('a separator split across two chunks still separates', () {
      final AiSseParser parser = AiSseParser();
      expect(parser.addChunk('data: a\n'), isEmpty,
          reason: 'a lone LF is a line break, not an event boundary');
      expect(parser.addChunk('\ndata: b\n\n'), <String>['a', 'b']);
    });

    test('character-by-character delivery yields the same events', () {
      const String input =
          'data: one\n\n: keep-alive\n\ndata: two\r\n\r\ndata: three\n\n';
      expect(parseCharByChar(input), parseWhole(input),
          reason: 'framing must not depend on how the network chunks bytes');
    });

    test('one chunk may complete several events at once', () {
      expect(parseWhole('data: a\n\ndata: b\n\ndata: c\n\n'),
          <String>['a', 'b', 'c']);
    });
  });

  group('data lines', () {
    test('joins multiple data lines with LF', () {
      expect(parseWhole('data: line1\ndata: line2\n\n'),
          <String>['line1\nline2']);
    });

    test('strips exactly one leading space', () {
      // Two spaces must leave one behind: the first is framing, the second is
      // payload. Getting this wrong corrupts indented JSON and code blocks.
      expect(parseWhole('data:  padded\n\n'), <String>[' padded']);
    });

    test('keeps a data line with no space after the colon', () {
      expect(parseWhole('data:tight\n\n'), <String>['tight']);
    });

    test('keeps an empty data line', () {
      expect(parseWhole('data:\n\n'), <String>[''],
          reason: 'an empty data line is still a data line');
    });

    test('ignores comments, event, id and retry fields', () {
      expect(
        parseWhole(': ping\nevent: message\nid: 7\nretry: 100\ndata: real\n\n'),
        <String>['real'],
      );
    });

    test('emits nothing for an event carrying no data line', () {
      expect(parseWhole(': keep-alive\n\n'), isEmpty,
          reason: 'keep-alives must cost the caller nothing');
      expect(parseWhole('event: ping\n\n'), isEmpty);
    });

    test('ignores a bare `data` line with no colon', () {
      expect(parseWhole('data\n\n'), isEmpty);
    });

    test('splits inner lines on CR, LF and CRLF alike', () {
      expect(parseWhole('data: a\rdata: b\ndata: c\r\n\r\n'),
          <String>['a\nb\nc']);
    });
  });

  group('stream termination', () {
    test('flushes a residual event when the stream ends without a separator',
        () {
      // Real gateways do this; without the flush the last token of every answer
      // would be dropped.
      expect(parseWhole('data: a\n\ndata: tail'), <String>['a', 'tail']);
    });

    test('does not emit a whitespace-only residual', () {
      expect(parseWhole('data: a\n\n   \n'), <String>['a']);
    });

    test('does not emit a residual that has no data line', () {
      expect(parseWhole('data: a\n\n: trailing-comment'), <String>['a']);
    });

    test('close is idempotent and clears the buffer', () {
      final AiSseParser parser = AiSseParser();
      parser.addChunk('data: tail');
      expect(parser.hasBufferedData, isTrue);
      expect(parser.close(), <String>['tail']);
      expect(parser.hasBufferedData, isFalse);
      expect(parser.close(), isEmpty, reason: 'a second close emits nothing');
    });

    test('an empty chunk is a no-op', () {
      final AiSseParser parser = AiSseParser();
      expect(parser.addChunk(''), isEmpty);
      expect(parser.hasBufferedData, isFalse);
    });
  });

  group('payload passthrough', () {
    test('does not interpret the payload', () {
      // The parser must hand `[DONE]` and malformed JSON straight through; the
      // sentinel check and JSON tolerance belong to the provider layer.
      expect(parseWhole('data: [DONE]\n\n'), <String>['[DONE]']);
      expect(parseWhole('data: {not json\n\n'), <String>['{not json']);
    });

    test('preserves Unicode and emoji payloads', () {
      expect(parseWhole('data: 日本語 — 「猫」 🐱\n\n'),
          <String>['日本語 — 「猫」 🐱']);
    });

    test('preserves a multi-byte payload split across chunks', () {
      const String text = 'data: 猫が好きです\n\n';
      expect(parseCharByChar(text), <String>['猫が好きです'],
          reason: 'decoded text must survive arbitrary chunk boundaries');
    });
  });
}
