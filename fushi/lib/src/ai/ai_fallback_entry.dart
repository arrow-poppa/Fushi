/// The synthetic `AI Fallback` dictionary result for words no dictionary knows.
///
/// Ported from the reference extension's `js/language/ai-fallback-util.js` and
/// `Translator._createAiFallbackTermDictionaryEntry`
/// (`js/language/translator.js:1869-1905`, GPL-3.0, Copyright (C) 2023-2026
/// Yomitan Authors). See `docs/agent/ai-explanation.md` §5.8 and §8.5.
///
/// Built entirely in Dart. It is never written into the `fushidicts` index and
/// the C++ engine is not touched: leaving
/// [DictionarySearchResult.popupJson] null makes the popup payload fall through
/// to the pure-Dart grouper, which needs no FFI.
library;

import 'dart:convert';

import 'package:fushi_dictionary/fushi_dictionary.dart';

/// The virtual dictionary name shown on the synthetic card.
///
/// Same literal as the reference so a user moving between the two products sees
/// the same label. It is not backed by the dictionary database.
const String kAiFallbackDictionaryName = 'AI Fallback';

/// Languages whose writing system does not separate words.
///
/// Copied from the reference's `NO_WORD_BOUNDARY_LANGUAGES`. It gates **only**
/// the tokeniser path below — see [resolveFallbackTerm] for why that is
/// narrower than upstream's use of it.
const Set<String> kNoWordBoundaryLanguages = <String>{
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
};

/// Leading run of word characters.
///
/// The apostrophe counts as a word character, which keeps `don't`, `it's` and
/// `O'Brien` whole. Languages with elision (French, Italian) yield a slightly
/// larger token — `l'homme` rather than `homme` — which is accepted: the model
/// gets the sentence too.
final RegExp _wordToken = RegExp(r"^[\p{L}\p{M}\p{N}'-]+", unicode: true);

/// Separators that are word characters inside a token but not at its edges.
final RegExp _edgeSeparatorStart = RegExp(r"^['-]+", unicode: true);
final RegExp _edgeSeparatorEnd = RegExp(r"['-]+$", unicode: true);

/// A token made only of digits or separators is not a word.
final RegExp _hasLetter = RegExp(r'\p{L}', unicode: true);

/// A resolved fallback token and the span of source text it covers.
class AiFallbackToken {
  const AiFallbackToken({required this.term, required this.textLength});

  /// The word handed to the model, and shown as the synthetic headword.
  final String term;

  /// How much of the source text the token covers, so the caller can keep the
  /// highlight and the sentence extraction anchored to the same span.
  ///
  /// Measured after trailing separators are stripped but before leading ones
  /// are, so it is never shorter than [term].
  final int textLength;
}

abstract final class AiFallback {
  /// Extracts the leading word from [text].
  ///
  /// Direct port of `getAiFallbackToken`. Returns null when the text does not
  /// start with a word character, or when the token contains no letter at all.
  static AiFallbackToken? tokenize(String text) {
    // U+2019 is normalised to a plain apostrophe first. The substitution is
    // length-preserving, so textLength still indexes the original text.
    final RegExpMatch? match = _wordToken.firstMatch(text.replaceAll('’', "'"));
    if (match == null) return null;

    final String scanned = match[0]!.replaceAll(_edgeSeparatorEnd, '');
    final String term = scanned.replaceAll(_edgeSeparatorStart, '');
    if (term.isEmpty || !_hasLetter.hasMatch(term)) return null;
    return AiFallbackToken(term: term, textLength: scanned.length);
  }

  /// Decides what word, if any, the fallback should explain.
  ///
  /// **Divergence from the reference** (`docs/agent/ai-explanation.md` §8.5).
  /// Upstream refuses the fallback outright for every language in
  /// [kNoWordBoundaryLanguages], including Japanese — and Fushi pins
  /// `targetLanguage` to Japanese, so importing that rule verbatim would ship a
  /// feature that can never fire.
  ///
  /// The reason upstream refuses is specific: its tokeniser takes the leading
  /// run of letters out of a raw scan buffer, and with no spaces that run
  /// swallows an entire clause. That failure needs a *boundary*, and it only
  /// applies when nobody supplied one.
  ///
  /// So the gate here is on the boundary, not on the language:
  ///
  /// - [hasExplicitBoundary] true — the user selected the text, or the surface
  ///   otherwise knows where the word ends. The selection **is** the boundary,
  ///   so it is used whole, in any language. This is the common mining case and
  ///   it is what makes the feature usable in Japanese.
  /// - [hasExplicitBoundary] false — a tap or hover handed us a raw window with
  ///   no boundary. The tokeniser has to find one, which only means anything in
  ///   a language that separates words, so [kNoWordBoundaryLanguages] applies
  ///   exactly as upstream.
  ///
  /// Fushi has no tokeniser that can segment an **unknown** word in CJK —
  /// `fushidicts` finds boundaries by matching dictionary entries, and by
  /// definition there is no entry here. Guessing one would produce a term
  /// covering half a sentence and a highlight over the wrong range, so this
  /// deliberately does not try.
  static AiFallbackToken? resolveFallbackTerm(
    String text, {
    required bool hasExplicitBoundary,
    required String language,
  }) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    if (hasExplicitBoundary) {
      // Never reduced to a partially matched prefix: the whole selection is the
      // word the user asked about.
      return AiFallbackToken(term: trimmed, textLength: trimmed.length);
    }

    if (kNoWordBoundaryLanguages.contains(language)) return null;
    return tokenize(text);
  }

  /// Builds the synthetic result the popup renders.
  ///
  /// The entry carries an empty glossary, exactly like the reference: the card
  /// exists so the popup opens, the audio and Anki buttons are available, and
  /// the AI explanation has somewhere to live. Leaving
  /// [DictionarySearchResult.popupJson] null routes rendering through the
  /// pure-Dart grouper, so nothing here touches the C++ engine or the index.
  static DictionarySearchResult buildResult(AiFallbackToken token) {
    return DictionarySearchResult(
      searchTerm: token.term,
      bestLength: token.textLength,
      headwordCount: 1,
      entries: <DictionaryEntry>[
        DictionaryEntry(
          dictionaryName: kAiFallbackDictionaryName,
          word: token.term,
          // Empty reading means "same as the written form" by the Yomitan
          // convention the grouper already follows (BUG-791); inventing a
          // reading for an unknown word would be a guess shown as fact.
          reading: '',
          meaning: '',
          extra: jsonEncode(<String, Object?>{'matched': token.term}),
        ),
      ],
    );
  }

  /// Whether [result] is a synthetic fallback rather than a real lookup.
  ///
  /// Used so the popup and the mining payload can treat it appropriately
  /// without re-deriving the condition at each call site.
  static bool isFallbackResult(DictionarySearchResult result) =>
      result.entries.length == 1 &&
      result.entries.single.dictionaryName == kAiFallbackDictionaryName;
}
