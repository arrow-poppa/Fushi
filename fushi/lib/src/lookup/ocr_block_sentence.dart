/// BUG-3487：从截屏识字（ML Kit）的一个 text block 里截出包含被点字的整句，作 app 外
/// 查词窗制卡的 `{sentence}`。
///
/// 块全文是原生侧把块内各行按 `\n` 拼起来的（`ScreenOcrLayout.blockLineOffsets`）。
/// 竖排 / 折行的长句被拆成多行，只拿被点那一行做句子会只剩半句；反过来一行里也可能
/// 装着两句话。截取规则：
///
/// - **换行不是句界**：OCR 的行是排版折行，不是作者断句。拼回时 CJK 之间直接相连，
///   两侧都是拉丁字母 / 数字时补一个空格（英文折行处原本就是空格）。
/// - **句末标点**：`。｡！？!?．‼⁇⁈⁉`，以及后面跟空白或块尾的半角 `.`（`3.5` 之类
///   不算）。句末标点后紧跟的闭括号 / 引号（`」』）"”` 等）和连续的句末标点都归前一句。
/// - **闭括号紧接开括号**（`」「`，中间只隔换行 / 空白）也是句界：对白一条一条排，
///   每条不一定带句号。
/// - `…` / `‥` **不算句界**：日文里它多半在句中（「あの……実は」），按它切会切出半句。
/// - 截出的句子超过 [maxLength] 个 UTF-16 码元（多半是整块没有标点的菜单 / 列表），
///   返回 null，让调用方回落为被点的那一行。
library;

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

bool _isLatinWordChar(String ch) {
  final int c = ch.codeUnitAt(0);
  return (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      (c >= 0xC0 && c <= 0x24F);
}

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

/// 把块里的 [start, end) 一段拼回一句：去掉 OCR 折行，CJK 直接相连，拉丁词之间补空格。
String _joinLines(String segment) {
  final List<String> lines = segment
      .split(RegExp(r'\r?\n|\r'))
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty)
      .toList();
  final StringBuffer out = StringBuffer();
  for (final String line in lines) {
    if (out.isNotEmpty) {
      final String before = out.toString();
      final String prev = before[before.length - 1];
      if (_isLatinWordChar(prev) && _isLatinWordChar(line[0])) out.write(' ');
    }
    out.write(line);
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
  final bool space =
      _isLatinWordChar(head[head.length - 1]) &&
      _isLatinWordChar(continuation[0]);
  final String joined = '$head${space ? ' ' : ''}$continuation';
  if (joined.length > maxLength) return null;
  return joined;
}
