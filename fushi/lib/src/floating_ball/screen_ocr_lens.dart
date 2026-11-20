/// 截屏 / 拍照识字的 Google Lens 引擎。
///
/// Lens 按段落回结果（一段一句、逐字命中区带 UTF-16 区间），系统 OCR 按视觉行回。
/// 这里把段落按逐字区拆回视觉行，产出屏幕行（`screen_ocr_lines.dart`）。
library;

import 'dart:typed_data';
import 'dart:ui';

import 'package:fushi/src/floating_ball/screen_ocr_lines.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// Lens 结果 → 视觉行，按段落顺序、段内按阅读顺序。
///
/// 段内逐字区已按阅读顺序排好；字的中心离开当前行的横向（竖排看纵向）跨度就是
/// 折到了下一行。没有逐字区的段落整段当一行。
List<ScreenOcrLine> screenOcrLinesFromLens(MokuroImage image) {
  final List<ScreenOcrLine> out = <ScreenOcrLine>[];
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
        ScreenOcrLine(
          text: sentence,
          rect: rect,
          isVertical: block.isVertical,
          blockText: sentence,
          blockOffset: 0,
          glyphs: const <ScreenOcrGlyph>[],
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
        ScreenOcrLine(
          text: sentence.substring(start, end),
          rect: bounds,
          isVertical: block.isVertical,
          blockText: sentence,
          blockOffset: start,
          glyphs: <ScreenOcrGlyph>[
            for (final MangaOcrTextRegion region in line)
              ScreenOcrGlyph(
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
    screenOcrPageFromLines(
      screenOcrLinesFromLens(image),
      width: image.size.width.round(),
      height: image.size.height.round(),
    );

/// 截屏识字 Lens 语言偏好的「自动」值（默认）。
const String kScreenOcrLensLanguageAuto = 'auto';

/// 偏好值 → 请求里的 Lens 语言。Lens 不管提示语言都会认出画面上的文字，空白也
/// 按文字本身处理（见 `GoogleLensProtocol.decodeResponse`），所以「自动」只是像
/// Chrome 那样报设备语言；认不出的设备语言回退英语。
String resolveScreenOcrLensLanguage(String stored, {Locale? deviceLocale}) {
  if (stored != kScreenOcrLensLanguageAuto) {
    return normalizeLensLanguage(stored);
  }
  return normalizeLensLanguage(
    (deviceLocale ?? PlatformDispatcher.instance.locale).languageCode,
    fallback: 'en',
  );
}

/// 送一张截图给 Lens。失败（断网、接口变了、图解不开）记日志并返回 null，调用方
/// 退回系统 OCR——联网引擎不该让截屏识字整个不可用。[language] 是偏好值（可为
/// [kScreenOcrLensLanguageAuto]）。
Future<MokuroImage?> recognizeScreenWithLens(
  Uint8List bytes, {
  required String language,
  GoogleLensMangaOcrRunner? runner,
}) async {
  try {
    return await (runner ?? GoogleLensMangaOcrService()).recognizePageBytes(
      bytes,
      relativeUrl: 'screen_ocr.jpg',
      language: resolveScreenOcrLensLanguage(language),
    );
  } catch (error, stack) {
    ErrorLogService.instance.log('floating_ball.screen_ocr_lens', error, stack);
    return null;
  }
}

Rect _rect(MokuroRect rect) =>
    Rect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom);
