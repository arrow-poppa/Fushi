import 'dart:io';

// drift 也导出一个 isNull（查询构造器用），与 matcher 的同名 matcher 撞名。
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/ai/ai_fallback_entry.dart';
import 'package:fushi/src/ai/ai_pref_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// `AppModel.applyAiFallback` is the gate between "no dictionary knew this word"
/// and "invent a card for it". Getting the gate wrong is expensive in both
/// directions: too eager and every failed lookup fabricates an entry, too shy
/// and the feature never fires.
///
/// The boundary rule is the load-bearing part. Fushi's lookup pipeline is
/// deliberately language-agnostic — `targetLanguage` was removed on 2026-07-26
/// and `target_language_removed_guard_test.dart` keeps it out — so this gate
/// cannot use the reference's language blacklist. It gates on whether the caller
/// supplied a real word boundary instead. See docs/agent/ai-explanation.md §8.5.
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_ai_fallback');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  Future<void> enableFallback({bool on = true}) =>
      prefs.setPref(AiPrefKeys.unknownFallback, on);

  DictionarySearchResult empty([String term = 'Proxmox']) =>
      DictionarySearchResult(searchTerm: term);

  DictionarySearchResult withEntries() => DictionarySearchResult(
    searchTerm: '猫',
    entries: <DictionaryEntry>[
      DictionaryEntry(dictionaryName: 'JMdict', word: '猫'),
    ],
  );

  group('gating', () {
    test('does nothing when the setting is off', () async {
      // Default is off, matching the reference: this is opt-in.
      final DictionarySearchResult out = appModel.applyAiFallback(
        empty(),
        hasExplicitBoundary: true,
      );
      expect(out.entries, isEmpty);
      expect(AiFallback.isFallbackResult(out), isFalse);
    });

    test('never replaces a real dictionary result', () async {
      // The explicit requirement: the fallback must not modify or displace
      // results that actually came from a dictionary.
      await enableFallback();
      final DictionarySearchResult real = withEntries();
      final DictionarySearchResult out = appModel.applyAiFallback(
        real,
        hasExplicitBoundary: true,
      );
      expect(identical(out, real), isTrue, reason: 'passed through untouched');
      expect(out.entries.single.dictionaryName, 'JMdict');
    });

    test(
      'synthesises a card when enabled and the boundary is explicit',
      () async {
        await enableFallback();
        final DictionarySearchResult out = appModel.applyAiFallback(
          empty('Proxmox'),
          hasExplicitBoundary: true,
        );
        expect(AiFallback.isFallbackResult(out), isTrue);
        expect(out.entries.single.word, 'Proxmox');
        expect(out.entries.single.dictionaryName, 'AI Fallback');
        expect(
          out.popupJson,
          isNull,
          reason: 'renders through the pure-Dart grouper, never the C++ engine',
        );
      },
    );

    test('keeps a multi-word selection whole', () async {
      // Never reduced to whatever prefix a dictionary partially matched.
      await enableFallback();
      final DictionarySearchResult out = appModel.applyAiFallback(
        empty('machine learning'),
        hasExplicitBoundary: true,
      );
      expect(out.entries.single.word, 'machine learning');
    });

    test('refuses when no boundary was supplied', () async {
      // Without a boundary there is nothing to derive a word from that would be
      // correct in a language without spaces — and this pipeline does not know
      // the language by design.
      await enableFallback();
      final DictionarySearchResult out = appModel.applyAiFallback(
        empty('日本語ですねこれは'),
        hasExplicitBoundary: false,
      );
      expect(AiFallback.isFallbackResult(out), isFalse);
      expect(out.entries, isEmpty);
    });

    test('works for Japanese when the boundary is explicit', () async {
      // The whole point of the §8.5 divergence: upstream disables the fallback
      // for `ja` outright, and Fushi is Japanese-first, so a literal port would
      // ship a feature that can never fire.
      await enableFallback();
      final DictionarySearchResult out = appModel.applyAiFallback(
        empty('持ち込み'),
        hasExplicitBoundary: true,
      );
      expect(AiFallback.isFallbackResult(out), isTrue);
      expect(out.entries.single.word, '持ち込み');
    });

    test('a blank search term yields nothing to explain', () async {
      await enableFallback();
      expect(
        AiFallback.isFallbackResult(
          appModel.applyAiFallback(empty('   '), hasExplicitBoundary: true),
        ),
        isFalse,
      );
    });
  });
}
