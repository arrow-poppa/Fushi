# BYOK AI Explanation

> Sub-document of [CLAUDE.md](../../CLAUDE.md). Read this in full before modifying any
> AI-explanation code. Update it whenever an architectural decision, a permanent
> requirement, or an observable contract of the feature changes.
>
> Written in English (like `README.md`, `fushi/lib/src/utils/net/README.md` and
> `DESIGN.md`) because the reference implementation, the provider wire formats and
> the upstream licence headers are all English; the parity tables quote them verbatim.

## 1. Objective

Port **only** the AI Explanation feature of the local Yomitan fork
(`yomitan-chrome-26.8.24.0-ai`) into Fushi, as a **BYOK** (bring-your-own-key)
capability: the user supplies their own provider credentials and every request goes
**directly from the user's device to the provider they configured**. There is no
Fushi-operated proxy, relay or key escrow in the path.

The explanation is shown inside the **existing** dictionary popup, next to normal
dictionary results.

## 2. Scope

- A testable Dart layer (config, prompt rendering, provider clients, SSE streaming,
  cache, cancellation, controller).
- Four providers: OpenAI, Google Gemini, DeepSeek, Custom (OpenAI-compatible,
  including OpenRouter).
- An "AI Integration" settings section following the existing schema-based settings
  system.
- Popup rendering of all explanation states, with selectable/copyable text.
- A synthetic `AI Fallback` result for words no dictionary matched.
- Anki interop: `{popup-selection-text}` must work inside the explanation, plus an
  additive `{ai-explanation}` marker.

## 3. Non-objectives

- **Not** turning Fushi into a Yomitan clone. The reader, parser, UI, dictionary
  system, OCR, video, manga, audio and Anki integration stay as they are, except for
  the strictly necessary extensions listed here.
- **No** C++ / `fushidicts` engine changes. Providers, prompts, cache, streaming and
  cancellation live in Dart. The fallback entry is synthesised in Dart and never
  written into the `fushidicts` index.
- **No** Fushi-operated inference proxy, and no bundled/default API key.
- **Not** porting Yomitan's settings page, options schema, structured-content
  generator or display pipeline. Only observable behaviour is ported.

## 4. Reference baseline

| Item | Value |
|---|---|
| Reference tree | `yomitan-chrome-26.8.24.0-ai` (read-only; not a git repo) |
| Reference options schema version | 81 |
| Fushi base branch | `develop` |
| Fushi base commit | `cda13c620c293b22f76df363752bde119ae074f8` (2026-09-10, `2.4.0+1316`) |

Reference files (all GPL-3.0, `Copyright (C) 2023-2025/2026 Yomitan Authors`):

| File | Lines | Role |
|---|---|---|
| `js/comm/ai-provider.js` | 1266 | Provider classes, factory, SSE reader, reasoning/routing/body merge |
| `js/display/ai-explanation-generator.js` | 465 | Orchestration, cache, timeout, cancellation, states |
| `js/pages/settings/ai-controller.js` | 600 | Settings UI controller |
| `js/language/ai-fallback-util.js` | 118 | Unknown-word tokeniser + language gate |
| `js/display/display.js`, `display-generator.js` | — | Box insertion, streaming DOM update, cancel triggers |
| `js/language/translator.js` | — | Synthetic fallback dictionary entry |

## 5. Parity matrix

Legend for **Strategy**: `port` = reproduce observable behaviour; `adapt` = same intent,
Fushi-idiomatic mechanism; `diverge` = deliberate difference (always justified in §8).

### 5.1 Settings

| Feature | Yomitan source | Observable behaviour | Yomitan setting | Fushi equivalent | Strategy | Tests | Status |
|---|---|---|---|---|---|---|---|
| Provider choice | `settings.html:2473` | 4 options; switching reveals that provider's fields | `ai.provider` enum `openai\|gemini\|deepseek\|custom`, default `openai` | pref `ai_explain_provider`; `SettingsSegmentedItem`/navigation | port | unit | todo |
| Auto generate on lookup | `settings.html:2499` | off ⇒ box shows manual state, **no request** | `ai.autoGenerateOnLookup`, default `true` | `ai_explain_auto_generate` | port | unit+widget | todo |
| Real time response | `settings.html:2521` | streams into the popup | `ai.streamResponse`, default `false` | `ai_explain_stream` | port | unit | todo |
| Cancel unfinished requests | `settings.html:2549` | abort on close / new lookup / hide | `ai.cancelPendingRequests`, default `true` | `ai_explain_cancel_pending` | port | unit | todo |
| Fallback for unknown words | `settings.html:2580` | opens popup for words in no dictionary | `ai.unknownWordFallback`, default `false` | `ai_explain_unknown_fallback` | adapt (§8.5) | unit | todo |
| Custom prompt | `settings.html:2602` | user prompt template | `ai.customPrompt`, default = §5.2 | `ai_explain_prompt` | port | unit | todo |
| System prompt | `settings.html:2625` | optional system message | `ai.systemPrompt`, default `""` | `ai_explain_system_prompt` | port | unit | todo |
| Temperature | `settings.html:2650` | clamp `[0,2]`, default `0.7`, `,`→`.` | `ai.temperature` | `ai_explain_temperature` (double) | port | unit | todo |
| OpenAI key / model | `settings.html:2670,2693` | key + model dropdown | `ai.openai.{apiKey,model}`, model default `gpt-4o-mini` | `ai_explain_openai_api_key`, `ai_explain_openai_model` | port | unit | todo |
| Gemini key / model / thinking | `settings.html:2718,2741,2776` | key, 11 models, 5 thinking levels | `ai.gemini.{apiKey,model,thinkingLevel}` | `ai_explain_gemini_*` | port | unit | todo |
| DeepSeek key / model / thinking | `settings.html:2805,2828,2850,2876` | free-text model, mode + intensity | `ai.deepseek.{apiKey,model,thinkingMode,thinkingIntensity}` | `ai_explain_deepseek_*` | port | unit | todo |
| Custom endpoint/key/model | `settings.html:2902,2924,2946` | full URL used verbatim | `ai.custom.{endpoint,apiKey,model}` | `ai_explain_custom_*` | port | unit | todo |
| OpenRouter routing | `settings.html:2968,2995,3017` | `order`/`only`/`ignore` + `allow_fallbacks` | `ai.custom.{providerRoutingMode,providerSlugs,providerAllowFallbacks}` | `ai_explain_custom_routing_*` | port | unit | todo |
| Custom thinking | `settings.html:3039,3065,3091` | mode + intensity + custom value | `ai.custom.{thinkingMode,thinkingIntensity,customThinkingIntensity}` | `ai_explain_custom_thinking_*` | port | unit | todo |
| Custom request body JSON | `settings.html:3115` | deep-merged override | `ai.custom.requestBodyJson` | `ai_explain_custom_body_json` | port | unit | todo |

### 5.2 Prompt

Default user prompt (verbatim, identical in `options-schema.json:1399`,
`options-util.js:1881`, `ai-controller.js:204`):

```
Explain the meaning of '{{target}}' in the following sentence: '{{sentence}}'. Provide a concise explanation focusing on the word's usage and meaning in this specific context.
```

| Feature | Yomitan source | Behaviour | Strategy | Status |
|---|---|---|---|---|
| Placeholders | `ai-provider.js:69-73` | exactly `{{target}}` and `{{sentence}}`, case-sensitive, **global** replace, `{{target}}` substituted first | port | todo |
| System prompt substitution | `ai-provider.js:306-315` | placeholders also applied to the system prompt | port | todo |
| Empty system prompt | `ai-provider.js:482-489` | omit the `system` message entirely | port | todo |
| Empty user prompt | `ai-explanation-generator.js:162` | sends `content: ""` unguarded | diverge (§8.1) | todo |
| `$`-sequences | JS `String.replace` semantics | `$&`, `` $` ``, `$'`, `$1` in the term/sentence act as replacement patterns | diverge (§8.2) | todo |

### 5.3 Provider request contracts

| Provider | Endpoint | Auth | Body | Stream flag | Response paths read | Ignored |
|---|---|---|---|---|---|---|
| OpenAI | `https://api.openai.com/v1/chat/completions` (hardcoded) | `Authorization: Bearer <key>` | `{model, messages, temperature}` | `stream:true` added only on the streaming path | `choices[0].message.content` | — |
| Gemini | `…/v1beta/models/{id}:{generateContent\|streamGenerateContent}?key=` or Vertex `aiplatform…/v1/publishers/google/models/…` | **key in query string** | `{contents:[{parts:[{text}]}], generationConfig:{temperature[, thinkingConfig]}}` (+`systemInstruction`) | `?alt=sse` | stream: all parts, skipping `part.thought===true`; non-stream: `candidates[0].content.parts[0].text` | thought parts (stream only) |
| DeepSeek | `https://api.deepseek.com/chat/completions` (**no `/v1`**) | `Bearer <key.trim()>` | `{model, messages, stream, temperature}` + `thinking`/`reasoning_effort` | explicit `stream` field | `choices[0].message.content` | `reasoning_content` |
| Custom | `ai.custom.endpoint` **verbatim, nothing appended** | `Bearer <key.trim()>` (+OpenRouter headers) | `{model, messages, temperature}` → reasoning → provider routing → deep-merge custom JSON | `stream=true` set **after** the merge | `choices[0].message.content` → `choices[0].text`, array parts joined | `reasoning`, `reasoning_content` |

`messages` shape — with a system prompt:
`[{role:"system",content:SYS},{role:"user",content:USER}]`; without: `[{role:"user",content:USER}]`.
**A request is never sent without `messages`.**

### 5.4 OpenRouter reasoning mapping (`ai-provider.js:101-156`)

Guard: if neither thinking mode nor effective intensity is set, **nothing** is added.

| Mode | Intensity | Custom value | Resulting `reasoning` |
|---|---|---|---|
| `disabled` | any | any | `{effort:'none', exclude:true}` |
| `''`/`enabled` | `custom` | `/^\d+$/` | `{max_tokens:<int>, exclude:true}` |
| `''`/`enabled` | `custom` | valid JSON object | `{...parsed, exclude:true}` |
| `''`/`enabled` | `custom` | `{`-prefixed but invalid / array | `{effort:'<raw>', exclude:true}` |
| `''`/`enabled` | `custom` | `max` | `{effort:'xhigh', exclude:true}` |
| `''`/`enabled` | `custom` | other text | `{effort:'<text>', exclude:true}` |
| `''`/`enabled` | `high` | — | `{effort:'high', exclude:true}` |
| `''`/`enabled` | `max` | — | `{effort:'xhigh', exclude:true}` |
| `enabled` | `''` | — | `{enabled:true, exclude:true}` |
| `''` | `''` | — | *(nothing)* |

`reasoning.exclude` is set **unconditionally** after the merge, so internal thinking is
never surfaced. Non-OpenRouter endpoints instead get `thinking:{type:<mode>}` and
`reasoning_effort:<intensity>` (and `max` is **not** rewritten to `xhigh` there).

Provider routing: slugs split on `/[\n,]+/`, trimmed, empties dropped. `order`/`only`/
`ignore` per mode; `allow_fallbacks` always appended when it is a boolean — so every
OpenRouter request carries at least `provider:{allow_fallbacks:true}`.

### 5.5 Custom request body JSON (`ai-provider.js:162-193`)

- Accepts a JSON **object** only. Array, `null`, scalar or invalid JSON ⇒ throw
  **before** any network call.
- Merge is **deep/recursive** for plain objects; arrays replace wholesale; `null`
  overwrites (does not delete).
- Custom values win over `model`, `messages`, `temperature`, `reasoning`, `thinking`,
  `provider`.
- `stream` is controlled by the app: the streaming path assigns `stream = true`
  **after** the merge, so a stored `"stream": false` cannot disable streaming.
- Auth headers are never overridable by the custom body.

### 5.6 Streaming (`ai-provider.js:325-435`)

| Aspect | Behaviour |
|---|---|
| Event separators | `\r\n\r\n`, `\n\n`, `\r\r` |
| Line splitting | `\r\n`, `\n`, `\r` |
| Kept lines | only those starting with `data:`; exactly one leading space stripped |
| Multiple `data:` lines | joined with `\n` |
| Comments / `event:` / `id:` / keep-alives | dropped; an event with no `data:` line never fires the callback |
| `[DONE]` | strict equality on the joined payload ⇒ finish; everything after is discarded |
| Malformed JSON payload | silently ignored (not fatal) |
| In-stream `error` | recorded, stream drained, then thrown |
| Termination without trailing blank line | residual buffer emitted if non-empty after trim |
| Split multi-byte UTF-8 | incremental decoder with a final flush |
| Delta path | `choices[0].delta.content`, else `choices[0].text`; `delta.reasoning_content` ignored |
| Non-streaming fallback | retried once, only when nothing arrived and the request is still wanted — see §5.6.1 |

### 5.6.1 Non-streaming fallback — replicated exactly

Reference: `ai-explanation-generator.js:192-207`. When `generateExplanationStream`
throws, the request is retried **once** as a normal non-streaming call, but **only if
all four of these are false**:

| Guard | Meaning | If true |
|---|---|---|
| `receivedLength > 0` | at least one chunk already reached the display | rethrow — never silently re-request |
| `pending.cancelled` | superseded or cancelled | rethrow |
| `timedOut` | the 30 s inactivity timeout fired | rethrow |
| `error.name === 'AbortError'` | the abort signal fired | rethrow |

Verbatim:

```js
if (receivedLength > 0 || pending.cancelled || timedOut || streamError?.name === 'AbortError') {
    throw error;
}
console.warn('AI streaming failed, falling back to a single response:', error);
armRequestTimeout();
explanation = await provider.generateExplanation(term, sentence, promptTemplate, systemPrompt, abortController.signal);
```

Exact semantics to preserve in Dart:

- **Retried at most once.** There is no loop and no second retry; if the non-streaming
  call also fails, that error propagates to the normal error handling.
- **The 30 s timeout is re-armed before the retry** (`armRequestTimeout()`), so the
  retry gets a full fresh window rather than inheriting the streaming attempt's budget.
- **`receivedLength` is only ever assigned inside `onChunk`**, which itself early-returns
  when the request was already superseded. So a chunk that arrived for a stale request
  does **not** count as "text received" and does not block the retry.
- **This is the only automatic retry in the feature.** No other path re-issues a
  request, which is what keeps BYOK billing predictable.
- The fallback is unreachable when streaming is off, and unreachable when the provider
  reports it cannot stream (all four providers report that they can).

Status: **port (exact)**.

### 5.7 Cache, concurrency, cancellation

| Aspect | Yomitan | Fushi |
|---|---|---|
| Cache TTL | 60 000 ms | same |
| Cache key | `JSON.stringify([profileIndex, term, sentence])` — **omits provider/model/prompt/temperature** | **diverge (§8.3)**: include profile, provider, model, prompt, system prompt, temperature |
| Errors cached | no | no |
| Partial cancelled answers cached | no | no |
| Inactivity timeout | 30 000 ms, re-armed on every chunk, aborts the request | same |
| Timeout vs cancel | distinct: timeout renders a message, cancel renders nothing | same |
| Dedup | same key in flight ⇒ re-render does not restart it | same |
| Regenerate | deletes the cache entry, then forces a restart | same |
| Stale-response guard | pending-map object identity + display-side term comparison | request token/identity; a result applies only if still current |
| Cancel triggers (when enabled) | new lookup, popup hidden, `pagehide` | popup dismissed, new lookup, surface hidden/destroyed |
| `contentClear` | removes the node, **does not** cancel | same |
| Cancel disabled | request finishes into the cache, cannot paint another word | same |

### 5.8 Unknown-word fallback (`ai-fallback-util.js`, `translator.js:1869-1905`)

| Aspect | Yomitan |
|---|---|
| Virtual dictionary name | `AI Fallback` |
| Excluded languages | `ja, zh, zh-Hans, zh-Hant, yue, th, lo, km, my, bo` |
| Tokeniser | leading run of `[\p{L}\p{M}\p{N}'’-]`, edge separators trimmed, must contain a `\p{L}` |
| Entry | empty glossary, `id=-1`, `sequence=[-1]`, reading = term, `isPrimary`, dictionary registered **after** the DB search |
| Trigger | only after both term and kanji lookups returned nothing |
| Anchoring | scan re-anchored to the **start of the word** so every character of a word yields the same token |

**Fushi consequence:** Yomitan excludes `ja`, and `fushi_dictionary` pins
`targetLanguage` to Japanese — a literal port would ship a permanently dead feature.
See §8.5.

## 6. Architecture

All AI code is Dart-side, under `fushi/lib/src/ai/`. Nothing enters `native/fushidicts/`.

```
AiProviderConfig        immutable value object; provider + model + prompt knobs.
                        Credentials are NOT fields on it (see §9).
AiExplanationRequest    {target, sentence, config, requestId}
AiExplanationResult     sealed: Idle | Manual | Loading | Streaming(text) |
                        Done(text) | Failed(reason) | TimedOut | Cancelled |
                        NotConfigured
AiPromptRenderer        placeholder substitution only. Knows nothing about HTTP or UI.
AiExplanationClient     builds + executes requests per provider; returns a single
                        result or a Stream<String> of deltas. Knows nothing about
                        widgets. Takes an injected `http.Client` factory for tests.
AiSseParser             incremental SSE decoder (§5.6). Pure; no I/O.
AiExplanationCache      bounded, 60 s TTL, key per §8.3.
AiExplanationRepository cache + dedup + 30 s inactivity timeout + cancellation +
                        stale-response rejection.
AiExplanationController popup-facing state; auto/manual generation, regenerate,
                        cancel; bound to the lookup lifecycle.
AiCredentialStore       reads/writes API keys; device-local (§9).
```

**Dart owns the request state.** The WebView only renders states, forwards chunks
into one text node, and emits `regenerate` / `cancel` / `export` intents. No duplicated
state machine in JS.

### 6.1 Fushi integration points (verified at `cda13c62`)

| Concern | File:line |
|---|---|
| Lookup engine | `fushi/lib/src/models/app_model.dart:5649` `searchDictionary` |
| Result → JS payload | `fushi/lib/src/pages/implementations/popup_settings_injection.dart:468` `buildPopupEntriesJs` |
| Payload push | `dictionary_popup_webview.dart:1159` `_pushResults` |
| Dart↔JS bridge | `dictionary_popup_webview.dart` — 27 `addJavaScriptHandler` registrations |
| Popup DOM builder | `fushi/assets/popup/popup.js:5229` `renderPopup` |
| Warm WebView slot | `base_source_page.dart:99` `_seedWarmPopup`; `dictionary_popup_controller.dart:306` `beginTop(reuseWarmSlot:)` |
| Selection snapshot | `fushi/assets/popup/popup.js:1179` `snapshotSelection`, wired at `:3517` (`onpointerdown`) and `:3523` (`ontouchstart`) |
| Anki markers | `packages/fushi_anki/lib/src/anki_models.dart:1053` `coreOptions`; renderer switch at `:881` |
| Selection-vs-`<mark>` rule | `packages/fushi_anki/lib/src/base_anki_repository.dart:695` `shouldYieldSelectionText` |
| Preference keys registry | `fushi/lib/src/models/preference_keys.dart` `kKnownPreferenceKeys` |
| Preference getters | `fushi/lib/src/models/preferences_repository.dart` |
| Settings schema | `fushi/lib/src/settings/settings_schema_*.dart`; secret fields via `SettingsTextItem(secret: true)` |
| Redaction policy | `fushi/lib/src/sync/pref_redaction_policy.dart:109` `isDeviceLocalOrCredential` |
| Profile exclusion | `fushi/lib/src/profile/profile_keys.dart:155` (delegates to the policy) |
| Outbound HTTP | `packages/fushi_engine/lib/utils/net/app_http.dart:63` `createAppHttpIoClient` |
| i18n | `fushi/tool/i18n_sync.dart`, 17 files under `fushi/lib/i18n/` |

### 6.2 Sentence context per surface

Verified carriers; surfaces without context pass `''` (never invalid JSON):

| Surface | Sentence? | Carrier |
|---|---|---|
| EPUB reader | yes | `snapshotCueSentence`, `fushiSelection.getSentenceContext` |
| PDF reader | yes | `_lastSentence` via `extractSentenceAt` |
| Manga / OCR | yes | `_lastSentence` |
| Video subtitles | yes | `_lastLookupSentence`, merged multi-cue `mergedSentence` |
| Web video | yes | page cue text |
| Texthooker | yes | `_activeSentence` |
| Floating lyric | yes | host lyric line |
| Global lookup (desktop) | yes | `_currentSentence` via `extractSentenceAt` |
| Galgame overlay | yes | `sentenceContext` |
| Home Dictionary tab | **no** | — |
| Floating dict window | **no** | hardcoded `sentence: ''` |
| Nested popup | **no** | child inherits nothing |

`fields['sentence']` is **not** emitted by `popup.js` (`buildMinePayload` never sets it);
hosts inject it Dart-side. The AI layer therefore takes the sentence from the Dart host
context, not from the WebView.

## 7. Permanent decisions

1. **No C++ changes.** The synthetic fallback entry is built in Dart. Leaving
   `DictionarySearchResult.popupJson` null makes `buildPopupEntriesJs` fall through to
   the pure-Dart grouper `buildLookupEntriesJson` — verified, no FFI involved.
2. **Dart is the single source of request state.** JS renders and emits intents only.
3. **Outbound HTTP must go through `createAppHttpIoClient()`.** A bare
   `HttpClient()`/`http.Client()` fails the CI guard
   `fushi/test/tools/outbound_http_discipline_guard_test.dart` (sentinel
   `kRegisteredOutboundFileCount = 21`).
4. **Credentials never travel.** Registered in `PrefRedactionPolicy`, which is the
   single predicate consumed by backup, profile snapshot and profile sharing.
5. **Behaviour preferences follow profiles; credentials do not.**
6. **The feature is inert when disabled.** No client construction, no parser
   allocation, no network work on a normal lookup with AI off.
7. **The popup WebView is never recreated for AI.** The warm slot and parked realms
   are preserved; streaming updates one text node.
8. **`{popup-selection-text}` semantics are unchanged.** `{ai-explanation}` is purely
   additive.
9. **i18n only via `fushi/tool/i18n_sync.dart`**, then `dart run slang`. Never hand-edit
   the 17 JSON files or `strings.g.dart`.

## 8. Deliberate divergences from the reference

Each item states the reference behaviour, the Fushi behaviour and the reason.

### 8.1 Never send an empty user message
Yomitan sends `content: ""` when the custom prompt is empty. Fushi falls back to the
default prompt template when the rendered user prompt is blank. Reason: the user's
explicit requirement that a request is never sent without valid input, and several
gateways reject empty content with `Input required: specify "prompt" or "messages"`.

### 8.2 Literal placeholder substitution
JS `String.replace` with a string replacement interprets `$&`, `` $` ``, `$'` and `$1`
inside the *replacement*. A term or sentence containing `$&` is therefore mangled by
the reference. Dart's `replaceAll` is literal, which is the correct behaviour; we keep
Dart semantics and pin it with a test.

### 8.3 Cache key includes the full generation context
The reference keys on `[profileIndex, term, sentence]` only, so changing model or
prompt returns a stale answer for up to 60 s. Fushi keys on profile + provider + model
+ target + sentence + user prompt + system prompt + temperature, per the explicit
requirement that a response generated with a different prompt or model is never reused.

### 8.4 Safe OpenRouter host detection
The reference uses `hostname.endsWith('openrouter.ai')`, which also matches
`evil-openrouter.ai` and would send the Bearer token and identifying headers to it.
Fushi requires `host == 'openrouter.ai' || host.endsWith('.openrouter.ai')`.

### 8.5 Unknown-word fallback and Japanese
The reference disables the fallback for `ja, zh, zh-Hans, zh-Hant, yue, th, lo, km, my,
bo` because its tokeniser takes a leading run of letters and, with no spaces, would
swallow an entire clause. Fushi's lookup is **not** a leading-letter tokeniser: the host
already supplies a bounded scan window and the popup already knows the selected range,
so the failure mode the exclusion protects against does not exist here.

Since Fushi pins `targetLanguage` to Japanese, importing the exclusion list verbatim
would ship a permanently dead feature. Fushi therefore derives the fallback term from
**the host's existing selection/scan window**, not from a space-based tokeniser, and the
full selected word is preserved — never reduced to a partially matched prefix. The
space-based tokeniser is kept only as the degenerate path for surfaces that provide a
raw text buffer with no bounded selection.

### 8.6 Identifying headers
The reference sends `HTTP-Referer: https://yomitan.wiki/` and
`X-OpenRouter-Title: Yomitan`. Fushi must not claim to be Yomitan, and
`X-OpenRouter-Title` is not even the header OpenRouter documents (`X-Title` is). Fushi
sends Fushi-identifying values and never puts personal data in the referer.

### 8.7 Gemini non-streaming thought parts
The reference's non-streaming Gemini path reads `parts[0].text` only and does not check
`part.thought`, so a thinking model can return its thought text. Fushi applies the same
thought-skipping filter on both paths.

### 8.8 States rendered but not reachable in the reference
The reference has no user-facing cancel control and its intermediate regenerate button
has no click listener. Fushi exposes an explicit cancel action while a request is in
flight, as required.

## 9. Credential security

- API keys are **device-local**. They are never included in backup archives, profile
  snapshots, profile sharing JSON, sync payloads or error reports.
- Registration point: `sensitiveKeys` in
  `fushi/lib/src/sync/pref_redaction_policy.dart`. Every AI credential key is **also**
  named explicitly there even though the `api_key` substring rule already matches it —
  that is the file's stated convention, so an auditor sees the full list at a glance.
- `ai_explain_custom_endpoint` and `ai_explain_custom_body_json` are registered too:
  an endpoint can carry a query credential and the body JSON can embed a key, and
  neither name matches a credential shape.
- Never logged: Authorization headers, bearer tokens, full request bodies, full Gemini
  URLs (Gemini puts the key in the query string).
- Provider error text is sanitised before it reaches the UI or any log.
- **Storage reality:** the repo has **no** `flutter_secure_storage`/keychain/keystore
  usage anywhere. Secrets today are plaintext rows in the Drift `preferences` table,
  protected only by the redaction policy at export time. The AI keys follow that same
  existing model. This is a **known limitation**, recorded in §13 — base64 is not
  encryption and must never be described as such.

## 10. Popup integration

States: not configured, auto-generation disabled (manual), loading, streaming, done,
error, timeout, cancelled.

Actions: generate, regenerate, cancel (while in flight), select, copy, export via the
existing Anki flow.

Requirements:
- Text is genuinely selectable; copy works on Android and the supported desktops.
- A partial selection exports exactly that part.
- Selection is captured on pointer-down/touch-start **before** the Anki button changes
  focus — reuse the existing `snapshotSelection()` mechanism rather than inventing one.
- The explanation must not overlay or block the audio, Anki, favourite or navigation
  buttons, and must not introduce floating arrows over them.
- Normal popup scrolling is preserved.
- Streaming updates only the explanation text node; no full DOM rebuild, no flicker,
  no loss of selection; visual updates are throttled if needed.

## 11. Anki integration

- `{popup-selection-text}` must keep working for normal definitions **and** inside the
  AI explanation, exporting only the selected fragment, never the popup's HTML/CSS.
- Behaviour is identical for create and overwrite/update, on AnkiDroid and AnkiConnect.
- `{glossary}`, `{glossary-first}`, `{selected-glossary}` and the `<mark>` highlight
  logic are untouched, as is image and audio handling.
- An `AI Fallback` result is minable even without a dictionary definition.
- `{ai-explanation}` is additive: it exports only the **final** answer, never loading or
  error text. It does not alter `{popup-selection-text}` semantics.

## 12. Testing

Prompts: `{{target}}`, `{{sentence}}`, repeated occurrences, system prompt, empty
prompt, Unicode, empty context, `$`-sequences.

Requests: each provider; OpenRouter routing modes; `allow_fallbacks`; thinking
enabled/disabled/high/max-xhigh; custom intensity textual/numeric/JSON; custom body
deep merge; invalid JSON rejected; `messages` always present; `stream` not disableable
from the custom body.

Streaming: fragmented SSE chunks, multiple `data:` lines, LF, CRLF, keep-alives,
`[DONE]`, termination without a final separator, invalid payload, in-stream error,
non-streaming fallback, no fallback after text arrived, cancellation, timeout re-armed
by a chunk.

Concurrency: stale response, two fast lookups, popup close, cancel on/off, cache hit,
expiry, regeneration, provider/model/prompt change invalidating the key.

Popup: every visual state, manual generation, regenerate, cancel, partial selection,
copy, selection preserved during streaming, buttons not overlaid, warm popup preserved.

Fallback: no dictionary result, synthetic entry, audio, Anki, sentence, full expression,
space-separated languages, CJK, fallback off, coexistence with a real result.

Anki: `{popup-selection-text}` with a normal dictionary and with the AI explanation,
partial selection, no selection, `AI Fallback` result, create, overwrite/update,
AnkiDroid, AnkiConnect, audio and image preserved, no accidental HTML/CSS export.

Security: key absent from backup, profile snapshot, profile sharing, logs,
serialisation and exception text; errors sanitised.

JS behaviour tests go in `test/js/` (jsdom, loading the real assets), matching
`popup_ruby_selection.test.mjs`.

## 13. Known limitations

1. **Credentials are stored in plaintext** in the Drift `preferences` table, like every
   other secret in this repo today. There is no OS keystore/keychain integration
   anywhere in Fushi. Encryption at rest would be a separate, repo-wide change.
2. Surfaces with no sentence context (home Dictionary tab, floating dict window, nested
   popups) send an empty `{{sentence}}`. The explanation quality there depends on the
   model.
3. Streaming quality depends on the provider honouring SSE; gateways emitting mixed
   line endings inside one event boundary are handled, but exotic framings may only
   flush at stream end.
4. Thinking/reasoning options are best-effort: not every OpenAI-compatible endpoint
   supports them, and unsupported values are the provider's to reject.
5. Local Dart validation is unavailable on the current development machine (no Flutter
   SDK); `flutter analyze` and the test suites run on GitHub Actions.

## 14. Acceptance criteria

The feature is complete when: the AI Integration settings section exists; all four
providers work; OpenRouter and Custom work with every option; system and user prompts
follow the reference logic; `{{target}}`/`{{sentence}}` substitute correctly; no request
is ever sent without `messages`; streaming and cancellation can each be toggled;
thinking mode and intensity work; the answer can be selected and copied; a partial
selection exports correctly through `{popup-selection-text}`; `AI Fallback` opens for
unknown words and keeps the Anki and audio buttons; real dictionary results, Anki image
and audio do not regress; a normal lookup with AI off stays fast; API keys never appear
in backup, profile, sync or logs; the relevant tests pass; and an arm64-v8a build is
produced by GitHub Actions.

## 15. Licence

Fushi is GPL-3.0 and the reference files carry GPL-3.0 headers
(`Copyright (C) 2023-2025/2026 Yomitan Authors`) — compatible. Behaviour is
re-implemented idiomatically in Dart rather than copied as large JavaScript blocks;
where a constant, wire shape or algorithm is taken from the reference, the origin is
cited in the source file's header comment.
