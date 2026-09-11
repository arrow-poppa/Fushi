import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_request_builder.dart';
import 'package:fushi/src/ai/ai_response_parser.dart';

/// Gateways disagree about response shape, and a BYOK user can point Fushi at
/// any of them. These extractors have to accept a plain string, an array of
/// typed parts and the legacy completion `text` field, and they must degrade to
/// empty text rather than throwing — a single odd chunk must not kill a stream
/// that is otherwise producing a good answer.
///
/// The thinking-suppression cases are the ones with real consequences: leaking
/// `reasoning_content` or a Gemini `thought` part into the popup would show the
/// user the model's private reasoning instead of the explanation.
///
/// See `docs/agent/ai-explanation.md` §5.3 and §5.6.
void main() {
  Object? json(String source) => jsonDecode(source);

  group('stringifyMessageContent', () {
    test('passes a plain string through', () {
      expect(AiResponseParser.stringifyMessageContent('hello'), 'hello');
    });

    test('concatenates array parts with no separator', () {
      // Parts are token fragments, not lines: joining with anything would insert
      // characters the model never produced.
      expect(
        AiResponseParser.stringifyMessageContent(json('''
          [{"type":"text","text":"猫 "},{"type":"text","text":"means cat"}]
        ''')),
        '猫 means cat',
      );
    });

    test('accepts bare strings inside the array', () {
      expect(
        AiResponseParser.stringifyMessageContent(json('["a","b"]')),
        'ab',
      );
    });

    test('falls back from text to content on a part', () {
      expect(
        AiResponseParser.stringifyMessageContent(json('[{"content":"x"}]')),
        'x',
      );
    });

    test('reads a bare object', () {
      expect(AiResponseParser.stringifyMessageContent(json('{"text":"x"}')), 'x');
      expect(
          AiResponseParser.stringifyMessageContent(json('{"content":"y"}')), 'y');
    });

    test('yields empty for shapes it does not recognise', () {
      expect(AiResponseParser.stringifyMessageContent(null), isEmpty);
      expect(AiResponseParser.stringifyMessageContent(42), isEmpty);
      expect(AiResponseParser.stringifyMessageContent(json('[{"foo":1}]')),
          isEmpty);
      expect(AiResponseParser.stringifyMessageContent(json('[null,1,true]')),
          isEmpty);
    });
  });

  group('extractOpenAiStreamDelta', () {
    test('reads delta.content', () {
      expect(
        AiResponseParser.extractOpenAiStreamDelta(
            json('{"choices":[{"delta":{"content":"tok"}}]}')),
        'tok',
      );
    });

    test('ignores reasoning_content', () {
      // Thinking is not the answer; showing it would expose chain-of-thought.
      expect(
        AiResponseParser.extractOpenAiStreamDelta(json(
            '{"choices":[{"delta":{"reasoning_content":"thinking hard"}}]}')),
        isEmpty,
      );
    });

    test('ignores a reasoning field alongside real content', () {
      expect(
        AiResponseParser.extractOpenAiStreamDelta(json(
            '{"choices":[{"delta":{"reasoning":"hmm","content":"real"}}]}')),
        'real',
      );
    });

    test('treats a null content delta as empty, not as an error', () {
      // The first chunk of many streams carries only a role.
      expect(
        AiResponseParser.extractOpenAiStreamDelta(
            json('{"choices":[{"delta":{"role":"assistant"}}]}')),
        isEmpty,
      );
      expect(
        AiResponseParser.extractOpenAiStreamDelta(
            json('{"choices":[{"delta":{"content":null}}]}')),
        isEmpty,
      );
    });

    test('accepts an array-valued delta content', () {
      expect(
        AiResponseParser.extractOpenAiStreamDelta(json(
            '{"choices":[{"delta":{"content":[{"text":"a"},{"text":"b"}]}}]}')),
        'ab',
      );
    });

    test('falls back to the legacy completion text field', () {
      expect(
        AiResponseParser.extractOpenAiStreamDelta(
            json('{"choices":[{"text":"legacy"}]}')),
        'legacy',
      );
    });

    test('yields empty for malformed payloads instead of throwing', () {
      for (final String source in <String>[
        '{}',
        '{"choices":[]}',
        '{"choices":"nope"}',
        '{"choices":[null]}',
        '[]',
        'null',
        '"a string"',
      ]) {
        expect(AiResponseParser.extractOpenAiStreamDelta(json(source)), isEmpty,
            reason: '$source must not kill the stream');
      }
    });
  });

  group('extractOpenAiMessage', () {
    test('reads message.content', () {
      expect(
        AiResponseParser.extractOpenAiMessage(
            json('{"choices":[{"message":{"content":"answer"}}]}')),
        'answer',
      );
    });

    test('accepts composite content from a gateway', () {
      expect(
        AiResponseParser.extractOpenAiMessage(json(
            '{"choices":[{"message":{"content":[{"text":"a"},{"text":"b"}]}}]}')),
        'ab',
      );
    });

    test('falls back to the legacy text field', () {
      expect(
        AiResponseParser.extractOpenAiMessage(
            json('{"choices":[{"text":"legacy"}]}')),
        'legacy',
      );
    });

    test('prefers message.content over text', () {
      expect(
        AiResponseParser.extractOpenAiMessage(json(
            '{"choices":[{"message":{"content":"msg"},"text":"legacy"}]}')),
        'msg',
      );
    });

    test('throws on an error carried inside the choice', () {
      // Some gateways answer HTTP 200 with a per-choice error; rendering that as
      // a blank explanation would hide a real failure from the user.
      expect(
        () => AiResponseParser.extractOpenAiMessage(json(
            '{"choices":[{"error":{"message":"quota exceeded"}}]}')),
        throwsA(isA<AiRequestException>().having(
            (AiRequestException e) => e.message, 'message', 'quota exceeded')),
      );
    });

    test('throws a generic message when the error has no message', () {
      expect(
        () => AiResponseParser.extractOpenAiMessage(
            json('{"choices":[{"error":{}}]}')),
        throwsA(isA<AiRequestException>()),
      );
    });

    test('yields empty for an empty or malformed body', () {
      expect(AiResponseParser.extractOpenAiMessage(json('{}')), isEmpty);
      expect(AiResponseParser.extractOpenAiMessage(json('{"choices":[]}')),
          isEmpty);
      expect(AiResponseParser.extractOpenAiMessage(null), isEmpty);
    });
  });

  group('extractGeminiText', () {
    test('concatenates every non-thought part', () {
      expect(
        AiResponseParser.extractGeminiText(json('''
          {"candidates":[{"content":{"parts":[{"text":"a"},{"text":"b"}]}}]}
        ''')),
        'ab',
      );
    });

    test('skips parts marked as thought', () {
      // Divergence §8.7: upstream applies this only while streaming, so a
      // thinking model with streaming off can return its reasoning as the
      // answer. The filter belongs on both paths.
      expect(
        AiResponseParser.extractGeminiText(json('''
          {"candidates":[{"content":{"parts":[
            {"thought":true,"text":"internal reasoning"},
            {"text":"the answer"}
          ]}}]}
        ''')),
        'the answer',
      );
    });

    test('reads past a leading thought part rather than stopping at index 0',
        () {
      // Upstream's non-streaming path reads parts[0].text blindly, which is
      // exactly this payload returning the thought.
      expect(
        AiResponseParser.extractGeminiText(json('''
          {"candidates":[{"content":{"parts":[
            {"thought":true,"text":"secret"},
            {"text":"visible"}
          ]}}]}
        ''')),
        isNot(contains('secret')),
      );
    });

    test('yields empty when every part is a thought', () {
      expect(
        AiResponseParser.extractGeminiText(json('''
          {"candidates":[{"content":{"parts":[{"thought":true,"text":"x"}]}}]}
        ''')),
        isEmpty,
      );
    });

    test('yields empty for malformed payloads instead of throwing', () {
      for (final String source in <String>[
        '{}',
        '{"candidates":[]}',
        '{"candidates":[{}]}',
        '{"candidates":[{"content":{}}]}',
        '{"candidates":[{"content":{"parts":"nope"}}]}',
        'null',
        '[]',
      ]) {
        expect(AiResponseParser.extractGeminiText(json(source)), isEmpty,
            reason: '$source must degrade quietly');
      }
    });

    test('preserves Unicode', () {
      expect(
        AiResponseParser.extractGeminiText(json('''
          {"candidates":[{"content":{"parts":[{"text":"猫が好き 🐱"}]}}]}
        ''')),
        '猫が好き 🐱',
      );
    });
  });

  group('extractErrorMessage', () {
    test('reads the common error.message shape', () {
      expect(
        AiResponseParser.extractErrorMessage(
            json('{"error":{"message":"bad key"}}')),
        'bad key',
      );
    });

    test('reads a bare string error and a top-level message', () {
      expect(AiResponseParser.extractErrorMessage(json('{"error":"oops"}')),
          'oops');
      expect(AiResponseParser.extractErrorMessage(json('{"message":"nope"}')),
          'nope');
    });

    test('returns null when there is nothing usable', () {
      expect(AiResponseParser.extractErrorMessage(json('{}')), isNull);
      expect(AiResponseParser.extractErrorMessage(json('{"error":{}}')), isNull);
      expect(AiResponseParser.extractErrorMessage(null), isNull);
      expect(AiResponseParser.extractErrorMessage(json('"text"')), isNull);
    });
  });
}
