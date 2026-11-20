// 「点一个字 → 查哪个词」在空格分词文本（英语等拉丁文）上的取词规则。
//
// 日语分词器 [JapaneseLanguage.wordFromIndex] 从被点字起向后做词典最长匹配：
// 这对日文成立，对英文却会从单词中间起查——点 "world" 的 'r' 查的是 "rld…"，
// 匹配不到就退化成单个字母 'r'。截屏识字（字框按行宽等分估计，几乎总落在词中）
// 与悬浮字幕点词最容易踩到。
//
// 规则与视频字幕点词（`subtitleTranscriptLookupSpan`）同口径：拉丁单词字符先把
// 起点回退到词首，其余脚本起点就是被点字本身。
library;

import 'package:fushi_dictionary/fushi_dictionary.dart';

final RegExp _latinWordCharRegExp = RegExp(
  r'^[\p{Script=Latin}0-9]',
  unicode: true,
);

/// 组合附加符（NFD 的 é = e + U+0301）：本身不是拉丁脚本，但属于前一个字母。
final RegExp _combiningMarkRegExp = RegExp(r'^\p{M}', unicode: true);

/// 一个字位簇（或单个 UTF-16 码元）是否是「拉丁单词字符」：拉丁字母（含重音字母）
/// 或 ASCII 数字。CJK / 空白 / 标点恒为 false。
bool isLatinWordGrapheme(String grapheme) {
  if (grapheme.isEmpty) return false;
  return _latinWordCharRegExp.hasMatch(grapheme);
}

bool _isLatinWordUnit(String text, int i) {
  final String unit = text[i];
  return _latinWordCharRegExp.hasMatch(unit) ||
      _combiningMarkRegExp.hasMatch(unit);
}

/// [index]（UTF-16 下标）所在拉丁单词的 `[start, end)`；被点的不是拉丁单词字符时
/// 返回 null。
({int start, int end})? latinWordRangeAt(String text, int index) {
  if (index < 0 || index >= text.length) return null;
  if (!_latinWordCharRegExp.hasMatch(text[index])) return null;
  int start = index;
  while (start > 0 && _isLatinWordUnit(text, start - 1)) {
    start--;
  }
  // 起点不能停在组合附加符上（它属于更前面那个非拉丁字）。
  while (start < index && _combiningMarkRegExp.hasMatch(text[start])) {
    start++;
  }
  int end = index + 1;
  while (end < text.length && _isLatinWordUnit(text, end)) {
    end++;
  }
  return (start: start, end: end);
}

/// 从整句 [text] 与被点字的 UTF-16 下标 [index] 取出要查的词。
///
/// - 非拉丁字：原样交给 [wordFromIndex]（默认日语分词器：词典最长匹配）。
/// - 拉丁单词字符：从**词首**起交给 [wordFromIndex]，引擎在空格分词语言上只在词
///   边界切（`native/fushidicts/fushidicts_src/scan/word_scan.cpp`），匹配到
///   `look forward to` 这类短语就用短语；匹配不到整词（没装英语词典 / 引擎未就绪）
///   时用整个单词，而不是退化成单个字母。
///
/// 越界返回空串，调用方据此回退整句。
String lookupWordAtIndex(
  String text,
  int index, {
  String Function({required String text, required int index})? wordFromIndex,
}) {
  if (index < 0 || index >= text.length) return '';
  final String Function({required String text, required int index}) scan =
      wordFromIndex ?? JapaneseLanguage.instance.wordFromIndex;
  final ({int start, int end})? range = latinWordRangeAt(text, index);
  if (range == null) return scan(text: text, index: index);
  final String word = text.substring(range.start, range.end);
  final String matched = scan(text: text, index: range.start);
  return matched.trim().length > word.length ? matched : word;
}

/// 引擎对查询串 [text] 的最长匹配长度（UTF-16 码元，0 = 没匹配到 / 引擎未就绪）。
typedef LookupMatchedUnits = int Function(String text);

int _engineMatchedUnits(String text) {
  if (!FushiDicts.isInitialized) return 0;
  final List<FushiLookupResult> results = FushiDicts.instance.lookup(
    text,
    maxResults: 1,
  );
  return results.isEmpty ? 0 : results.first.matched.length;
}

bool _isHyphenGrapheme(String grapheme) => grapheme == '-' || grapheme == '‐';

/// 只把探测串截到这么多个字位：引擎窗口最多 [FushiDicts.maxHyphenatedScanLength]。
const int _kHyphenProbeGraphemes = 64;

/// 点在拉丁单词上时扫描查词的起点（字位下标）：词首；若这个词是连字符复合词的
/// 后一段（`gaming-mode` 里的 `mode`），且词典里有**盖住被点字**的复合词，起点再
/// 退到复合词的那一段开头。
///
/// 不能一律退到复合词开头：词典没收 `gaming-mode` 时，点 `mode` 会查出 `gaming`
/// ——不是用户点的词。所以从最左边的那一段起逐个探测（[matchedUnits]，默认问
/// 引擎），第一段的匹配一直延伸到被点字才采用；都不够就停在被点的那个词的词首。
/// 引擎未就绪时探测恒为 0，行为与旧的「只退到词首」一致。
///
/// 被点的不是拉丁单词字符时原样返回 [index]。
int latinLookupStartAt(
  List<String> graphemes,
  int index, {
  LookupMatchedUnits? matchedUnits,
}) {
  if (index < 0 || index >= graphemes.length) return index;
  if (!isLatinWordGrapheme(graphemes[index])) return index;
  int wordStart = index;
  while (wordStart > 0 && isLatinWordGrapheme(graphemes[wordStart - 1])) {
    wordStart--;
  }
  // 复合词里更靠前的各段开头，由近到远。
  final List<int> segmentStarts = <int>[];
  int cursor = wordStart;
  while (cursor >= 2 &&
      _isHyphenGrapheme(graphemes[cursor - 1]) &&
      isLatinWordGrapheme(graphemes[cursor - 2])) {
    cursor--;
    while (cursor > 0 && isLatinWordGrapheme(graphemes[cursor - 1])) {
      cursor--;
    }
    segmentStarts.add(cursor);
  }
  if (segmentStarts.isEmpty) return wordStart;
  final LookupMatchedUnits probe = matchedUnits ?? _engineMatchedUnits;
  for (final int start in segmentStarts.reversed) {
    final String suffix = graphemes
        .skip(start)
        .take(_kHyphenProbeGraphemes)
        .join();
    final int unitsThroughTapped = graphemes
        .sublist(start, index + 1)
        .join()
        .length;
    if (probe(suffix) >= unitsThroughTapped) return start;
  }
  return wordStart;
}
