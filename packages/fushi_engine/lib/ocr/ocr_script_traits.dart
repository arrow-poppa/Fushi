/// 识别权重对应的文字体系差异：逐列 CTC / 横排行路径里几处原本按日文写死的
/// 规则（竖排、去振假名、行间不加空格），换成通用 PP-OCR 权重读别的文字时要关掉
/// 或换掉。
///
/// 默认值 [OcrScriptTraits.japanese] 与本类出现前的行为逐项相同，漫画微调权重
/// （`MangaOcrLocalModel.mangaCtc`）不受影响。
library;

/// 一套识别权重读的文字有哪些排版特征。
class OcrScriptTraits {
  const OcrScriptTraits({
    this.verticalText = true,
    this.dropRuby = true,
    this.spaceBetweenLines = false,
    this.rightToLeft = false,
  });

  /// 日漫：竖排、带振假名、行间直接相连。
  static const OcrScriptTraits japanese = OcrScriptTraits();

  /// 会有竖排文字（中日文）。为 false 时一律按横行读：拉丁 / 西里尔等文字的
  /// 细高气泡里是折行的横排短行，转 90° 当竖列读只会得到乱码。
  final bool verticalText;

  /// 去掉比正文细得多的行（振假名）。只有日文有注音；别的文字里细行是小字正文。
  final bool dropRuby;

  /// 行与行之间按文字本身补空格（[joinOcrLineTexts]）。词间有空格的文字折行后，
  /// 直接相连会把行尾词和下一行行首词粘成一个词。
  final bool spaceBetweenLines;

  /// 从右往左书写（阿拉伯文）。CTC 按图从左往右吐字，读出的是视觉顺序，要按
  /// [restoreRtlOcrText] 翻回逻辑顺序。
  final bool rightToLeft;
}

/// 汉字、假名、全角符号这类词间不写空格的字（与 Lens 解码同一个判据）。
bool isSpacelessOcrRune(int rune) =>
    (rune >= 0x3000 && rune <= 0x30FF) ||
    (rune >= 0x31F0 && rune <= 0x31FF) ||
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    (rune >= 0xFF00 && rune <= 0xFFEF) ||
    (rune >= 0x20000 && rune <= 0x3FFFF);

/// 前一行 [before] 与下一行 [after] 之间要不要补一个空格：两边都有字、接缝处
/// 没有现成的空白、前一行不是以连字符断词收尾、接缝两侧都不是 [isSpacelessOcrRune]。
bool needsOcrLineSpace(String before, String after) {
  if (before.isEmpty || after.isEmpty) return false;
  final int last = before.runes.last;
  final int first = after.runes.first;
  if (String.fromCharCode(last).trim().isEmpty) return false;
  if (String.fromCharCode(first).trim().isEmpty) return false;
  if (last == 0x2D || last == 0xAD || last == 0x2010) return false;
  return !isSpacelessOcrRune(last) && !isSpacelessOcrRune(first);
}

/// 把逐行文本拼成块文本：[spaces] 为真时按 [needsOcrLineSpace] 把空格**挂在前
/// 一行的行尾**，返回的行与块文本仍满足 `lines.join() == text`，逐字区间不用
/// 另算偏移。
List<String> joinOcrLineTexts(List<String> lines, {required bool spaces}) {
  if (!spaces || lines.length < 2) return lines;
  return <String>[
    for (int i = 0; i < lines.length; i++)
      i + 1 < lines.length && needsOcrLineSpace(lines[i], lines[i + 1])
          ? '${lines[i]} '
          : lines[i],
  ];
}

final RegExp _rtlKeepOrder = RegExp(r'[a-zA-Z0-9 :*./%+\-]');

/// 从右往左文字的 CTC 结果（视觉顺序）翻回逻辑顺序：整串倒过来，但拉丁字母、
/// 数字和常见符号连成的片段内部保持原序（PaddleOCR `CTCLabelDecode.pred_reverse`
/// 同一个规则）。
String restoreRtlOcrText(String visual) {
  final List<String> pieces = <String>[];
  final StringBuffer run = StringBuffer();
  for (final int rune in visual.runes) {
    final String char = String.fromCharCode(rune);
    if (_rtlKeepOrder.hasMatch(char)) {
      run.write(char);
      continue;
    }
    if (run.isNotEmpty) {
      pieces.add(run.toString());
      run.clear();
    }
    pieces.add(char);
  }
  if (run.isNotEmpty) pieces.add(run.toString());
  return pieces.reversed.join();
}
