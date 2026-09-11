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

- **Phase 1 — audit** and `docs/agent/ai-explanation.md` (parity matrix, architecture,
  permanent decisions, deliberate divergences).
- **Phase 3 — base layer**: SSE parser, prompt renderer, config model, 27 preference
  keys, credential registration in `PrefRedactionPolicy`.
- **Phase 4 — providers**: request builders for OpenAI / DeepSeek / Custom+OpenRouter
  and Gemini, response extraction, HTTP client with streaming + cancellation,
  repository with cache / dedup / timeout / the single non-streaming retry.
- **Persistence**: `AiPrefKeys`, `AiCredentialStore`, `AiSettingsStore`, wired onto
  `AppModel` as `aiSettings` / `aiCredentials`.
- **Unknown-word fallback**: synthetic `AI Fallback` result, built in Dart only.
- **i18n**: 60 keys across all 17 locales via `i18n_sync.dart` + `slang`.
- **Settings**: the AI Explanation section under Settings → Lookup, with the five
  interactive rows registered in `settings_schema_coverage_test`'s `kCoveredElsewhere`.
- **Popup**: the explanation box in `popup.js` + `popup.css`, with jsdom tests.
- **Anki**: the `{ai-explanation}` marker, threaded through `renderMediaPayload`.

### Parity evidence

The reference implementation was executed under Node and diffed against this port.
**684 cases identical** (23 SSE framing, 301 reasoning/routing/merge, 360 Gemini),
plus 36 recorded fallback-tokenizer cases embedded directly as test expectations.

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

All local, with Flutter 3.44.0 (matching CI):

| Command | Result |
|---|---|
| `flutter analyze` (whole project) | **No issues found!** |
| `flutter test test/ai` | +252 passed |
| `flutter test test/settings test/ai test/models` | +1410 passed |
| `flutter test test/anki test/ai` | +648 passed |
| `flutter test` in `packages/fushi_anki` | +562 passed |
| `flutter test test/i18n` | +30 passed |
| `npm test` in `test/js` | 72/72 passed |

CI run 34560758748 (`main.yml` on the fork) was green through commit `20ce166f`:
`dart analyze`, **25511** app tests, package tests, and both JS suites. Note the
count — `CLAUDE.md` warns that a zero-test run disguises itself as a pass.

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

Everything below the UI is done and verified; what remains is integration.

1. **Controller wiring** — the one piece that makes it work end to end:
   - register an `aiExplainAction` JS handler in `dictionary_popup_webview.dart`
     (regenerate / cancel) alongside the existing 27;
   - inject the AI state and the `window.i18nAi*` strings with the popup payload
     (`popup_settings_injection.dart`), reusing the static/dynamic split so the
     per-lookup push stays small;
   - on lookup: build the cache key, call `AiExplanationRepository.explain`, push
     each `AiExplanationResult` through `window.__fushiAiUpdate`;
   - honour `cancelPendingRequests` on popup dismiss / new lookup / surface hide.
2. **AI Fallback wiring** — call `AiFallback.resolveFallbackTerm` when
   `searchDictionary` returns no entries and the setting is on, passing
   `hasExplicitBoundary: true` for selection-driven lookups.
3. **Surfaces** — thread the sentence from each host (see §6.2 of the feature doc for
   the verified carrier per surface; three surfaces genuinely have none).
4. **Validation** — full CI run, then the arm64 artifact via `release.yml` with
   `build_only: true` (produces downloadable artifacts without publishing a release).
