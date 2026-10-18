## BUG-3522 · 连字符复合词：超过 16 码点查不到整词；点后一段时不会退到复合词开头
- **报告**：2026-10-18（用户：`gaming-mode`、`state-of-the-art` 这类连字符词能不能当一个词查）
- **真实性**：✅ 真 bug，两处。
  - 引擎扫描窗口恒为 `FushiDicts.defaultScanLength` = 16 码点（`packages/fushi_dictionary/lib/src/engine/fushidicts.dart`，修前 `int scanLength = defaultScanLength`），候选前缀又不切在两个字母之间（`native/fushidicts/fushidicts_src/scan/word_scan.cpp`），于是 `jack-of-all-trades`（18）这类复合词永远查不到整词，书本 / 截屏识字 / 字幕都一样。（`state-of-the-art` 恰好 16，本来就能查到。）
  - 源文本条 / 截屏识字首查（`sourceLookupSuffixAt`）与视频字幕点词（`subtitleTranscriptLookupSpan`）把起点退到词首时遇 `-` 即停：点 `gaming-mode` 的 `mode` 只查 `mode`。书本阅读器（`selectFromPosition`，`-` 不是扫描分界）则一律退到复合词开头，词典没收复合词时点 `mode` 会查出 `gaming`——书本这条本次未改。
- **[x] ① 已修复**（`6b7e3c36a4`）— `FushiDicts.scanLengthFor`（`fushidicts.dart:712`）：串首是长于 16 码点的连字符复合词时窗口撑到恰好装下（上限 48），`lookup` / `lookupPopupJson` 不传 `scanLength` 时默认用它，日文匹配长度缓存键（`JapaneseLanguage.matchLengthCacheKey`）同步用它；其余查询窗口不变。`latinLookupStartAt`（`fushi/lib/src/lookup/latin_word_lookup.dart:106`）：点复合词的后一段时从最左一段起问引擎，匹配一直延伸到被点字才退到那一段开头，否则停在被点词的词首；引擎未就绪时与旧规则一致。源文本条与视频字幕共用它。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/hyphenated_compound_lookup_test.dart`（窗口：普通查询不变、18 / 21 码点复合词、上限、孤立连字符、缓存键；起点：词典有 / 没有复合词、多段复合词取最左可用段、首段与普通词不变、引擎未就绪回到旧规则；源文本条与字幕同一规则）。
- **备注**：Android 原生查词窗（`PopupDictActivity` → `FushiBridge.lookupJson`）的 Kotlin 默认窗口仍是 16，未改。未在真机复测（本环境无 Android 设备）。
