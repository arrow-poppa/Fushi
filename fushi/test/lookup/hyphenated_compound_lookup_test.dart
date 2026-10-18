import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/latin_word_lookup.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 连字符复合词（`gaming-mode`、`state-of-the-art`、`jack-of-all-trades`）：
/// ① 引擎扫描窗口装得下整个复合词；② 点后一段时只有词典真有复合词才退到复合词开头。
void main() {
  /// 假引擎：返回 [text] 以 [dict] 里某个词开头时最长那个的 UTF-16 长度。
  LookupMatchedUnits fakeEngine(Set<String> dict) => (String text) {
    int best = 0;
    for (final String word in dict) {
      if (text.startsWith(word) && word.length > best) best = word.length;
    }
    return best;
  };

  List<String> g(String text) => text.characters.toList();

  group('FushiDicts.scanLengthFor', () {
    test('ordinary queries keep the default window', () {
      expect(FushiDicts.scanLengthFor('今日は良い天気'), FushiDicts.defaultScanLength);
      expect(
        FushiDicts.scanLengthFor('hello world'),
        FushiDicts.defaultScanLength,
      );
      // 16 码点恰好装得下，不需要撑长。
      expect(FushiDicts.scanLengthFor('state-of-the-art design'), 16);
    });

    test('a leading compound longer than the default widens the window', () {
      // jack-of-all-trades = 18 码点。
      expect(FushiDicts.scanLengthFor('jack-of-all-trades and more'), 18);
      expect(FushiDicts.scanLengthFor("mother-in-law's-house is"), 21);
    });

    test('the window is capped', () {
      final String huge = List<String>.filled(30, 'abc').join('-');
      expect(
        FushiDicts.scanLengthFor(huge),
        FushiDicts.maxHyphenatedScanLength,
      );
    });

    test('a hyphen not between letters does not widen anything', () {
      expect(FushiDicts.scanLengthFor('-abcdefghijklmnopqrstu'), 16);
      expect(FushiDicts.scanLengthFor('abcdefghijklmnopqrstu-'), 16);
    });

    test('the Japanese match-length cache key follows the same window', () {
      const String text = 'jack-of-all-trades and more';
      expect(JapaneseLanguage.matchLengthCacheKey(text), 'jack-of-all-trades');
    });
  });

  group('latinLookupStartAt', () {
    const String text = 'my gaming-mode on';
    final List<String> gs = g(text);
    final int tappedMode = text.indexOf('mode') + 1; // 「o」

    test(
      'tapping the second part reaches the compound when the dictionary has it',
      () {
        expect(
          latinLookupStartAt(
            gs,
            tappedMode,
            matchedUnits: fakeEngine(<String>{'gaming', 'gaming-mode', 'mode'}),
          ),
          text.indexOf('gaming'),
        );
      },
    );

    test('without the compound it stays on the tapped word', () {
      // 退到 gaming 会查出 gaming：不是用户点的词。
      expect(
        latinLookupStartAt(
          gs,
          tappedMode,
          matchedUnits: fakeEngine(<String>{'gaming', 'mode'}),
        ),
        text.indexOf('mode'),
      );
    });

    test('multi-part compounds try the leftmost part first', () {
      const String t = 'a jack-of-all-trades here';
      final int tapped = t.indexOf('all');
      expect(
        latinLookupStartAt(
          g(t),
          tapped,
          matchedUnits: fakeEngine(<String>{'jack-of-all-trades', 'of-all'}),
        ),
        t.indexOf('jack'),
      );
      // Só existe o trecho do meio: começa nele.
      expect(
        latinLookupStartAt(
          g(t),
          tapped,
          matchedUnits: fakeEngine(<String>{'of-all'}),
        ),
        t.indexOf('of-all'),
      );
    });

    test('the first part and plain words are unchanged', () {
      expect(
        latinLookupStartAt(gs, text.indexOf('ming'), matchedUnits: (_) => 99),
        text.indexOf('gaming'),
      );
      expect(latinLookupStartAt(g('hello there'), 8), 6);
      // Não latino: devolve o próprio índice.
      expect(latinLookupStartAt(g('今日は'), 1), 1);
    });

    test('without an engine it behaves like the old word-start rule', () {
      // FushiDicts não inicializado nos testes: o probe padrão devolve 0.
      expect(latinLookupStartAt(gs, tappedMode), text.indexOf('mode'));
    });
  });

  test('the source strip and video subtitles use the same rule', () {
    const String text = 'turn on gaming-mode now';
    final LookupMatchedUnits engine = fakeEngine(<String>{'gaming-mode'});
    final int tapped = text.indexOf('mode');
    expect(
      sourceLookupSuffixAt(text, tapped, matchedUnits: engine)!.suffix,
      'gaming-mode now',
    );
    expect(
      subtitleTranscriptLookupSpan(text, tapped, matchedUnits: engine).term,
      'gaming-mode now',
    );
    expect(sourceLookupSuffixAt(text, tapped)!.suffix, 'mode now');
  });
}
