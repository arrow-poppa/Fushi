/// BUG-3487：从截屏识字（ML Kit）的一个 text block 里截出包含被点字的整句，作 app 外
/// 查词窗制卡的 `{sentence}`。
///
/// 块全文是原生侧把块内各行按 `\n` 拼起来的（`ScreenOcrLayout.blockLineOffsets`）。
/// 竖排 / 折行的长句被拆成多行，只拿被点那一行做句子会只剩半句；反过来一行里也可能
/// 装着两句话。截取规则：
///
/// - **换行不是句界**：OCR 的行是排版折行，不是作者断句。拼回时任一侧是不靠空格
///   分词的文字（CJK / 假名 / 泰文等）直接相连，上一行以连字符结尾也直接相连，其余
///   （拉丁、西里尔、希腊等，含行尾是标点的情形）补一个空格——这些文字折行处原本
///   就是空格（BUG-3521）。
/// - **句末标点**：`。｡！？!?．‼⁇⁈⁉`，以及后面跟空白或块尾的半角 `.`（`3.5` 之类
///   不算）。句末标点后紧跟的闭括号 / 引号（`」』）"”` 等）和连续的句末标点都归前一句。
/// - **闭括号紧接开括号**（`」「`，中间只隔换行 / 空白）也是句界：对白一条一条排，
///   每条不一定带句号。
/// - `…` / `‥` **不算句界**：日文里它多半在句中（「あの……実は」），按它切会切出半句。
/// - 截出的句子超过 [maxLength] 个 UTF-16 码元（多半是整块没有标点的菜单 / 列表），
///   返回 null，让调用方回落为被点的那一行。
library;

import 'package:fushi/src/lookup/sentence_extraction.dart';

const int kOcrBlockSentenceMaxLength = 200;

const Set<String> _terminators = <String>{
  '。',
  '｡',
  '！',
  '？',
  '!',
  '?',
  '．',
  '‼',
  '⁇',
  '⁈',
  '⁉',
};

const Set<String> _closers = <String>{
  '」',
  '』',
  '）',
  ')',
  '】',
  '〕',
  '〉',
  '》',
  '］',
  ']',
  '〟',
  '”',
  '’',
  '"',
  "'",
};

const Set<String> _bracketClosers = <String>{'」', '』'};
const Set<String> _bracketOpeners = <String>{'「', '『'};

bool _isLineBreak(String ch) => ch == '\n' || ch == '\r';

bool _isSpace(String ch) =>
    ch == ' ' || ch == '\t' || ch == '　' || _isLineBreak(ch);

/// [i] 处的字符结束一句时，返回句子在块里的结束位置（不含），否则 -1。
int _sentenceEndAt(String block, int i) {
  final String ch = block[i];
  final bool asciiPeriod = ch == '.';
  if (!_terminators.contains(ch) && !asciiPeriod) {
    if (_bracketClosers.contains(ch)) {
      int j = i + 1;
      while (j < block.length && _isSpace(block[j])) {
        j++;
      }
      if (j < block.length && _bracketOpeners.contains(block[j])) return i + 1;
    }
    return -1;
  }
  int j = i + 1;
  while (j < block.length &&
      (_terminators.contains(block[j]) ||
          block[j] == '.' ||
          _closers.contains(block[j]))) {
    j++;
  }
  // 半角句点只在后面是空白 / 块尾时才算句末（排除 3.5、e.g 中段、网址）。
  if (asciiPeriod && j < block.length && !_isSpace(block[j])) return -1;
  return j;
}

/// 不靠空格分词的文字（汉字、假名、全角标点、泰 / 老 / 高棉 / 缅文）：这类字两侧
/// 的 OCR 折行拼回时不补空格。按 UTF-16 码元判：代理对多半是 CJK 扩展区汉字，
/// 一并算进来。
bool _isUnspacedScriptUnit(int c) =>
    (c >= 0x0E00 && c <= 0x0EFF) || // 泰文、老挝文
    (c >= 0x1000 && c <= 0x109F) || // 缅甸文
    (c >= 0x1780 && c <= 0x17FF) || // 高棉文
    (c >= 0x2E80 && c <= 0x2FFF) || // CJK 部首
    (c >= 0x3000 && c <= 0x30FF) || // CJK 标点、假名
    (c >= 0x31F0 && c <= 0x31FF) || // 片假名音标扩展
    (c >= 0x3400 && c <= 0x4DBF) || // CJK 扩展 A
    (c >= 0x4E00 && c <= 0x9FFF) || // CJK 统一汉字
    (c >= 0xD800 && c <= 0xDFFF) || // 代理对（CJK 扩展 B 起）
    (c >= 0xF900 && c <= 0xFAFF) || // CJK 兼容汉字
    (c >= 0xFF00 && c <= 0xFFEF); // 全角 / 半角形式

/// 块里有没有不靠空格分词的文字（见 [_isUnspacedScriptUnit]）。
bool _hasUnspacedScript(String text) {
  for (int i = 0; i < text.length; i++) {
    if (_isUnspacedScriptUnit(text.codeUnitAt(i))) return true;
  }
  return false;
}

/// 两段已去空白的 OCR 行拼接时中间放什么。
///
/// 任一侧是不靠空格分词的文字时直接相连；上一行以连字符结尾（词被折开，或本来
/// 就是连字符复合词）时也直接相连，保留连字符；其余情形（拉丁、西里尔、希腊等
/// 靠空格分词的文字，包括行尾是逗号 / 句号这类标点）补一个空格。此前只在两侧都是
/// 拉丁字母时补空格，「Hello,」+「world」会拼成「Hello,world」，西里尔 / 希腊文的
/// 折行一律粘成一个词。
String _lineSeparator(String previous, String next) {
  final int last = previous.codeUnitAt(previous.length - 1);
  if (_isUnspacedScriptUnit(last) ||
      _isUnspacedScriptUnit(next.codeUnitAt(0))) {
    return '';
  }
  if (last == 0x2D || last == 0xAD || last == 0x2010) return '';
  return ' ';
}

/// 把块里的 [start, end) 一段拼回一句：去掉 OCR 折行，规则见 [_lineSeparator]。
String _joinLines(String segment) {
  final List<String> lines = segment
      .split(RegExp(r'\r?\n|\r'))
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty)
      .toList();
  final StringBuffer out = StringBuffer();
  String previous = '';
  for (final String line in lines) {
    if (previous.isNotEmpty) out.write(_lineSeparator(previous, line));
    out.write(line);
    previous = line;
  }
  return out.toString();
}

/// 块全文 [block] 里包含 UTF-16 下标 [index] 那个字的那一句的 [start, end)（块内下标，
/// 未拼行、未去空白）。调用方保证 [index] 在块内。
({int start, int end}) _sentenceBoundsAt(String block, int index) {
  int start = 0;
  int end = block.length;
  int i = 0;
  while (i < block.length) {
    final int sentenceEnd = _sentenceEndAt(block, i);
    if (sentenceEnd < 0) {
      i++;
      continue;
    }
    if (sentenceEnd > index) {
      end = sentenceEnd;
      break;
    }
    start = sentenceEnd;
    i = sentenceEnd;
  }
  return (start: start, end: end);
}

/// 块全文 [block] 里包含 UTF-16 下标 [index] 那个字的整句（已拼掉 OCR 折行、去首尾
/// 空白）。下标越界、截出空串或长于 [maxLength] 时返回 null。
String? ocrBlockSentenceAt(
  String block,
  int index, {
  int maxLength = kOcrBlockSentenceMaxLength,
}) {
  if (block.isEmpty || index < 0 || index >= block.length) return null;
  final ({int start, int end}) bounds = _sentenceBoundsAt(block, index);
  final String sentence = _joinLines(block.substring(bounds.start, bounds.end));
  if (sentence.isEmpty || sentence.length > maxLength) return null;
  return sentence;
}

/// 截屏识字被点的那一行 [line]（位于块全文 [block] 的 UTF-16 偏移 [lineOffset] 处）
/// 加上**行尾那一句在下面几行里的剩余部分**，按 OCR 折行规则拼成一串。
///
/// 一句话折到下一行时，只给被点的那一行会让查词窗既看不到下一行，也查不出跨行的
/// 词（「天」在行尾、「気」在下一行行首时只能查到「天」）。返回值以 [line] 去掉
/// 行尾空白后的原文开头——行内的 UTF-16 下标原样有效，调用方点字 / 扫描查词的
/// 下标不用换算。
///
/// 返回 null（调用方保持整行不变）的情形：块与行对不上、行尾那一句在本行内就已
/// 结束、后面没有内容，或拼出来超过 [maxLength] 个 UTF-16 码元（多半是没有标点的
/// 菜单 / 列表）。
String? ocrLineWithSentenceContinuation(
  String block,
  int lineOffset,
  String line, {
  int maxLength = kOcrBlockSentenceMaxLength,
}) {
  final String head = line.trimRight();
  if (head.isEmpty || lineOffset < 0) return null;
  final int lineEnd = lineOffset + line.length;
  if (lineEnd > block.length || block.substring(lineOffset, lineEnd) != line) {
    return null;
  }
  final int lastUnit = lineOffset + head.length - 1;
  final int sentenceEnd = _sentenceBoundsAt(block, lastUnit).end;
  if (sentenceEnd <= lineEnd) return null;
  final String continuation = _joinLines(block.substring(lineEnd, sentenceEnd));
  if (continuation.isEmpty) return null;
  final String joined =
      '$head${_lineSeparator(head, continuation)}$continuation';
  if (joined.length > maxLength) return null;
  return joined;
}

/// 查词窗源文本条按整块显示时的上限（UTF-16 码元）：再长多半是整页正文 / 菜单，
/// 回落为「被点那一行 + 句子续行」。
const int kOcrSpacedBlockMaxLength = 1000;

/// 靠空格分词的文字（拉丁、西里尔、希腊……）的截屏识字：把被点那一行所在 text
/// block 的**全部行**拼成一串（规则见 [_lineSeparator]），并给出被点字在拼接结果里
/// 的 UTF-16 下标。
///
/// 这类文字的折行处本来就是词界，整块拼回不会把不相干的词粘在一起，源文本条上
/// 可以直接点块里任何一行的词，制卡 / AI 的句子也能从拼好的整块里按句截。日文 /
/// 中文等不靠空格分词的文字一个块常常是一整段对白或一整页，不走这条路
/// （返回 null，调用方用 [ocrLineWithSentenceContinuation]）。
///
/// 返回 null 的情形：块里有不靠空格分词的文字、块只有一行、行与块对不上、
/// [unitInLine] 越界、或拼出来超过 [maxLength]。
({String text, int unit})? ocrSpacedBlockAt(
  String block,
  int lineOffset,
  String line,
  int unitInLine, {
  int maxLength = kOcrSpacedBlockMaxLength,
}) {
  if (lineOffset < 0 || unitInLine < 0 || unitInLine >= line.length) {
    return null;
  }
  final int lineEnd = lineOffset + line.length;
  if (lineEnd > block.length || block.substring(lineOffset, lineEnd) != line) {
    return null;
  }
  if (_hasUnspacedScript(block) || !block.contains(RegExp(r'[\r\n]'))) {
    return null;
  }
  final int target = lineOffset + unitInLine;
  final StringBuffer out = StringBuffer();
  String previous = '';
  int mapped = -1;
  int lineStart = 0;
  while (lineStart <= block.length) {
    int end = lineStart;
    while (end < block.length && !_isLineBreak(block[end])) {
      end++;
    }
    final String raw = block.substring(lineStart, end);
    final String trimmed = raw.trim();
    if (trimmed.isNotEmpty) {
      if (previous.isNotEmpty) out.write(_lineSeparator(previous, trimmed));
      final int contentStart = lineStart + (raw.length - raw.trimLeft().length);
      if (mapped < 0 && target < contentStart + trimmed.length) {
        // 点在行首空白上时落到这一行的第一个字。
        final int within = target - contentStart;
        mapped = out.length + (within < 0 ? 0 : within);
      }
      out.write(trimmed);
      previous = trimmed;
    }
    if (end >= block.length) break;
    lineStart = end + 1;
    if (block[end] == '\r' &&
        lineStart < block.length &&
        block[lineStart] == '\n') {
      lineStart++;
    }
  }
  final String text = out.toString();
  if (text.isEmpty || text.length > maxLength) return null;
  // 点在行尾空白上：落到这一行最后一个字。
  if (mapped < 0) mapped = text.length - 1;
  return (text: text, unit: mapped);
}

/// 整块模式（[ocrSpacedBlockAt] 拼好的整块）里 UTF-16 下标 [unit] 那个字所在的句子，
/// 与书本阅读器同一套句读：PDF 阅读器用的 [extractSentenceAt]，句读表与 EPUB 阅读器
/// 的 `fushiSelection.getSentenceContext` 逐字节一致（`。！？.!?` 断句，句末后的闭
/// 括号 / 。、等跟着前一句）。整块已拼掉 OCR 折行，换行不会再被当成句界——与
/// 书本把换行当空白同一个效果。
///
/// 与上面 [ocrBlockSentenceAt] 的块规则刻意不同：那套为漫画 / 游戏对白调过（`」「`
/// 相接也断句、`3.5` 里的点不断句），靠空格分词的文字改走书本的规则，让截屏识字、
/// 书本、PDF 的句子是同一个。截不出（空）时返回 null。
String? ocrSpacedBlockSentenceAt(String joined, int unit) {
  if (unit < 0 || unit >= joined.length) return null;
  final String sentence = extractSentenceAt(joined, unit, 1).sentence;
  return sentence.isEmpty ? null : sentence;
}
