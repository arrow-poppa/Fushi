import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_prompt_renderer.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_request_builder.dart';

/// These tests pin the exact bytes a BYOK request puts on the wire.
///
/// That matters more here than in most layers: the user pays per request, a
/// malformed body is only discovered by spending money on it, and the reasoning
/// mapping has 192 reachable input combinations whose upstream behaviour is
/// genuinely non-obvious (`max` becomes `xhigh` on OpenRouter but stays `max`
/// everywhere else; `exclude` is forced true; a `{`-prefixed value that is not
/// valid JSON degrades to an `effort` string containing the braces).
///
/// The full matrix was cross-checked by executing the reference implementation
/// and diffing it against this port — 301/301 cases identical. What follows is
/// the readable subset that guards the behaviour a future edit is most likely
/// to break. See `docs/agent/ai-explanation.md` §5.3-§5.5.
void main() {
  const String openRouterUrl = 'https://openrouter.ai/api/v1/chat/completions';
  const String otherUrl = 'https://api.example.com/v1/chat/completions';

  AiRenderedPrompts prompts({String system = ''}) => AiPromptRenderer.render(
        userTemplate: 'Explain {{target}} in {{sentence}}.',
        systemTemplate: system,
        target: 'word',
        sentence: 'ctx',
      );

  Map<String, Object?> customBody({
    AiThinkingMode thinkingMode = AiThinkingMode.unset,
    AiThinkingIntensity thinkingIntensity = AiThinkingIntensity.unset,
    String thinkingValue = '',
    AiProviderRoutingMode routingMode = AiProviderRoutingMode.unset,
    String slugs = '',
    bool allowFallbacks = true,
    String requestBodyJson = '',
    String endpoint = openRouterUrl,
    bool stream = false,
  }) =>
      AiRequestBuilder.buildCustom(
        config: AiProviderConfig(
          provider: AiProvider.custom,
          customEndpoint: endpoint,
          customModel: 'some/model',
          customThinkingMode: thinkingMode,
          customThinkingIntensity: thinkingIntensity,
          customThinkingValue: thinkingValue,
          customRoutingMode: routingMode,
          customRoutingSlugs: slugs,
          customAllowFallbacks: allowFallbacks,
          customRequestBodyJson: requestBodyJson,
        ),
        prompts: prompts(),
        apiKey: 'k',
        stream: stream,
      ).body;

  group('messages', () {
    test('a user message is always present', () {
      // The single invariant that must never break: upstream sends content:""
      // when the prompt is blank, and gateways answer `Input required: specify
      // "prompt" or "messages"`.
      for (final AiHttpRequest request in <AiHttpRequest>[
        AiRequestBuilder.buildOpenAi(
            config: const AiProviderConfig(),
            prompts: AiPromptRenderer.render(
                userTemplate: '',
                systemTemplate: '',
                target: 'w',
                sentence: ''),
            apiKey: 'k',
            stream: false),
        AiRequestBuilder.buildDeepSeek(
            config: const AiProviderConfig(deepseekModel: 'd'),
            prompts: prompts(),
            apiKey: 'k',
            stream: false),
      ]) {
        final List<Object?> messages = request.body['messages']! as List<Object?>;
        expect(messages, isNotEmpty);
        final Map<Object?, Object?> last =
            messages.last as Map<Object?, Object?>;
        expect(last['role'], 'user');
        expect((last['content']! as String).trim(), isNotEmpty,
            reason: 'a request must never carry an empty user message');
      }
    });

    test('omits the system message when the system prompt is empty', () {
      final List<Object?> messages = AiRequestBuilder.buildMessages(prompts());
      expect(messages, hasLength(1));
      expect((messages.single as Map<String, String>)['role'], 'user');
    });

    test('prepends the system message when one is set', () {
      final List<Map<String, String>> messages =
          AiRequestBuilder.buildMessages(prompts(system: 'be terse'));
      expect(messages, hasLength(2));
      expect(messages.first['role'], 'system');
      expect(messages.first['content'], 'be terse');
      expect(messages.last['role'], 'user');
    });
  });

  group('OpenAI', () {
    test('uses the fixed endpoint and a bearer token', () {
      final AiHttpRequest request = AiRequestBuilder.buildOpenAi(
          config: const AiProviderConfig(),
          prompts: prompts(),
          apiKey: 'sk-test',
          stream: false);
      expect(request.url, 'https://api.openai.com/v1/chat/completions');
      expect(request.headers['Authorization'], 'Bearer sk-test');
      expect(request.headers['Content-Type'], 'application/json');
    });

    test('trims a pasted key', () {
      // Upstream trims for DeepSeek and Custom but not OpenAI, so a key copied
      // with a trailing newline fails only there. That is a bug, not a contract.
      final AiHttpRequest request = AiRequestBuilder.buildOpenAi(
          config: const AiProviderConfig(),
          prompts: prompts(),
          apiKey: '  sk-test\n',
          stream: false);
      expect(request.headers['Authorization'], 'Bearer sk-test');
    });

    test('omits the stream key entirely when not streaming', () {
      final Map<String, Object?> body = AiRequestBuilder.buildOpenAi(
          config: const AiProviderConfig(),
          prompts: prompts(),
          apiKey: 'k',
          stream: false).body;
      expect(body.containsKey('stream'), isFalse,
          reason: 'upstream sends no stream field at all on the sync path');
      expect(body['model'], 'gpt-4o-mini');
      expect(body['temperature'], 0.7);
    });

    test('sets stream true when streaming', () {
      expect(
        AiRequestBuilder.buildOpenAi(
            config: const AiProviderConfig(),
            prompts: prompts(),
            apiKey: 'k',
            stream: true).body['stream'],
        isTrue,
      );
    });

    test('never carries reasoning, routing or custom body fields', () {
      final Map<String, Object?> body = AiRequestBuilder.buildOpenAi(
          config: const AiProviderConfig(
            customThinkingMode: AiThinkingMode.enabled,
            customRequestBodyJson: '{"top_p":0.1}',
          ),
          prompts: prompts(),
          apiKey: 'k',
          stream: false).body;
      expect(body.keys.toSet(),
          <String>{'model', 'messages', 'temperature'});
    });
  });

  group('DeepSeek', () {
    test('uses the endpoint without a /v1 segment', () {
      final AiHttpRequest request = AiRequestBuilder.buildDeepSeek(
          config: const AiProviderConfig(deepseekModel: 'deepseek-chat'),
          prompts: prompts(),
          apiKey: 'k',
          stream: false);
      expect(request.url, 'https://api.deepseek.com/chat/completions',
          reason: 'adding /v1 404s');
    });

    test('always carries an explicit stream field', () {
      expect(
        AiRequestBuilder.buildDeepSeek(
            config: const AiProviderConfig(deepseekModel: 'd'),
            prompts: prompts(),
            apiKey: 'k',
            stream: false).body['stream'],
        isFalse,
      );
    });

    test('uses the non-OpenRouter thinking shape', () {
      final Map<String, Object?> body = AiRequestBuilder.buildDeepSeek(
          config: const AiProviderConfig(
            deepseekModel: 'd',
            deepseekThinkingMode: AiThinkingMode.enabled,
            deepseekThinkingIntensity: AiThinkingIntensity.max,
          ),
          prompts: prompts(),
          apiKey: 'k',
          stream: false).body;
      expect(body['thinking'], <String, Object?>{'type': 'enabled'});
      expect(body['reasoning_effort'], 'max',
          reason: 'max is only rewritten to xhigh on OpenRouter');
      expect(body.containsKey('reasoning'), isFalse);
    });

    test('disabled suppresses reasoning_effort', () {
      final Map<String, Object?> body = AiRequestBuilder.buildDeepSeek(
          config: const AiProviderConfig(
            deepseekModel: 'd',
            deepseekThinkingMode: AiThinkingMode.disabled,
            deepseekThinkingIntensity: AiThinkingIntensity.high,
          ),
          prompts: prompts(),
          apiKey: 'k',
          stream: false).body;
      expect(body['thinking'], <String, Object?>{'type': 'disabled'});
      expect(body.containsKey('reasoning_effort'), isFalse);
    });
  });

  group('OpenRouter detection', () {
    test('matches the domain and its subdomains', () {
      expect(AiRequestBuilder.isOpenRouterEndpoint(openRouterUrl), isTrue);
      expect(
          AiRequestBuilder.isOpenRouterEndpoint('https://openrouter.ai/'), isTrue);
      expect(
          AiRequestBuilder.isOpenRouterEndpoint('https://api.openrouter.ai/v1'),
          isTrue);
    });

    test('rejects lookalike hosts (divergence §8.4)', () {
      // Upstream uses hostname.endsWith('openrouter.ai'), so these are treated
      // as OpenRouter and receive the bearer token plus identifying headers.
      for (final String url in <String>[
        'https://evil-openrouter.ai/v1/chat/completions',
        'https://notopenrouter.ai/v1',
        'https://openrouter.ai.attacker.com/v1',
      ]) {
        expect(AiRequestBuilder.isOpenRouterEndpoint(url), isFalse,
            reason: '$url is not OpenRouter');
      }
    });

    test('rejects junk without throwing', () {
      expect(AiRequestBuilder.isOpenRouterEndpoint(''), isFalse);
      expect(AiRequestBuilder.isOpenRouterEndpoint('not a url'), isFalse);
    });
  });

  group('OpenRouter identifying headers (divergence §8.6)', () {
    test('identify Fushi and use the documented header name', () {
      final Map<String, String> headers = AiRequestBuilder.buildCustom(
        config: const AiProviderConfig(
            provider: AiProvider.custom,
            customEndpoint: openRouterUrl,
            customModel: 'm'),
        prompts: prompts(),
        apiKey: 'k',
        stream: false,
      ).headers;
      expect(headers['X-Title'], 'Fushi');
      expect(headers.containsKey('X-OpenRouter-Title'), isFalse,
          reason: 'upstream sends a header OpenRouter does not document');
      expect(headers['HTTP-Referer'], isNot(contains('yomitan')));
      expect(headers['HTTP-Referer'], startsWith('https://'));
    });

    test('are absent on non-OpenRouter endpoints', () {
      final Map<String, String> headers = AiRequestBuilder.buildCustom(
        config: const AiProviderConfig(
            provider: AiProvider.custom,
            customEndpoint: otherUrl,
            customModel: 'm'),
        prompts: prompts(),
        apiKey: 'k',
        stream: false,
      ).headers;
      expect(headers.containsKey('X-Title'), isFalse);
      expect(headers.containsKey('HTTP-Referer'), isFalse);
    });
  });

  group('OpenRouter provider routing', () {
    test('order, only and ignore each map to their own field', () {
      expect(
          (customBody(
                  routingMode: AiProviderRoutingMode.order,
                  slugs: 'a,b')['provider']! as Map<String, Object?>)['order'],
          <String>['a', 'b']);
      expect(
          (customBody(
                  routingMode: AiProviderRoutingMode.only,
                  slugs: 'a')['provider']! as Map<String, Object?>)['only'],
          <String>['a']);
      expect(
          (customBody(
                  routingMode: AiProviderRoutingMode.ignore,
                  slugs: 'a')['provider']! as Map<String, Object?>)['ignore'],
          <String>['a']);
    });

    test('slugs split on commas and newlines and drop empties', () {
      expect(AiRequestBuilder.parseProviderSlugs('a, b\nc'),
          <String>['a', 'b', 'c']);
      expect(AiRequestBuilder.parseProviderSlugs(' , , '), isEmpty);
      expect(AiRequestBuilder.parseProviderSlugs('deepinfra/turbo, fireworks'),
          <String>['deepinfra/turbo', 'fireworks']);
    });

    test('no routing field is emitted when the slug list is empty', () {
      final Map<String, Object?> provider =
          customBody(routingMode: AiProviderRoutingMode.only)['provider']!
              as Map<String, Object?>;
      expect(provider.containsKey('only'), isFalse);
    });

    test('allow_fallbacks rides along even with routing left on Default', () {
      // Consequence worth pinning: every OpenRouter request carries a provider
      // object because allow_fallbacks alone makes it non-empty.
      expect(customBody()['provider'],
          <String, Object?>{'allow_fallbacks': true});
      expect(customBody(allowFallbacks: false)['provider'],
          <String, Object?>{'allow_fallbacks': false});
    });

    test('routing is inert on a non-OpenRouter endpoint', () {
      expect(
        customBody(
            endpoint: otherUrl,
            routingMode: AiProviderRoutingMode.only,
            slugs: 'a'),
        isNot(contains('provider')),
      );
    });
  });

  group('reasoning mapping', () {
    test('nothing is added when neither axis is set', () {
      expect(customBody().containsKey('reasoning'), isFalse);
      expect(customBody(endpoint: otherUrl).keys.toSet(),
          <String>{'model', 'messages', 'temperature'});
    });

    test('disabled wins over any intensity', () {
      expect(
        customBody(
            thinkingMode: AiThinkingMode.disabled,
            thinkingIntensity: AiThinkingIntensity.high),
        containsPair('reasoning',
            <String, Object?>{'effort': 'none', 'exclude': true}),
      );
    });

    test('high and max map to high and xhigh', () {
      expect(
          customBody(thinkingIntensity: AiThinkingIntensity.high)['reasoning'],
          <String, Object?>{'effort': 'high', 'exclude': true});
      expect(
          customBody(thinkingIntensity: AiThinkingIntensity.max)['reasoning'],
          <String, Object?>{'effort': 'xhigh', 'exclude': true});
    });

    test('enabled with no intensity sets enabled true', () {
      expect(customBody(thinkingMode: AiThinkingMode.enabled)['reasoning'],
          <String, Object?>{'enabled': true, 'exclude': true});
    });

    test('a numeric custom value becomes max_tokens', () {
      expect(
        customBody(
            thinkingIntensity: AiThinkingIntensity.custom,
            thinkingValue: '2000')['reasoning'],
        <String, Object?>{'max_tokens': 2000, 'exclude': true},
      );
    });

    test('a textual custom value becomes effort, with max special-cased', () {
      expect(
          customBody(
              thinkingIntensity: AiThinkingIntensity.custom,
              thinkingValue: 'medium')['reasoning'],
          <String, Object?>{'effort': 'medium', 'exclude': true});
      expect(
          customBody(
              thinkingIntensity: AiThinkingIntensity.custom,
              thinkingValue: 'max')['reasoning'],
          <String, Object?>{'effort': 'xhigh', 'exclude': true});
    });

    test('a JSON object custom value merges into reasoning', () {
      expect(
        customBody(
            thinkingIntensity: AiThinkingIntensity.custom,
            thinkingValue: '{"max_tokens":2000}')['reasoning'],
        <String, Object?>{'max_tokens': 2000, 'exclude': true},
      );
    });

    test('exclude is forced true even when the user sets it false', () {
      // Internal thinking must never reach the popup.
      expect(
        (customBody(
                    thinkingIntensity: AiThinkingIntensity.custom,
                    thinkingValue: '{"effort":"high","exclude":false}')[
                'reasoning']! as Map<String, Object?>)['exclude'],
        isTrue,
      );
    });

    test('invalid JSON degrades to an effort string, it does not throw', () {
      expect(
          customBody(
              thinkingIntensity: AiThinkingIntensity.custom,
              thinkingValue: '{bad json')['reasoning'],
          <String, Object?>{'effort': '{bad json', 'exclude': true});
    });

    test('a JSON array is not treated as an object', () {
      expect(
          customBody(
              thinkingIntensity: AiThinkingIntensity.custom,
              thinkingValue: '[1,2]')['reasoning'],
          <String, Object?>{'effort': '[1,2]', 'exclude': true});
    });

    test('intensity without a mode still sets reasoning_effort off OpenRouter',
        () {
      expect(
          customBody(
              endpoint: otherUrl,
              thinkingIntensity: AiThinkingIntensity.high)['reasoning_effort'],
          'high');
    });
  });

  group('custom request body JSON', () {
    test('is a no-op when empty or whitespace', () {
      expect(customBody(requestBodyJson: '   ').keys,
          isNot(contains('top_p')));
    });

    test('merges new keys and overrides generated ones', () {
      final Map<String, Object?> body =
          customBody(requestBodyJson: '{"top_p":0.5,"temperature":0.1}');
      expect(body['top_p'], 0.5);
      expect(body['temperature'], 0.1,
          reason: 'custom values win over the generated body');
    });

    test('merges deeply rather than replacing whole objects', () {
      final Map<String, Object?> provider = customBody(
        routingMode: AiProviderRoutingMode.order,
        slugs: 'a',
        requestBodyJson: '{"provider":{"order":["z"]}}',
      )['provider']! as Map<String, Object?>;
      expect(provider['order'], <String>['z'], reason: 'arrays replace');
      expect(provider['allow_fallbacks'], isTrue,
          reason: 'sibling keys survive a deep merge');
    });

    test('rejects a JSON array', () {
      expect(() => customBody(requestBodyJson: '[1,2]'),
          throwsA(isA<AiRequestException>()));
    });

    test('rejects a scalar and null', () {
      expect(() => customBody(requestBodyJson: '5'),
          throwsA(isA<AiRequestException>()));
      expect(() => customBody(requestBodyJson: '"x"'),
          throwsA(isA<AiRequestException>()));
      expect(() => customBody(requestBodyJson: 'null'),
          throwsA(isA<AiRequestException>()));
    });

    test('rejects malformed JSON before any network call', () {
      expect(() => customBody(requestBodyJson: '{oops'),
          throwsA(isA<AiRequestException>()));
    });

    test('the rejection message names the setting and leaks nothing', () {
      try {
        customBody(requestBodyJson: '{oops');
        fail('expected a rejection');
      } on AiRequestException catch (e) {
        expect(e.message, contains('Custom Request Body JSON'));
        expect(e.message, isNot(contains('Bearer')));
      }
    });

    test('cannot disable a streaming the user turned on', () {
      // Assigned after the merge upstream, and here, for exactly this reason.
      expect(
        customBody(requestBodyJson: '{"stream":false}', stream: true)['stream'],
        isTrue,
      );
    });

    test('cannot override the Authorization header', () {
      // Headers are built separately from the body, so custom JSON has no path
      // to them at all — asserted so a future refactor cannot merge them.
      final AiHttpRequest request = AiRequestBuilder.buildCustom(
        config: const AiProviderConfig(
          provider: AiProvider.custom,
          customEndpoint: openRouterUrl,
          customModel: 'm',
          customRequestBodyJson: '{"headers":{"Authorization":"Bearer evil"}}',
        ),
        prompts: prompts(),
        apiKey: 'real',
        stream: false,
      );
      expect(request.headers['Authorization'], 'Bearer real');
    });
  });

  group('custom endpoint validation', () {
    test('is used verbatim with no path appended', () {
      expect(
        AiRequestBuilder.buildCustom(
          config: const AiProviderConfig(
              provider: AiProvider.custom,
              customEndpoint: 'https://api.example.com/weird/path',
              customModel: 'm'),
          prompts: prompts(),
          apiKey: 'k',
          stream: false,
        ).url,
        'https://api.example.com/weird/path',
      );
    });

    test('rejects a non-URL', () {
      expect(
        () => AiRequestBuilder.buildCustom(
          config: const AiProviderConfig(
              provider: AiProvider.custom,
              customEndpoint: 'api.example.com',
              customModel: 'm'),
          prompts: prompts(),
          apiKey: 'k',
          stream: false,
        ),
        throwsA(isA<AiRequestException>()),
      );
    });

    test('rejects an unsupported scheme', () {
      expect(
        () => AiRequestBuilder.buildCustom(
          config: const AiProviderConfig(
              provider: AiProvider.custom,
              customEndpoint: 'ftp://api.example.com/v1',
              customModel: 'm'),
          prompts: prompts(),
          apiKey: 'k',
          stream: false,
        ),
        throwsA(isA<AiRequestException>()),
      );
    });

    test('accepts a local http endpoint', () {
      // Self-hosted inference on localhost is a first-class BYOK case, and the
      // app's proxy layer already forces DIRECT for loopback targets.
      expect(
        AiRequestBuilder.buildCustom(
          config: const AiProviderConfig(
              provider: AiProvider.custom,
              customEndpoint: 'http://127.0.0.1:11434/v1/chat/completions',
              customModel: 'm'),
          prompts: prompts(),
          apiKey: 'k',
          stream: false,
        ).url,
        'http://127.0.0.1:11434/v1/chat/completions',
      );
    });
  });

  group('serialisation', () {
    test('the body round-trips through JSON', () {
      final AiHttpRequest request = AiRequestBuilder.buildCustom(
        config: const AiProviderConfig(
          provider: AiProvider.custom,
          customEndpoint: openRouterUrl,
          customModel: 'm',
          customThinkingIntensity: AiThinkingIntensity.max,
        ),
        prompts: prompts(system: 'sys'),
        apiKey: 'k',
        stream: true,
      );
      final Object? decoded = jsonDecode(request.encodeBody());
      expect(decoded, isA<Map<String, Object?>>());
      final Map<String, Object?> body = decoded! as Map<String, Object?>;
      expect(body['stream'], isTrue);
      expect((body['messages']! as List<Object?>), hasLength(2));
      expect(body['reasoning'],
          <String, Object?>{'effort': 'xhigh', 'exclude': true});
    });

    test('preserves Unicode prompts', () {
      final AiHttpRequest request = AiRequestBuilder.buildOpenAi(
        config: const AiProviderConfig(),
        prompts: AiPromptRenderer.render(
            userTemplate: '{{target}} / {{sentence}}',
            systemTemplate: '',
            target: '猫',
            sentence: '猫が好きです。🐱'),
        apiKey: 'k',
        stream: false,
      );
      final Map<String, Object?> body =
          jsonDecode(request.encodeBody())! as Map<String, Object?>;
      final Map<String, Object?> message =
          (body['messages']! as List<Object?>).single as Map<String, Object?>;
      expect(message['content'], '猫 / 猫が好きです。🐱');
    });
  });
}
