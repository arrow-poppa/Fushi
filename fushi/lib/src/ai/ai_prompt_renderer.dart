/// Prompt template rendering for the BYOK AI Explanation feature.
///
/// Ported from the reference extension's `_replacePlaceholders` /
/// `_resolvePromptArguments` (`js/comm/ai-provider.js:69-73`, `:306-315`,
/// GPL-3.0, Copyright (C) 2023-2025 Yomitan Authors). See
/// `docs/agent/ai-explanation.md` §5.2.
///
/// Deliberately knows nothing about HTTP, providers or widgets: it turns
/// templates plus a lookup into strings, and that is all. Everything here is
/// pure and synchronous, so it is cheap enough to run on every lookup.
library;

/// The reference's default user prompt, verbatim.
///
/// Identical in three places upstream (`options-schema.json:1399`,
/// `options-util.js:1881`, `ai-controller.js:204`). Kept byte-for-byte so a user
/// migrating from the extension gets the same answers from the same model.
const String kAiDefaultUserPrompt =
    "Explain the meaning of '{{target}}' in the following sentence: "
    "'{{sentence}}'. Provide a concise explanation focusing on the word's usage "
    'and meaning in this specific context.';

/// The rendered prompts for one request.
class AiRenderedPrompts {
  const AiRenderedPrompts({
    required this.userPrompt,
    required this.systemPrompt,
  });

  /// Always non-empty — see [AiPromptRenderer.render].
  final String userPrompt;

  /// Empty means "send no system message at all", not "send an empty one".
  final String systemPrompt;

  /// Whether a `system` role message should be included.
  bool get hasSystemPrompt => systemPrompt.isNotEmpty;
}

/// Substitutes `{{target}}` and `{{sentence}}` into prompt templates.
abstract final class AiPromptRenderer {
  /// The only two placeholders that exist. Case-sensitive and whitespace-
  /// intolerant, exactly like the reference: `{{ target }}` is left alone.
  static const String targetPlaceholder = '{{target}}';
  static const String sentencePlaceholder = '{{sentence}}';

  /// Renders the user and system templates for one lookup.
  ///
  /// [sentence] may be empty — several surfaces (the home Dictionary tab, the
  /// floating dictionary window, nested popups) genuinely have no context. An
  /// empty sentence substitutes to an empty string and must never produce
  /// invalid JSON or a missing field.
  ///
  /// **Divergence from the reference** (`docs/agent/ai-explanation.md` §8.1):
  /// upstream sends `content: ""` when the custom prompt is blank, which several
  /// gateways reject outright with `Input required: specify "prompt" or
  /// "messages"`. When the rendered user prompt is blank we fall back to
  /// [kAiDefaultUserPrompt] so a request is never sent without user input.
  static AiRenderedPrompts render({
    required String userTemplate,
    required String systemTemplate,
    required String target,
    required String sentence,
  }) {
    String userPrompt = _substitute(userTemplate, target, sentence);
    if (userPrompt.trim().isEmpty) {
      userPrompt = _substitute(kAiDefaultUserPrompt, target, sentence);
    }
    return AiRenderedPrompts(
      userPrompt: userPrompt,
      // The system prompt gets the same substitution, and an empty one stays
      // empty: the caller omits the message entirely rather than sending "".
      systemPrompt: _substitute(systemTemplate, target, sentence),
    );
  }

  /// Replaces every occurrence of both placeholders.
  ///
  /// Order matters and is preserved from the reference: `{{target}}` first, then
  /// `{{sentence}}`. A term containing the literal text `{{sentence}}` therefore
  /// gets substituted on the second pass — pathological, but reproducing it
  /// keeps parity.
  ///
  /// **Divergence from the reference** (`docs/agent/ai-explanation.md` §8.2):
  /// JavaScript's `String.replace` with a string replacement interprets `$&`,
  /// `` $` ``, `$'` and `$1` **inside the replacement**, so upstream mangles any
  /// term or sentence containing those sequences. Dart's [String.replaceAll] is
  /// literal, which is the correct behaviour; we keep it and pin it with a test.
  static String _substitute(String template, String target, String sentence) {
    if (template.isEmpty) return '';
    return template
        .replaceAll(targetPlaceholder, target)
        .replaceAll(sentencePlaceholder, sentence);
  }
}
