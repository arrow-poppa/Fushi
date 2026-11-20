/// 整张截屏的本地 PP-OCR 识别（截屏取词 / 拍照识字的「本地」引擎）。
///
/// 漫画流水线先用漫画检测器找气泡、再在气泡里切行；截屏没有气泡，所以这里直接
/// 在整张图上跑 PP-OCRv6 行检测，把挨着的行按距离归成段落，再逐行交 CTC 识别：
///
/// 1. 行检测：长边缩到 [kPpOcrScreenDetMaxSide] 再检（1080×2400 的手机截屏原尺寸
///    进 DB 检测器要多花几倍时间，行框缩回原图坐标后精度够用）；
/// 2. 归段：同方向、粗细相近、彼此紧挨着的行并成一段（[groupPpOcrScreenLines]），
///    段落是制卡句子的上下文；
/// 3. 逐行识别：竖列逆时针转 90° 当横行读（与 `ctc_column_ocr_recognizer.dart`
///    同一个做法），CTC token 位置换成逐字命中格（`ocr_glyph_boxes.dart`）；
/// 4. 段内拼接按 [OcrScriptTraits]：词间有空格的文字补空格、从右往左的文字翻回
///    逻辑顺序。
///
/// 产出的行形状与系统 OCR / Lens 的屏幕行相同（行文本 + 行框 + 所属段落全文与
/// 偏移 + 行内逐字框），宿主直接交给选取层。
library;

import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'package:fushi_engine/ocr/ocr_glyph_boxes.dart';
import 'package:fushi_engine/ocr/ocr_line_layout.dart';
import 'package:fushi_engine/ocr/ocr_script_traits.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';

/// 行检测前截屏长边的上限（像素）。
const int kPpOcrScreenDetMaxSide = 1280;

/// 行框边长小于它（像素）的检测结果不读：多是图标边角与噪点。
const double kPpOcrScreenMinLineSide = 4;

/// 识别置信度（吐字帧里最小的 softmax 概率）低于它的行丢掉：检测器把图标、
/// 分隔线当成了字时，CTC 会以很低的把握吐出一两个字。
const double kPpOcrScreenMinConfidence = 0.3;

/// 一条屏幕行。坐标是原截图像素；[glyphs] 的区间按本行文本计。
class PpOcrScreenLine {
  const PpOcrScreenLine({
    required this.text,
    required this.rect,
    required this.vertical,
    required this.blockText,
    required this.blockOffset,
    required this.glyphs,
  });

  final String text;
  final OcrRect rect;
  final bool vertical;

  /// 所属段落全文与本行在其中的起始 UTF-16 偏移。
  final String blockText;
  final int blockOffset;

  /// 逐字框；拿不到位置时为空，选取层按行框均分。
  final List<OcrGlyphBox> glyphs;
}

/// 一段：阅读顺序排好的行框 + 方向。
class PpOcrScreenBlock {
  const PpOcrScreenBlock({required this.lines, required this.vertical});

  final List<OcrRect> lines;
  final bool vertical;
}

/// 两行算不算同一段：同方向、粗细比不超过 1.6，并且
/// - 上下（竖排是左右）相邻：间距不超过 0.8 倍行厚，沿阅读方向有重叠；或
/// - 同一排的碎片：跨轴方向重叠过半，沿阅读方向的空隙不超过 1.5 倍行厚。
///
/// 系数按手机截屏的行距 / 字距取，偏宽：漏并比错并好补（错并只是句子上下文
/// 多了一行）。
bool _sameScreenBlock(OcrRect a, OcrRect b, {required bool vertical}) {
  final double ta = vertical ? a.width : a.height;
  final double tb = vertical ? b.width : b.height;
  final double thick = math.max(ta, tb);
  if (thick <= 0 || math.min(ta, tb) * 1.6 < thick) return false;
  // 沿阅读方向（横行是 x，竖列是 y）与跨轴方向的区间。
  final double aAlong0 = vertical ? a.top : a.left;
  final double aAlong1 = vertical ? a.bottom : a.right;
  final double bAlong0 = vertical ? b.top : b.left;
  final double bAlong1 = vertical ? b.bottom : b.right;
  final double aCross0 = vertical ? a.left : a.top;
  final double aCross1 = vertical ? a.right : a.bottom;
  final double bCross0 = vertical ? b.left : b.top;
  final double bCross1 = vertical ? b.right : b.bottom;
  final double alongOverlap =
      math.min(aAlong1, bAlong1) - math.max(aAlong0, bAlong0);
  final double crossOverlap =
      math.min(aCross1, bCross1) - math.max(aCross0, bCross0);
  if (crossOverlap >= 0.5 * math.min(ta, tb)) {
    // 同一排：沿阅读方向的空隙（重叠为负）。
    return -alongOverlap <= 1.5 * thick;
  }
  final double crossGap = -crossOverlap;
  return alongOverlap > 0 && crossGap <= 0.8 * thick;
}

/// 截屏行框 → 段落。[verticalText] 为 false 时所有行都当横行。段按左上角排序
/// （上到下、再左到右），段内行按阅读顺序。
List<PpOcrScreenBlock> groupPpOcrScreenLines(
  List<OcrRect> lines, {
  required bool verticalText,
}) {
  final List<bool> vertical = <bool>[
    for (final OcrRect line in lines)
      verticalText && line.height >= line.width * kPpLineVerticalRatio,
  ];
  final List<int> parent = List<int>.generate(lines.length, (int i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  for (int i = 0; i < lines.length; i++) {
    for (int j = i + 1; j < lines.length; j++) {
      if (vertical[i] != vertical[j]) continue;
      if (_sameScreenBlock(lines[i], lines[j], vertical: vertical[i])) {
        parent[find(j)] = find(i);
      }
    }
  }
  final Map<int, List<int>> groups = <int, List<int>>{};
  for (int i = 0; i < lines.length; i++) {
    groups.putIfAbsent(find(i), () => <int>[]).add(i);
  }
  final List<PpOcrScreenBlock> blocks = <PpOcrScreenBlock>[
    for (final List<int> members in groups.values)
      PpOcrScreenBlock(
        vertical: vertical[members.first],
        lines: orderOcrLinesForReading(<OcrRect>[
          for (final int i in members) lines[i],
        ], vertical: vertical[members.first]),
      ),
  ];
  double topOf(PpOcrScreenBlock b) =>
      b.lines.map((OcrRect r) => r.top).reduce(math.min);
  double leftOf(PpOcrScreenBlock b) =>
      b.lines.map((OcrRect r) => r.left).reduce(math.min);
  blocks.sort((PpOcrScreenBlock a, PpOcrScreenBlock b) {
    final int byTop = topOf(a).compareTo(topOf(b));
    return byTop != 0 ? byTop : leftOf(a).compareTo(leftOf(b));
  });
  return blocks;
}

/// 截屏识别器。行检测与行识别以函数注入（生产接 [PpOcrLineDetector] /
/// [PpOcrLineRecognizer]，测试接假的）。
class PpOcrScreenReader {
  PpOcrScreenReader({
    required Future<List<OcrRect>> Function(img.Image image) detectLines,
    required Future<PpOcrPositionedLine> Function(img.Image line) readLine,
    this.traits = OcrScriptTraits.japanese,
  }) : _detectLines = detectLines,
       _readLine = readLine;

  /// 生产装配：行检测与行识别各一个 ORT 会话。
  factory PpOcrScreenReader.fromModels({
    required PpOcrLineDetector detector,
    required PpOcrLineRecognizer recognizer,
    OcrScriptTraits traits = OcrScriptTraits.japanese,
  }) => PpOcrScreenReader(
    detectLines: (img.Image image) async => <OcrRect>[
      for (final PpTextLine line in await detector.detect(image)) line.rect,
    ],
    readLine: recognizer.recognizeLinePositioned,
    traits: traits,
  );

  final Future<List<OcrRect>> Function(img.Image image) _detectLines;
  final Future<PpOcrPositionedLine> Function(img.Image line) _readLine;
  final OcrScriptTraits traits;

  /// 识别整张截屏 [page]，按段落顺序返回屏幕行。
  Future<List<PpOcrScreenLine>> read(img.Image page) async {
    final List<OcrRect> detected = await _detectScaled(page);
    final List<PpOcrScreenLine> out = <PpOcrScreenLine>[];
    for (final PpOcrScreenBlock block in groupPpOcrScreenLines(
      detected,
      verticalText: traits.verticalText,
    )) {
      final List<_ScreenRead> reads = <_ScreenRead>[];
      for (final OcrRect line in block.lines) {
        final _ScreenRead? read = await _readOne(
          page,
          line,
          vertical: block.vertical,
        );
        if (read != null) reads.add(read);
      }
      if (reads.isEmpty) continue;
      final List<String> texts = joinOcrLineTexts(<String>[
        for (final _ScreenRead read in reads) read.text,
      ], spaces: traits.spaceBetweenLines);
      final String blockText = texts.join();
      int offset = 0;
      for (int i = 0; i < reads.length; i++) {
        out.add(
          PpOcrScreenLine(
            // 补上的行尾空格只属于段落文本，行文本保持识别原样。
            text: reads[i].text,
            rect: reads[i].rect,
            vertical: block.vertical,
            blockText: blockText,
            blockOffset: offset,
            glyphs: reads[i].glyphs,
          ),
        );
        offset += texts[i].length;
      }
    }
    return out;
  }

  /// 长边超过 [kPpOcrScreenDetMaxSide] 时缩小后检测，行框换回原图坐标并夹进
  /// 原图；太小的框丢掉。
  Future<List<OcrRect>> _detectScaled(img.Image page) async {
    final int longSide = math.max(page.width, page.height);
    final double scale = longSide > kPpOcrScreenDetMaxSide
        ? kPpOcrScreenDetMaxSide / longSide
        : 1.0;
    final img.Image input = scale < 1
        ? img.copyResize(
            page,
            width: math.max(1, (page.width * scale).round()),
            height: math.max(1, (page.height * scale).round()),
            interpolation: img.Interpolation.linear,
          )
        : page;
    final double sx = page.width / input.width;
    final double sy = page.height / input.height;
    return <OcrRect>[
      for (final OcrRect rect in await _detectLines(input))
        OcrRect(
          left: rect.left * sx,
          top: rect.top * sy,
          right: rect.right * sx,
          bottom: rect.bottom * sy,
        ).clamp(page.width.toDouble(), page.height.toDouble()),
    ]..removeWhere(
      (OcrRect r) =>
          r.width < kPpOcrScreenMinLineSide ||
          r.height < kPpOcrScreenMinLineSide,
    );
  }

  /// 裁出一行交识别器；读不出字或把握太低时返回 null。
  Future<_ScreenRead?> _readOne(
    img.Image page,
    OcrRect line, {
    required bool vertical,
  }) async {
    final OcrBlockCrop? crop = cropOcrBlock(page, line);
    if (crop == null) return null;
    // copyRotate 的正角是顺时针，-90 即逆时针 90°：列顶转到左边。
    final PpOcrPositionedLine read = await _readLine(
      vertical ? img.copyRotate(crop.image, angle: -90) : crop.image,
    );
    if (read.text.trim().isEmpty) return null;
    final double? confidence = read.confidence;
    if (confidence != null && confidence < kPpOcrScreenMinConfidence) {
      return null;
    }
    final OcrRect rect = OcrRect(
      left: crop.x.toDouble(),
      top: crop.y.toDouble(),
      right: (crop.x + crop.image.width).toDouble(),
      bottom: (crop.y + crop.image.height).toDouble(),
    );
    if (traits.rightToLeft) {
      // 翻序后 token 位置与文字对不上，不出字格。
      return _ScreenRead(
        text: restoreRtlOcrText(read.text),
        rect: rect,
        glyphs: const <OcrGlyphBox>[],
      );
    }
    return _ScreenRead(
      text: read.text,
      rect: rect,
      glyphs:
          ocrLineGlyphBoxes(
            text: read.text,
            tokens: read.tokens,
            line: rect,
            vertical: vertical,
            alongOrigin: (vertical ? crop.y : crop.x).toDouble(),
            utf16Offset: 0,
          ) ??
          const <OcrGlyphBox>[],
    );
  }
}

class _ScreenRead {
  const _ScreenRead({
    required this.text,
    required this.rect,
    required this.glyphs,
  });

  final String text;
  final OcrRect rect;
  final List<OcrGlyphBox> glyphs;
}
