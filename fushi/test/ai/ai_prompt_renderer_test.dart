import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_prompt_renderer.dart';

/// [AiPromptRenderer] decides the exact bytes that leave the user's device on a
/// BYOK request, so its substitution rules are a contract rather than a detail.
///
/// Two of these tests pin **deliberate divergences** from the reference
/// extension (`docs/agent/ai-explanation.md` §8.1 and §8.2): never sending an
/// empty user prompt, and substituting literally rather than with JavaScript's
/// `$`-pattern semantics. Both are behaviour the reference gets wrong, and both
/// would silently regress if someone "restored parity" without reading why.
void main() {
  AiRenderedPrompts render({
    String user = 'Explain {{target}} in {{sentence}}.',
    String system = '',
    String target = 'word',
    String sentence = 'a sentence',
  }) =>
      AiPromptRenderer.render(
        userTemplate: user,
        systemTemplate: system,
        target: target,
        sentence: sentence,
      );

  group('placeholder substitution', () {
    test('substitutes {{target}} and {{sentence}}', () {
      expect(render().userPrompt, 'Explain word in a sentence.');
    });

    test('substitutes every occurrence, not just the first', () {
      expect(
        render(user: '{{target}} {{target}} {{sentence}} {{sentence}}')
            .userPrompt,
        'word word a sentence a sentence',
      );
    });

    test('is case-sensitive and whitespace-intolerant', () {
      // `{{ target }}` and `{{Target}}` are left alone upstream; a tolerant
      // matcher would start substituting text the user meant to keep literal.
      expect(render(user: '{{ target }} {{Target}} {{TARGET}}').userPrompt,
          '{{ target }} {{Target}} {{TARGET}}');
    });

    test('leaves unknown placeholders untouched', () {
      expect(render(user: '{{reading}} {{target}}').userPrompt,
          '{{reading}} word');
    });

    test('substitutes target before sentence', () {
      // Parity quirk: a target containing the literal text `{{sentence}}` is
      // substituted on the second pass. Pathological, but reproduced.
      expect(
        render(user: '{{target}}', target: '{{sentence}}', sentence: 'CTX')
            .userPrompt,
        'CTX',
        reason: 'target is substituted first, so its content is then scanned',
      );
    });
  });

  group('empty and missing input', () {
    test('an empty sentence substitutes to an empty string', () {
      // The home Dictionary tab, the floating dictionary window and nested
      // popups genuinely have no context; this must stay valid, not blow up.
      expect(render(user: 'X{{sentence}}Y', sentence: '').userPrompt, 'XY');
    });

    test('falls back to the default prompt when the template is empty', () {
      // Divergence §8.1: upstream sends `content: ""`, which gateways reject
      // with `Input required: specify "prompt" or "messages"`.
      final AiRenderedPrompts result = render(user: '');
      expect(result.userPrompt, isNotEmpty);
      expect(result.userPrompt, contains('word'));
      expect(result.userPrompt, contains('a sentence'));
    });

    test('falls back when the template is only whitespace', () {
      expect(render(user: '   \n\t ').userPrompt.trim(), isNotEmpty);
    });

    test('the fallback still substitutes placeholders', () {
      expect(render(user: '', target: '猫', sentence: '猫が好き').userPrompt,
          allOf(contains('猫'), contains('猫が好き')));
    });

    test('a template of only placeholders resolving to empty falls back', () {
      // `{{sentence}}` alone with no context renders blank — that is exactly the
      // "no user input" case the divergence exists to prevent.
      final AiRenderedPrompts result =
          render(user: '{{sentence}}', sentence: '');
      expect(result.userPrompt.trim(), isNotEmpty,
          reason: 'a blank render must never become the outgoing message');
    });
  });

  group('system prompt', () {
    test('is empty by default and reports no system message', () {
      final AiRenderedPrompts result = render();
      expect(result.systemPrompt, isEmpty);
      expect(result.hasSystemPrompt, isFalse,
          reason: 'an empty system prompt means: omit the message entirely');
    });

    test('receives the same placeholder substitution', () {
      final AiRenderedPrompts result =
          render(system: 'You explain {{target}}. Context: {{sentence}}');
      expect(result.systemPrompt, 'You explain word. Context: a sentence');
      expect(result.hasSystemPrompt, isTrue);
    });

    test('is never defaulted the way the user prompt is', () {
      // Only the user prompt has a fallback; a blank system prompt is a
      // legitimate choice and must not silently acquire content.
      expect(render(system: '').systemPrompt, isEmpty);
    });
  });

  group('literal substitution (divergence from JS replace semantics)', () {
    test(r'does not interpret $& in the substituted value', () {
      // JS `String.replace` expands `$&` to the match, so upstream turns this
      // into `{{target}}`. Dart replaceAll is literal, which is correct.
      expect(render(user: '[{{target}}]', target: r'$&').userPrompt, r'[$&]');
    });

    test(r'does not interpret $1, $` or $ in the substituted value', () {
      expect(render(user: '{{target}}', target: r'$1').userPrompt, r'$1');
      expect(render(user: '{{target}}', target: r'$`').userPrompt, r'$`');
      expect(render(user: '{{sentence}}', sentence: r"$'").userPrompt, r"$'");
    });

    test('handles a value that is entirely dollar signs', () {
      expect(render(user: '{{target}}', target: r'$$$$').userPrompt, r'$$$$');
    });
  });

  group('unicode and formatting preservation', () {
    test('preserves Japanese, combining marks and emoji', () {
      const String sentence = '猫が好きです。🐱';
      expect(render(user: '{{sentence}}', sentence: sentence).userPrompt,
          sentence);
    });

    test('preserves newlines in the template and in the values', () {
      expect(
        render(user: 'A\n{{sentence}}\nB', sentence: 'line1\nline2').userPrompt,
        'A\nline1\nline2\nB',
        reason: 'prompts are plain text; line structure is meaningful to models',
      );
    });

    test('does not treat values as HTML', () {
      const String target = '<script>alert(1)</script>';
      expect(render(user: '{{target}}', target: target).userPrompt, target,
          reason: 'the prompt is a string, never markup to be escaped here');
    });
  });

  test('the default prompt matches the reference byte-for-byte', () {
    // A user migrating from the extension must get the same answers from the
    // same model, so this string is pinned rather than paraphrased.
    expect(
      kAiDefaultUserPrompt,
      "Explain the meaning of '{{target}}' in the following sentence: "
      "'{{sentence}}'. Provide a concise explanation focusing on the word's "
      'usage and meaning in this specific context.',
    );
  });
}
