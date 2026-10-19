/// 截屏 / 拍照识字的 Google Lens 引擎。
///
/// Lens 按段落回结果（一段一句、逐字命中区带 UTF-16 区间），系统 OCR 按视觉行回。
/// 这里把段落按逐字区拆回视觉行，产出与系统 OCR 同形的行：Android 原生选取层
/// 收 [ScreenOcrLensLine.toWire]，Dart 选取页收 [screenOcrPageFromLens]。行带所属
/// 段落全文与偏移（与原生 `ScreenOcrLayout.Line.blockText` 同义），制卡句子从段落里截。
library;

import 'dart:typed_data';
import 'dart:ui';

import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 一个字：在行文本里的 `[start, end)` 与它在原图上的框（像素）。
class ScreenOcrLensGlyph {
  const ScreenOcrLensGlyph({
    required this.start,
    required this.end,
    required this.rect,
  });

  final int start;
  final int end;
  final Rect rect;
}

/// 一条视觉行。
class ScreenOcrLensLine {
  const ScreenOcrLensLine({
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

  /// 逐字框；Lens 没给逐字区时为空，原生侧按行框均分。
  final List<ScreenOcrLensGlyph> glyphs;

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
      for (final ScreenOcrLensGlyph glyph in glyphs) ...<int>[
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

/// Lens 结果 → 视觉行，按段落顺序、段内按阅读顺序。
///
/// 段内逐字区已按阅读顺序排好；字的中心离开当前行的横向（竖排看纵向）跨度就是
/// 折到了下一行。没有逐字区的段落整段当一行。
List<ScreenOcrLensLine> screenOcrLinesFromLens(MokuroImage image) {
  final List<ScreenOcrLensLine> out = <ScreenOcrLensLine>[];
  for (final MokuroBlock block in image.blocks) {
    final String sentence = block.lines.join('\n');
    if (sentence.trim().isEmpty) continue;
    final List<MangaOcrTextRegion> regions =
        <MangaOcrTextRegion>[
          for (final MangaOcrTextRegion region
              in block.regions ?? const <MangaOcrTextRegion>[])
            if (region.utf16Start >= 0 &&
                region.utf16End > region.utf16Start &&
                region.utf16End <= sentence.length &&
                !region.rectangle.isEmpty)
              region,
        ]..sort(
          (MangaOcrTextRegion a, MangaOcrTextRegion b) =>
              a.utf16Start.compareTo(b.utf16Start),
        );
    if (regions.isEmpty) {
      final Rect rect = _rect(block.rectangle);
      if (rect.isEmpty) continue;
      out.add(
        ScreenOcrLensLine(
          text: sentence,
          rect: rect,
          isVertical: block.isVertical,
          blockText: sentence,
          blockOffset: 0,
          glyphs: const <ScreenOcrLensGlyph>[],
        ),
      );
      continue;
    }
    final List<List<MangaOcrTextRegion>> visualLines =
        <List<MangaOcrTextRegion>>[];
    Rect? current;
    for (final MangaOcrTextRegion region in regions) {
      final Rect rect = _rect(region.rectangle);
      final bool wraps =
          current != null &&
          (block.isVertical
              ? rect.center.dx < current.left || rect.center.dx > current.right
              : rect.center.dy < current.top ||
                    rect.center.dy > current.bottom);
      if (current == null || wraps) {
        visualLines.add(<MangaOcrTextRegion>[region]);
        current = rect;
      } else {
        visualLines.last.add(region);
        current = current.expandToInclude(rect);
      }
    }
    for (final List<MangaOcrTextRegion> line in visualLines) {
      final int start = line.first.utf16Start;
      final int end = line.last.utf16End;
      if (end <= start) continue;
      Rect bounds = _rect(line.first.rectangle);
      for (final MangaOcrTextRegion region in line.skip(1)) {
        bounds = bounds.expandToInclude(_rect(region.rectangle));
      }
      out.add(
        ScreenOcrLensLine(
          text: sentence.substring(start, end),
          rect: bounds,
          isVertical: block.isVertical,
          blockText: sentence,
          blockOffset: start,
          glyphs: <ScreenOcrLensGlyph>[
            for (final MangaOcrTextRegion region in line)
              ScreenOcrLensGlyph(
                start: region.utf16Start - start,
                end: region.utf16End - start,
                rect: _rect(region.rectangle),
              ),
          ],
        ),
      );
    }
  }
  return out;
}

/// Dart 选取页（桌面 / iOS 截屏、拍照识字）收的形状。
SystemOcrPageResult screenOcrPageFromLens(MokuroImage image) =>
    SystemOcrPageResult(
      lines: <SystemOcrTextLine>[
        for (final ScreenOcrLensLine line in screenOcrLinesFromLens(image))
          SystemOcrTextLine(
            text: line.text,
            rect: line.rect,
            isVertical: line.isVertical,
          ),
      ],
      imageWidth: image.size.width.round(),
      imageHeight: image.size.height.round(),
    );

/// 送一张截图给 Lens。失败（断网、接口变了、图解不开）记日志并返回 null，调用方
/// 退回系统 OCR——联网引擎不该让截屏识字整个不可用。
Future<MokuroImage?> recognizeScreenWithLens(
  Uint8List bytes, {
  required String language,
  GoogleLensMangaOcrRunner? runner,
}) async {
  try {
    return await (runner ?? GoogleLensMangaOcrService()).recognizePageBytes(
      bytes,
      relativeUrl: 'screen_ocr.jpg',
      language: normalizeLensLanguage(language),
    );
  } catch (error, stack) {
    ErrorLogService.instance.log('floating_ball.screen_ocr_lens', error, stack);
    return null;
  }
}

Rect _rect(MokuroRect rect) =>
    Rect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom);
