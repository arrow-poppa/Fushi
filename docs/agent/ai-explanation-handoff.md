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
  module docs).
- Yomitan AI feature extracted in full and cross-verified against the sources
  (placeholders, OpenRouter detection, identifying headers, fallback language set,
  SSE reader, non-streaming fallback guards).
- Fushi integration points mapped and the load-bearing claims re-verified first-hand:
  the outbound-HTTP CI guard sentinel, `snapshotSelection()` pointer-down wiring, and
  the `popupJson ?? buildLookupEntriesJson` fallback that makes a synthetic Dart-only
  result renderable.
- `docs/agent/ai-explanation.md` written (objective, scope, non-objectives, parity
  matrix, architecture, permanent decisions, deliberate divergences, credential
  security, popup and Anki integration, tests, limitations, acceptance, licence).

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

- None yet — no code written yet. Documentation-only change so far, so per `CLAUDE.md`
  the bar is `git diff --cached --check`.

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

1. Phase 3 — base layer: `AiProviderConfig`, `AiPromptRenderer`, `AiSseParser`, the
   preference keys, and `PrefRedactionPolicy` registration, with unit tests. This is
   pure Dart with no Flutter dependency and is the cheapest thing to get green on CI.
2. Phase 4 — providers and the repository (cache, dedup, timeout, cancellation).
3. Phase 5 — popup states and the JS box.
4. Phase 6 — fallback and Anki.
