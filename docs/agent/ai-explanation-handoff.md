# AI Explanation — handoff (temporary state)

> Working state only. Permanent rules, the parity matrix and architectural decisions
> live in [ai-explanation.md](ai-explanation.md); do not duplicate them here.
> **Never put API keys, tokens, passwords, keystores or personal data in this file.**

## Current session

| Field | Value |
|---|---|
| Agent | Claude Code (implementer) |
| Worktree | `.claude/worktrees/ai-explanation` (gitignored) |
| Branch | `agent/claude-ai-explanation` |
| Integration branch | `feature/byok-ai-explanation` |
| Base | `develop` @ `cda13c620c293b22f76df363752bde119ae074f8` |
| Fork | `arrow-poppa/Fushi` (`origin`). `upstream` = `hajisensai/Fushi`, **push URL disabled locally** |
| Claim | `.worktrees/coordination/claims/claude-ai-explanation.json` |
| Last commit | see `git log -1 agent/claude-ai-explanation` |

## Completed

- **Phase 1 — audit.** Repo/branch/worktree state verified; instruction files read in
  full (`CLAUDE.md`, `AGENTS.md`, `docs/agent/build.md`, `review-process.md`, relevant
  parts of `fast-workflow.md`, and the `fushi/`, `fushi_anki/`, `fushi_dictionary`
  module docs). `docs/agent/ai-explanation.md` written.
- **Phase 3 — base layer.** `AiSseParser`, `AiPromptRenderer`, `AiProviderConfig`,
  the 27 `ai_explain_*` preference keys, and credential registration in
  `PrefRedactionPolicy` / `kCredentialPreferenceKeys`, each with tests.
- **Phase 4 — providers.** `AiRequestBuilder` (OpenAI / DeepSeek / Custom+OpenRouter),
  `AiGeminiRequestBuilder`, `AiResponseParser`, `AiExplanationClient` (streaming,
  cancellation, sanitised errors), each with tests.

### Parity evidence

The reference implementation was executed under Node and diffed against this port,
case by case. **684 cases, all identical:**

| Area | Cases | What it covers |
|---|---|---|
| SSE framing | 23 | separators incl. `\r\r`, single-space strip, events split across chunks, termination with no trailing blank line, `[DONE]`, malformed payloads, Unicode |
| Reasoning / routing / merge | 301 | 192 thinking combinations x 2 endpoint kinds, 96 routing combinations, 13 deep-merge shapes |
| Gemini | 360 | 18 model ids x 5 thinking levels x streaming x system prompt — resolved model id, host, thinking level, full URL and full body |

Harnesses live in the session scratchpad (not committed); they are reproducible from
the reference tree at any time.

### Commits on `agent/claude-ai-explanation`

| Commit | Contents |
|---|---|
| `b3ac39b6` | docs: parity matrix, handoff, CLAUDE.md reference |
| `0fb887f4` | SSE parser + prompt renderer |
| `20ce166f` | config model + preference keys + credential redaction |
| `e0bac9b1` | OpenAI / DeepSeek / Custom request building |
| `72dc7f1e` | Gemini routing + response extraction |
| `7424418b` | HTTP client: streaming, cancellation, sanitised errors |

## Decisions taken with the user (2026-09-11)

1. **`AGENTS.md` stays a real pointer file, not a symlink.** The repo has zero tracked
   symlinks, `AGENTS.md` carries unique content, and a symlink degrades to a plain text
   file on Windows checkouts (`core.symlinks=false`). Only the canonical `CLAUDE.md` is
   edited.
2. **All Dart validation runs on GitHub Actions**, not locally. The machine has no
   Flutter/Dart/pwsh and limited RAM.

## Environment constraints

- No `flutter`, `dart` or `pwsh` on this machine. `tool/setup_worktree.ps1` part (a)
  (carry `skip-worktree` secret files) is a verified **no-op** here — this fresh clone
  has zero `skip-worktree` files. Part (b) (`bootstrap`) cannot run without Flutter.
- Validation path: `main.yml` on the fork (`workflow_dispatch` or a PR inside the fork)
  runs `flutter analyze`, app unit tests, package tests, jsdom JS tests and an arm64
  release build. `release.yml` with `build_only: true` produces downloadable artifacts
  without publishing a release.

## Tests run

- **CI run 34560758748** (`main.yml`, `workflow_dispatch`, fork): `dart analyze`
  **passed** on commits through `20ce166f`. The unit-test, package-test and JS-test
  steps were still running when this was written — re-check before trusting them.
- No Dart runs locally: this machine has no Flutter SDK (see Environment constraints).
- The 684-case parity diffs above were run locally under Node + Python. They validate
  **algorithms**, not Dart compilation; `dart analyze` and `flutter test` on CI are the
  real gate.

## Pending tests

Everything in `ai-explanation.md` §12.

## Risks

1. **Japanese and the unknown-word fallback.** Yomitan disables the fallback for `ja`
   (and other no-word-boundary languages) and `fushi_dictionary` pins `targetLanguage`
   to Japanese. A literal port ships a dead feature. Resolution recorded in
   `ai-explanation.md` §8.5 — derive the term from the host's bounded selection/scan
   window rather than a space-based tokeniser. **This is the highest-risk item and
   needs real-device verification.**
2. **`popup.js` is 6231 lines and high-conflict.** Keep AI changes to a small, clearly
   delimited region and coordinate before touching it.
3. **Directory-enumerating guard tests** (~60, `listSync(recursive: true)`) pick up any
   new file automatically. New outbound HTTP must use `createAppHttpIoClient()` or
   `outbound_http_discipline_guard_test.dart` fails.
4. **Preference key registry** `kKnownPreferenceKeys` is guarded — every new pref key
   must be registered or `preference_keys_guard_test.dart` fails.
5. **i18n completeness** is guarded across all 17 files; only `fushi/tool/i18n_sync.dart`
   may add keys.
6. Secrets are plaintext in the `preferences` table repo-wide; no keystore exists.

## Known bugs

None yet.

## Recommended next work

1. **Phase 4b — repository**: cache (60 s TTL, key per §8.3), dedup by in-flight key,
   30 s inactivity timeout re-armed per chunk, cancellation policy, and the
   non-streaming fallback with its four guards (§5.6.1 — replicate exactly).
2. **Credential store + settings UI**: `ai_explain_*` getters/setters on
   `PreferencesRepository`, an AI Integration settings section, i18n keys via
   `fushi/tool/i18n_sync.dart` only.
3. **Phase 5 — popup**: states, streaming into one text node, selection and copy.
4. **Phase 6 — fallback and Anki**: synthetic `AI Fallback` result, `{ai-explanation}`.
5. **Phase 7 — surfaces**, then **Phase 8 — full CI validation and the arm64 artifact**
   (`release.yml` with `build_only: true` produces downloadable artifacts without
   publishing a release).
