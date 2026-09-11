/// Executes AI explanation requests.
///
/// Ported from the reference extension's request execution
/// (`js/comm/ai-provider.js:390-435` and the per-provider `generateExplanation`
/// methods, GPL-3.0, Copyright (C) 2023-2025 Yomitan Authors). See
/// `docs/agent/ai-explanation.md` §5.3 and §5.6.
///
/// This layer knows about HTTP and nothing about widgets. It does not own
/// cache, dedup, timeouts or the non-streaming fallback — those belong to the
/// repository above it, because they are policy rather than transport.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/ai/ai_gemini_request.dart';
import 'package:fushi/src/ai/ai_prompt_renderer.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_request_builder.dart';
import 'package:fushi/src/ai/ai_response_parser.dart';
import 'package:fushi/src/ai/ai_sse_parser.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

/// A provider-side failure, already sanitised for display.
///
/// [providerMessage] is text the provider authored. It is shown to the user, so
/// nothing sensitive may ever be concatenated into it: no Authorization header,
/// no request body, no full Gemini URL.
class AiProviderException implements Exception {
  const AiProviderException({
    required this.providerLabel,
    this.statusCode,
    this.providerMessage,
  });

  final String providerLabel;
  final int? statusCode;
  final String? providerMessage;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('$providerLabel API error');
    if (statusCode != null) buffer.write(' ($statusCode)');
    if (providerMessage != null && providerMessage!.isNotEmpty) {
      buffer.write(': $providerMessage');
    }
    return buffer.toString();
  }
}

/// Builds and executes one request per provider.
class AiExplanationClient {
  /// [clientFactory] exists for tests, which point it at a loopback server —
  /// the pattern `MokuroMoeClient` already uses in this repo.
  ///
  /// Production callers leave it null and get `createAppHttpIoClient()`, which
  /// is the app-wide outbound assembly point: it applies the user's proxy and
  /// forces DIRECT for loopback and LAN targets, so a self-hosted endpoint keeps
  /// working. A bare `http.Client()` here would fail
  /// `fushi/test/tools/outbound_http_discipline_guard_test.dart`.
  AiExplanationClient({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? createAppHttpIoClient;

  final http.Client Function() _clientFactory;

  /// A fresh client per request, closed when the request ends.
  ///
  /// Deliberate: closing the client is what tears down an in-flight connection,
  /// and an AI explanation is at most one request per lookup against a
  /// multi-second inference call, so the construction cost is noise next to the
  /// round trip. Sharing one client would mean a cancel could only be done by
  /// closing it — which would abort every other request using it.
  http.Client _newClient() => _clientFactory();

  /// Builds the request for [config] without sending it.
  ///
  /// Exposed so the repository can derive a cache key and so tests can assert
  /// the wire format, and so a configuration error surfaces before any network
  /// call is made.
  AiHttpRequest buildRequest({
    required AiProviderConfig config,
    required AiRenderedPrompts prompts,
    required String apiKey,
    required bool stream,
  }) {
    switch (config.provider) {
      case AiProvider.openai:
        return AiRequestBuilder.buildOpenAi(
            config: config, prompts: prompts, apiKey: apiKey, stream: stream);
      case AiProvider.gemini:
        return AiGeminiRequestBuilder.build(
            config: config, prompts: prompts, apiKey: apiKey, stream: stream);
      case AiProvider.deepseek:
        return AiRequestBuilder.buildDeepSeek(
            config: config, prompts: prompts, apiKey: apiKey, stream: stream);
      case AiProvider.custom:
        return AiRequestBuilder.buildCustom(
            config: config, prompts: prompts, apiKey: apiKey, stream: stream);
    }
  }

  /// Human-readable provider name used in error messages.
  static String labelFor(AiProvider provider) {
    switch (provider) {
      case AiProvider.openai:
        return 'OpenAI';
      case AiProvider.gemini:
        return 'Gemini';
      case AiProvider.deepseek:
        return 'DeepSeek';
      case AiProvider.custom:
        return 'Custom';
    }
  }

  /// Performs a single non-streaming request and returns the answer text.
  ///
  /// May return an empty string when the provider answered with no content; the
  /// caller decides what to display, so the "no explanation" wording can go
  /// through i18n.
  Future<String> generate({
    required AiProviderConfig config,
    required AiRenderedPrompts prompts,
    required String apiKey,
    Future<void>? abortSignal,
  }) async {
    final AiHttpRequest built = buildRequest(
        config: config, prompts: prompts, apiKey: apiKey, stream: false);
    final String label = labelFor(config.provider);
    final http.Client client = _newClient();
    bool closed = false;
    void closeOnce() {
      if (closed) return;
      closed = true;
      client.close();
    }

    // Closing the client mid-flight is what aborts a non-streaming request:
    // there is no other way to stop one, and without it "close the popup" would
    // leave the provider generating an answer nobody will read — and billing
    // for it.
    unawaited(abortSignal?.whenComplete(closeOnce) ?? Future<void>.value());
    try {
      final http.Response response = await client.post(
        Uri.parse(built.url),
        headers: built.headers,
        // Encode explicitly: the default would pick a charset from the headers
        // and mangle non-ASCII prompts.
        body: utf8.encode(built.encodeBody()),
      );
      final String text = utf8.decode(response.bodyBytes, allowMalformed: true);
      final Object? decoded = _tryDecode(text);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiProviderException(
          providerLabel: label,
          statusCode: response.statusCode,
          providerMessage:
              AiResponseParser.extractErrorMessage(decoded) ?? _clip(text),
        );
      }

      // Some providers answer 200 with an error object in the body.
      final String? embedded = AiResponseParser.extractErrorMessage(decoded);
      if (embedded != null) {
        throw AiProviderException(
            providerLabel: label, providerMessage: embedded);
      }

      if (config.provider == AiProvider.gemini) {
        return AiResponseParser.extractGeminiText(decoded).trim();
      }
      return AiResponseParser.extractOpenAiMessage(decoded).trim();
    } finally {
      closeOnce();
    }
  }

  /// Performs a streaming request, yielding incremental text deltas.
  ///
  /// Cancelling the subscription aborts the request: the `finally` closes the
  /// client, which tears down the connection so the provider stops generating
  /// tokens nobody will read.
  ///
  /// Deltas are yielded, not the accumulated answer — the repository
  /// accumulates, so a late chunk from a superseded request cannot overwrite the
  /// popup with a whole stale answer.
  Stream<String> generateStream({
    required AiProviderConfig config,
    required AiRenderedPrompts prompts,
    required String apiKey,
    Future<void>? abortSignal,
  }) async* {
    final AiHttpRequest built = buildRequest(
        config: config, prompts: prompts, apiKey: apiKey, stream: true);
    final String label = labelFor(config.provider);
    final bool isGemini = config.provider == AiProvider.gemini;
    final http.Client client = _newClient();
    bool closed = false;
    void closeOnce() {
      if (closed) return;
      closed = true;
      client.close();
    }

    unawaited(abortSignal?.whenComplete(closeOnce) ?? Future<void>.value());
    try {
      final http.Request request = http.Request('POST', Uri.parse(built.url))
        ..headers.addAll(built.headers)
        ..bodyBytes = utf8.encode(built.encodeBody());
      final http.StreamedResponse response = await client.send(request);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final String text = await response.stream.bytesToString();
        throw AiProviderException(
          providerLabel: label,
          statusCode: response.statusCode,
          providerMessage:
              AiResponseParser.extractErrorMessage(_tryDecode(text)) ??
                  _clip(text),
        );
      }

      final AiSseParser parser = AiSseParser();
      bool finished = false;
      AiProviderException? streamError;

      // Emits the deltas of one SSE payload, or records a terminal condition.
      Iterable<String> handle(String payload) sync* {
        if (finished) return;
        // Gemini never sends the sentinel; checking for it costs nothing and
        // keeps one code path for both families.
        if (payload == '[DONE]') {
          finished = true;
          return;
        }
        final Object? parsed = _tryDecode(payload);
        // Keep-alive frames and non-JSON padding are not fatal.
        if (parsed == null) return;

        final String? error = AiResponseParser.extractErrorMessage(parsed);
        if (error != null) {
          streamError =
              AiProviderException(providerLabel: label, providerMessage: error);
          finished = true;
          return;
        }

        final String delta = isGemini
            ? AiResponseParser.extractGeminiText(parsed)
            : AiResponseParser.extractOpenAiStreamDelta(parsed);
        if (delta.isNotEmpty) yield delta;
      }

      await for (final String chunk
          in response.stream.transform(utf8.decoder)) {
        for (final String payload in parser.addChunk(chunk)) {
          for (final String delta in handle(payload)) {
            yield delta;
          }
        }
      }
      for (final String payload in parser.close()) {
        for (final String delta in handle(payload)) {
          yield delta;
        }
      }

      // Thrown only after the stream is fully drained, matching the reference:
      // an error frame mid-stream must not discard text that already arrived.
      final AiProviderException? pending = streamError;
      if (pending != null) throw pending;
    } finally {
      closeOnce();
    }
  }

  /// Decodes JSON, returning null rather than throwing.
  static Object? _tryDecode(String source) {
    if (source.trim().isEmpty) return null;
    try {
      return jsonDecode(source);
    } on FormatException {
      return null;
    }
  }

  /// Bounds an unparseable error body before it reaches the UI.
  ///
  /// A provider that answers with an HTML error page would otherwise put a
  /// whole document into a popup.
  static String _clip(String text) {
    final String trimmed = text.trim();
    if (trimmed.length <= 300) return trimmed;
    return '${trimmed.substring(0, 300)}...';
  }
}
