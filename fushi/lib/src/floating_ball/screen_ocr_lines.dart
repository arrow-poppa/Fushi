/// 截屏 / 拍照识字的屏幕行：Dart 侧引擎（Google Lens、本地 PaddleOCR）的共同
/// 产物。Android 原生选取层收 [ScreenOcrLine.toWire]（`ScreenOcrLayout.linesFromWire`
/// 读），Dart 选取页收 [screenOcrPageFromLines]。行带所属段落全文与偏移（与原生
/// `ScreenOcrLayout.Line.blockText` 同义），制卡句子从段落里截。
library;

import 'dart:ui';

import 'package:fushi/src/ocr/system_ocr_channel.dart';

/// 一个字：在行文本里的 `[start, end)` 与它在原图上的框（像素）。
class ScreenOcrGlyph {
  const ScreenOcrGlyph({
    required this.start,
    required this.end,
    required this.rect,
  });

  final int start;
  final int end;
  final Rect rect;
}

/// 一条视觉行。
class ScreenOcrLine {
  const ScreenOcrLine({
    required this.text,
    required this.rect,
    required this.isVertical,
    required this.blockText,
    required this.blockOffset,
    required this.glyphs,
  });

  final String text;

  /// 行在原图上的包围盒（像素）。
  final Rect rect;
  final bool isVertical;

  /// 所属段落全文与本行在其中的起始 UTF-16 偏移。
  final String blockText;
  final int blockOffset;

  /// 逐字框；引擎没给逐字位置时为空，选取层按行框均分。
  final List<ScreenOcrGlyph> glyphs;

  /// 原生 `ScreenOcrLayout.linesFromWire` 读的形状。坐标取整到像素；`glyphs`
  /// 是扁平的 `[start, end, left, top, right, bottom, …]`。
  Map<String, Object?> toWire() => <String, Object?>{
    'text': text,
    'left': rect.left.round(),
    'top': rect.top.round(),
    'right': rect.right.round(),
    'bottom': rect.bottom.round(),
    'vertical': isVertical,
    'blockText': blockText,
    'blockOffset': blockOffset,
    'glyphs': <int>[
      for (final ScreenOcrGlyph glyph in glyphs) ...<int>[
        glyph.start,
        glyph.end,
        glyph.rect.left.round(),
        glyph.rect.top.round(),
        glyph.rect.right.round(),
        glyph.rect.bottom.round(),
      ],
    ],
  };
}

/// Dart 选取页（桌面 / iOS 截屏、拍照识字）收的形状。[width] / [height] 是送检
/// 图的像素尺寸。
SystemOcrPageResult screenOcrPageFromLines(
  List<ScreenOcrLine> lines, {
  required int width,
  required int height,
}) => SystemOcrPageResult(
  lines: <SystemOcrTextLine>[
    for (final ScreenOcrLine line in lines)
      SystemOcrTextLine(
        text: line.text,
        rect: line.rect,
        isVertical: line.isVertical,
      ),
  ],
  imageWidth: width,
  imageHeight: height,
);
