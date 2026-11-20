import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_explanation_client.dart';
import 'package:fushi/src/ai/ai_prompt_renderer.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:http/io_client.dart';

/// End-to-end transport tests against a real loopback server, following the
/// pattern `fushi/test/media/manga/online/mokuro_moe_client_test.dart`
/// established: a local HttpServer plus an injected client factory, so the test
/// never touches the network or the user's proxy settings.
///
/// A loopback server rather than a mock because the things most likely to break
/// are real transport behaviours: an SSE event split across TCP writes, a
/// cancelled subscription actually closing the socket, and a provider that
/// answers HTTP 200 with an error body.
///
/// See `docs/agent/ai-explanation.md` §5.6 and §13.
void main() {
  late HttpServer server;
  late String baseUrl;

  /// What the next request should be answered with.
  late FutureOr<void> Function(HttpRequest) handler;

  /// Bodies the server actually received, for asserting the wire format.
  late List<String> receivedBodies;
  late List<HttpHeaders> receivedHeaders;

  setUp(() async {
    receivedBodies = <String>[];
    receivedHeaders = <HttpHeaders>[];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    unawaited(() async {
      await for (final HttpRequest request in server) {
        receivedBodies.add(await utf8.decoder.bind(request).join());
        receivedHeaders.add(request.headers);
        await handler(request);
      }
    }());
  });

  tearDown(() async {
    await server.close(force: true);
  });

  AiExplanationClient client() =>
      AiExplanationClient(clientFactory: () => IOClient(HttpClient()));

  AiProviderConfig customConfig({String path = '/v1/chat/completions'}) =>
      AiProviderConfig(
        provider: AiProvider.custom,
        customEndpoint: '$baseUrl$path',
        customModel: 'test/model',
      );

  AiRenderedPrompts prompts({String system = ''}) => AiPromptRenderer.render(
    userTemplate: 'explain {{target}}',
    systemTemplate: system,
    target: 'word',
    sentence: 'ctx',
  );

  /// Writes an SSE body, optionally flushing between writes so the client sees
  /// genuinely separate network chunks.
  Future<void> writeSse(HttpRequest request, List<String> chunks) async {
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    for (final String chunk in chunks) {
      request.response.write(chunk);
      await request.response.flush();
    }
    await request.response.close();
  }

  group('non-streaming', () {
    test('sends the built body and returns the answer', () async {
      handler = (HttpRequest request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{'content': '  the answer  '},
              },
            ],
          }),
        );
        await request.response.close();
      };

      final String answer = await client().generate(
        config: customConfig(),
        prompts: prompts(),
        apiKey: 'k',
      );

      expect(answer, 'the answer', reason: 'the answer is trimmed');
      final Map<String, Object?> sent =
          jsonDecode(receivedBodies.single) as Map<String, Object?>;
      expect(sent['model'], 'test/model');
      expect(sent.containsKey('stream'), isFalse);
      expect((sent['messages']! as List<Object?>).single, <String, Object?>{
        'role': 'user',
        'content': 'explain word',
      });
      expect(receivedHeaders.single.value('authorization'), 'Bearer k');
    });

    test('surfaces a non-2xx provider message', () async {
      handler = (HttpRequest request) async {
        request.response.statusCode = 401;
        request.response.write(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{'message': 'Incorrect API key provided'},
          }),
        );
        await request.response.close();
      };

      await expectLater(
        client().generate(
          config: customConfig(),
          prompts: prompts(),
          apiKey: 'bad',
        ),
        throwsA(
          isA<AiProviderException>()
              .having((AiProviderException e) => e.statusCode, 'status', 401)
              .having(
                (AiProviderException e) => e.providerMessage,
                'message',
                'Incorrect API key provided',
              ),
        ),
      );
    });

    test('surfaces an error body returned with HTTP 200', () async {
      // Real gateways do this, and rendering it as a blank explanation would
      // hide a genuine failure from the user.
      handler = (HttpRequest request) async {
        request.response.write(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{'message': 'quota exceeded'},
          }),
        );
        await request.response.close();
      };

      await expectLater(
        client().generate(
          config: customConfig(),
          prompts: prompts(),
          apiKey: 'k',
        ),
        throwsA(
          isA<AiProviderException>().having(
            (AiProviderException e) => e.providerMessage,
            'message',
            'quota exceeded',
          ),
        ),
      );
    });

    test('clips a huge non-JSON error body', () async {
      // A provider answering with an HTML error page must not put a whole
      // document into the popup.
      handler = (HttpRequest request) async {
        request.response.statusCode = 502;
        request.response.write('<html>${'x' * 5000}</html>');
        await request.response.close();
      };

      try {
        await client().generate(
          config: customConfig(),
          prompts: prompts(),
          apiKey: 'k',
        );
        fail('expected a provider error');
      } on AiProviderException catch (e) {
        expect(e.providerMessage!.length, lessThanOrEqualTo(304));
        expect(e.providerMessage, endsWith('...'));
      }
    });

    test('round-trips a Unicode prompt and answer', () async {
      handler = (HttpRequest request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.add(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'message': <String, Object?>{'content': '「猫」は cat 🐱'},
                },
              ],
            }),
          ),
        );
        await request.response.close();
      };

      final String answer = await client().generate(
        config: customConfig(),
        prompts: AiPromptRenderer.render(
          userTemplate: '{{target}} / {{sentence}}',
          systemTemplate: '',
          target: '猫',
          sentence: '猫が好きです',
        ),
        apiKey: 'k',
      );

      expect(answer, '「猫」は cat 🐱');
      expect(
        receivedBodies.single,
        contains('猫が好きです'),
        reason: 'the prompt must survive UTF-8 encoding',
      );
    });
  });

  group('streaming', () {
    test('yields deltas from a well-formed SSE stream', () async {
      handler = (HttpRequest request) => writeSse(request, <String>[
        'data: {"choices":[{"delta":{"content":"Hel"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"lo"}}]}\n\n',
        'data: [DONE]\n\n',
      ]);

      final List<String> deltas = await client()
          .generateStream(
            config: customConfig(),
            prompts: prompts(),
            apiKey: 'k',
          )
          .toList();

      expect(deltas, <String>['Hel', 'lo']);
      expect(
        (jsonDecode(receivedBodies.single) as Map<String, Object?>)['stream'],
        isTrue,
      );
    });

    test('reassembles an event split across network chunks', () async {
      // The case a naive implementation gets wrong: the JSON payload arrives in
      // three separate TCP writes.
      handler = (HttpRequest request) => writeSse(request, <String>[
        'data: {"choices":[{"delta":',
        '{"content":"split"}}]}',
        '\n\ndata: [DONE]\n\n',
      ]);

      expect(
        await client()
            .generateStream(
              config: customConfig(),
              prompts: prompts(),
              apiKey: 'k',
            )
            .toList(),
        <String>['split'],
      );
    });

    test('ignores keep-alives and non-JSON padding', () async {
      handler = (HttpRequest request) => writeSse(request, <String>[
        ': keep-alive\n\n',
        'data: not json at all\n\n',
        'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n',
      ]);

      expect(
        await client()
            .generateStream(
              config: customConfig(),
              prompts: prompts(),
              apiKey: 'k',
            )
            .toList(),
        <String>['ok'],
        reason: 'padding must not be fatal',
      );
    });

    test('stops at [DONE] and discards anything after it', () async {
      handler = (HttpRequest request) => writeSse(request, <String>[
        'data: {"choices":[{"delta":{"content":"a"}}]}\n\n',
        'data: [DONE]\n\n',
        'data: {"choices":[{"delta":{"content":"late"}}]}\n\n',
      ]);

      expect(
        await client()
            .generateStream(
              config: customConfig(),
              prompts: prompts(),
              apiKey: 'k',
            )
            .toList(),
        <String>['a'],
      );
    });

    test('handles a stream that ends without a trailing blank line', () async {
      handler = (HttpRequest request) => writeSse(request, <String>[
        'data: {"choices":[{"delta":{"content":"tail"}}]}',
      ]);

      expect(
        await client()
            .generateStream(
              config: customConfig(),
              prompts: prompts(),
              apiKey: 'k',
            )
            .toList(),
        <String>['tail'],
        reason: 'the residual buffer is a real final event',
      );
    });

    test(
      'throws an in-stream error only after draining what arrived',
      () async {
        // Text that already reached the user must not be discarded by a late
        // error frame.
        handler = (HttpRequest request) => writeSse(request, <String>[
          'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
          'data: {"error":{"message":"upstream exploded"}}\n\n',
        ]);

        final List<String> deltas = <String>[];
        await expectLater(
          client()
              .generateStream(
                config: customConfig(),
                prompts: prompts(),
                apiKey: 'k',
              )
              .forEach(deltas.add),
          throwsA(
            isA<AiProviderException>().having(
              (AiProviderException e) => e.providerMessage,
              'message',
              'upstream exploded',
            ),
          ),
        );
        expect(
          deltas,
          <String>['partial'],
          reason: 'the delta that arrived before the error is still delivered',
        );
      },
    );

    test('reports a non-2xx before yielding anything', () async {
      handler = (HttpRequest request) async {
        request.response.statusCode = 429;
        request.response.write(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{'message': 'slow down'},
          }),
        );
        await request.response.close();
      };

      await expectLater(
        client()
            .generateStream(
              config: customConfig(),
              prompts: prompts(),
              apiKey: 'k',
            )
            .toList(),
        throwsA(
          isA<AiProviderException>().having(
            (AiProviderException e) => e.statusCode,
            'status',
            429,
          ),
        ),
      );
    });

    test('cancelling the subscription stops delivery', () async {
      // Cancellation is how "close the popup" and "look up another word" abort
      // an answer nobody will read.
      handler = (HttpRequest request) async {
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        for (int i = 0; i < 200; i++) {
          request.response.write(
            'data: {"choices":[{"delta":{"content":"$i "}}]}\n\n',
          );
          try {
            await request.response.flush();
          } on Object {
            // The client hung up mid-stream: that is the success condition,
            // and it proves cancel() really closed the socket.
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await request.response.close();
      };

      final List<String> received = <String>[];
      final Completer<void> gotSome = Completer<void>();
      final StreamSubscription<String> sub = client()
          .generateStream(
            config: customConfig(),
            prompts: prompts(),
            apiKey: 'k',
          )
          .listen((String delta) {
            received.add(delta);
            if (!gotSome.isCompleted) gotSome.complete();
          });

      await gotSome.future;
      final int atCancel = received.length;
      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(
        received.length,
        atCancel,
        reason: 'no delta may arrive after cancel()',
      );
      expect(received, isNotEmpty);
    });

    test(
      'the extractor is chosen by provider, not by sniffing the payload',
      () async {
        // A Gemini-shaped payload arriving on an OpenAI-compatible endpoint must
        // yield nothing rather than being opportunistically parsed: picking the
        // extractor from the response shape would make a malicious or misbehaving
        // gateway able to steer which parser runs.
        handler = (HttpRequest request) => writeSse(request, <String>[
          'data: {"candidates":[{"content":{"parts":[{"text":"x"}]}}]}\n\n',
        ]);

        expect(
          await client()
              .generateStream(
                config: customConfig(),
                prompts: prompts(),
                apiKey: 'k',
              )
              .toList(),
          isEmpty,
        );
      },
    );
  });

  group('request shape', () {
    test('a system prompt becomes the first message', () async {
      handler = (HttpRequest request) async {
        request.response.write('{"choices":[{"message":{"content":"x"}}]}');
        await request.response.close();
      };

      await client().generate(
        config: customConfig(),
        prompts: prompts(system: 'be terse'),
        apiKey: 'k',
      );

      final List<Object?> messages =
          (jsonDecode(receivedBodies.single)
                  as Map<String, Object?>)['messages']!
              as List<Object?>;
      expect(messages, hasLength(2));
      expect((messages.first as Map<String, Object?>)['role'], 'system');
    });

    test('a local http endpoint is allowed', () async {
      // Self-hosted inference is a first-class BYOK case; the whole suite
      // depends on it working.
      handler = (HttpRequest request) async {
        request.response.write('{"choices":[{"message":{"content":"local"}}]}');
        await request.response.close();
      };

      expect(
        await client().generate(
          config: customConfig(),
          prompts: prompts(),
          apiKey: 'k',
        ),
        'local',
      );
    });
  });
}
