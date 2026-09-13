import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_fallback_entry.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// The fallback is the feature's sharpest edge: it invents a dictionary result,
/// and if it invents the wrong *word* the user mines a card for half a sentence.
///
/// The tokenizer expectations below were produced by **executing the reference
/// implementation** (`js/language/ai-fallback-util.js`) under Node and recording
/// its output, so they are parity assertions rather than guesses. The case
/// `日本語です` is the one that explains the whole design: the tokenizer swallows
/// the entire run, which is exactly why upstream refuses the fallback for
/// Japanese — and why this port gates on the boundary instead of the language.
///
/// See `docs/agent/ai-explanation.md` §5.8 and §8.5.
void main() {
  group('tokenize matches the reference exactly', () {
    /// term == null means the reference returned null.
    const Map<String, (String?, int)> expectations = <String, (String?, int)>{
      'Proxmox is great': ('Proxmox', 7),
      "don't stop": ("don't", 5),
      "O'Brien said": ("O'Brien", 7),
      "l'homme": ("l'homme", 7),
      'it’s fine': ("it's", 4),
      '  leading space': (null, 0),
      '-leading dash': ('leading', 8),
      "'quoted'": ('quoted', 7),
      'trailing- dash': ('trailing', 8),
      'word.': ('word', 4),
      '123': (null, 0),
      '123abc': ('123abc', 6),
      'abc123': ('abc123', 6),
      '---': (null, 0),
      "'''": (null, 0),
      '': (null, 0),
      '   ': (null, 0),
      'naïve café': ('naïve', 5),
      'Müller-Lüdenscheidt': ('Müller-Lüdenscheidt', 19),
      'señor': ('señor', 5),
      '日本語です': ('日本語です', 5),
      'Ελληνικά': ('Ελληνικά', 8),
      'Привет мир': ('Привет', 6),
      'hello-world foo': ('hello-world', 11),
      'a': ('a', 1),
      "A'": ('A', 1),
      "'a": ('a', 2),
      "co-op's": ("co-op's", 7),
      'x’y': ("x'y", 3),
      'тест-кейс': ('тест-кейс', 9),
      'ある': ('ある', 2),
      '한국어 단어': ('한국어', 3),
      'ไทย': ('ไทย', 3),
      'e.g.': ('e', 1),
      'U.S.A.': ('U', 1),
      're-do--it': ('re-do--it', 9),
    };

    test('every recorded reference case', () {
      expectations.forEach((String input, (String?, int) expected) {
        final AiFallbackToken? actual = AiFallback.tokenize(input);
        if (expected.$1 == null) {
          expect(actual, isNull, reason: 'input ${jsonEncode(input)}');
          return;
        }
        expect(actual, isNotNull, reason: 'input ${jsonEncode(input)}');
        expect(actual!.term, expected.$1, reason: 'input ${jsonEncode(input)}');
        expect(
          actual.textLength,
          expected.$2,
          reason: 'input ${jsonEncode(input)}',
        );
      });
    });

    test('textLength is never shorter than the term', () {
      // It measures the span after trailing separators are stripped but before
      // leading ones are, which is what keeps the highlight anchored at the
      // scan point for text starting with a quote or dash.
      for (final String input in expectations.keys) {
        final AiFallbackToken? token = AiFallback.tokenize(input);
        if (token == null) continue;
        expect(
          token.textLength,
          greaterThanOrEqualTo(token.term.length),
          reason: 'input ${jsonEncode(input)}',
        );
      }
    });
  });

  group('resolveFallbackTerm gates on the boundary, not the language', () {
    test('an explicit selection is used whole, in any language', () {
      // The divergence that makes the feature usable at all in Fushi, which
      // pins targetLanguage to Japanese.
      for (final String language in <String>['ja', 'zh', 'th', 'en', 'de']) {
        final AiFallbackToken? token = AiFallback.resolveFallbackTerm(
          '持ち込み',
          hasExplicitBoundary: true,
          language: language,
        );
        expect(
          token?.term,
          '持ち込み',
          reason: 'a user selection is the boundary, whatever the language',
        );
      }
    });

    test('a multi-word selection is never reduced to a prefix', () {
      // The explicit requirement: the whole selected word survives, rather than
      // collapsing to whatever partial prefix the dictionary matched.
      final AiFallbackToken? token = AiFallback.resolveFallbackTerm(
        'machine learning',
        hasExplicitBoundary: true,
        language: 'en',
      );
      expect(token?.term, 'machine learning');
    });

    test('a selection is trimmed but otherwise untouched', () {
      final AiFallbackToken? token = AiFallback.resolveFallbackTerm(
        '  Proxmox  ',
        hasExplicitBoundary: true,
        language: 'en',
      );
      expect(token?.term, 'Proxmox');
      expect(token?.textLength, 'Proxmox'.length);
    });

    test('a blank selection yields nothing', () {
      expect(
        AiFallback.resolveFallbackTerm(
          '   ',
          hasExplicitBoundary: true,
          language: 'en',
        ),
        isNull,
      );
    });

    test('without a boundary, a space-separated language tokenizes', () {
      final AiFallbackToken? token = AiFallback.resolveFallbackTerm(
        'Proxmox is great',
        hasExplicitBoundary: false,
        language: 'en',
      );
      expect(
        token?.term,
        'Proxmox',
        reason: 'the tokenizer finds the boundary the caller did not supply',
      );
    });

    test('without a boundary, a no-word-boundary language refuses', () {
      // Upstream's rule, kept exactly where it still applies: with no boundary
      // supplied, the tokenizer would return a whole clause.
      for (final String language in kNoWordBoundaryLanguages) {
        expect(
          AiFallback.resolveFallbackTerm(
            '日本語ですねこれは',
            hasExplicitBoundary: false,
            language: language,
          ),
          isNull,
          reason: '$language cannot be segmented without a boundary',
        );
      }
    });

    test('the excluded language set matches the reference', () {
      expect(kNoWordBoundaryLanguages, <String>{
        'ja',
        'zh',
        'zh-Hans',
        'zh-Hant',
        'yue',
        'th',
        'lo',
        'km',
        'my',
        'bo',
      });
      expect(
        kNoWordBoundaryLanguages.contains('ko'),
        isFalse,
        reason: 'Korean separates words and upstream does offer it',
      );
    });
  });

  group('synthetic result', () {
    AiFallbackToken token([String term = 'Proxmox']) =>
        AiFallbackToken(term: term, textLength: term.length);

    test('carries the AI Fallback dictionary name', () {
      final DictionarySearchResult result = AiFallback.buildResult(token());
      expect(result.entries.single.dictionaryName, 'AI Fallback');
      expect(
        kAiFallbackDictionaryName,
        'AI Fallback',
        reason: 'same literal as the reference, so the label matches',
      );
    });

    test('renders through the pure-Dart grouper, never the C++ engine', () {
      // popupJson stays null so buildPopupEntriesJs falls through to
      // buildLookupEntriesJson, which involves no FFI. This is what keeps the
      // fallback out of the fushidicts index entirely.
      final DictionarySearchResult result = AiFallback.buildResult(token());
      expect(result.popupJson, isNull);
    });

    test('has an empty glossary, like the reference entry', () {
      final DictionaryEntry entry = AiFallback.buildResult(
        token(),
      ).entries.single;
      expect(entry.meaning, isEmpty);
      expect(
        entry.reading,
        isEmpty,
        reason: 'an invented reading would be a guess shown as fact',
      );
    });

    test('marks the matched span so the popup highlights the whole word', () {
      final DictionaryEntry entry = AiFallback.buildResult(
        token('持ち込み'),
      ).entries.single;
      final Map<String, Object?> extra =
          jsonDecode(entry.extra) as Map<String, Object?>;
      expect(extra['matched'], '持ち込み');
      expect(entry.word, '持ち込み');
    });

    test('reports the scanned length so the highlight stays anchored', () {
      final DictionarySearchResult result = AiFallback.buildResult(
        const AiFallbackToken(term: 'leading', textLength: 8),
      );
      expect(result.bestLength, 8);
      expect(result.searchTerm, 'leading');
      expect(result.headwordCount, 1);
    });

    test('is recognisable as a fallback', () {
      expect(
        AiFallback.isFallbackResult(AiFallback.buildResult(token())),
        isTrue,
      );
      expect(
        AiFallback.isFallbackResult(
          DictionarySearchResult(
            searchTerm: 'x',
            entries: <DictionaryEntry>[
              DictionaryEntry(dictionaryName: 'JMdict', word: 'x'),
            ],
          ),
        ),
        isFalse,
      );
      expect(
        AiFallback.isFallbackResult(DictionarySearchResult(searchTerm: 'x')),
        isFalse,
        reason: 'an empty result is not a fallback',
      );
    });
  });
}
