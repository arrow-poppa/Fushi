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

## Pre-existing failure, not this branch's (verified)

`test/pages/home_video_page_menu_test.dart` — "卡片菜单单删会回收本视频 app-owned 封面
字幕与内嵌字幕缓存" — fails inside a `test/pages` batch and passes 17/17 when the file
is run alone. The error is:

```
A Timer is still pending even after the widget tree was disposed.
  VideoSpecsService._probeAndStore (video_specs_service.dart:338)
  VideoSpecsService._pump           (video_specs_service.dart:277)
```

**Classified against a clean baseline rather than assumed.** A detached worktree at
`develop` (`cda13c620`, no `fushi/lib/src/ai`) was bootstrapped and run:

| | passed | skipped | failed |
|---|---|---|---|
| `develop` baseline | 3675 | 7 | 1 |
| this branch | 3675 | 7 | 1 |

Identical counts, same test, same stack. Nothing in this branch touches
`VideoSpecsService`. So: **this branch adds no regression to `test/pages`**, and the
leaked timer is someone else's to fix — worth filing via `dart run tool/bug.dart new`
if it starts costing people time, which is a call for the repo owner rather than this
feature branch.

Do not "fix" it here, and do not let it mask a real red: re-run the single file alone
before concluding anything about a `test/pages` batch failure.

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

### 1. ~~Explicit-boundary audit~~ — done

All six `searchDictionaryResult` call sites were read. The rule applied: does the
caller hand over text the **user** delimited, or a window the app scanned?

| Call site | Path | Boundary |
|---|---|---|
| `base_source_page.dart:850` `onTextSelected` | popup tap-scan (`selection.js` `selectFromPosition`, "scan forward up to maxLength chars") | no |
| `base_source_page.dart:890` `onLinkClick` | headword / link target | **yes** |
| `reader_fushi/webview.part.dart:1726` | native text selection (drag) | **yes** |
| `reader_fushi_page.dart:3925` (via `lookup.part.dart`) | reader tap-scan | no |
| `reader_fushi/chrome.part.dart:400` | context menu over a native selection | **yes** |
| `manga_fushi_page.dart:3704` | OCR tap-scan (`processMangaSelection`) | no |

The three "yes" sites now pass `hasExplicitBoundary: true`; the three tap-scan
sites stay false, because with no supplied boundary the tokenizer would return a
whole clause in a language without spaces.

### 2. Real-device verification

`CLAUDE.md` requires it before claiming a reader/lookup feature works: no run of
this feature against a live provider has happened, on any platform. Everything
so far is analyzer plus unit/widget tests.

### 3. Full CI run and the arm64 artifact

`release.yml` with `build_only: true` produces downloadable artifacts without
publishing a release.

### 4. Nice to have

- Sentence context for the remaining surfaces (web video, floating lyric,
  global lookup, galgame overlay); §6.2 of the feature doc names each carrier.
- Swap the two `kCoveredElsewhere` entries that currently say "persistence only"
  for behaviour tests, now that the controller exists.
