/// 设置页选本地截屏识字引擎 / 换模型时，模型没下就问一句并在后台下载。
///
/// 截屏发生时 Fushi 可能在后台，弹不了下载确认，所以在设置页选的那一刻问。下载
/// 走漫画 OCR 的后台下载登记表（`mangaOcrModelDownloadsProvider`）：同一份模型文件、
/// 同一个进度，离开设置页照跑，「设置 › 存储」里也看得到。
library;

import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/floating_ball/screen_ocr_local.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_local_model_labels.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_model_downloads.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

/// [model] 已下好或正在下载时什么都不做；否则确认后开始后台下载。
Future<void> offerScreenOcrLocalModelDownload(
  BuildContext context,
  WidgetRef ref,
  MangaOcrLocalModel model,
) async {
  if (await isScreenOcrLocalModelReady(model)) return;
  final MangaOcrModelDownloads downloads = ref.read(
    mangaOcrModelDownloadsProvider,
  );
  if (downloads.isActive(model)) return;
  final MangaOcrService service = createMangaOcrService(localModel: model);
  final MangaOcrModelStatus status = await service.modelStatus();
  if (!context.mounted) return;
  final bool accepted = await showFushiConfirmDialog(
    context: context,
    title: t.floating_ball_screen_ocr_local_download_title,
    message: t.floating_ball_screen_ocr_local_download_body(
      name: localModelLabel(model),
      size: FushiByteFormat.bytes(
        math.max(0, status.totalBytes - status.obtainedBytes),
      ),
    ),
    icon: FushiIcons.download,
    confirmLabel: t.manga_ocr_download,
  );
  if (accepted) downloads.start(model, service);
}
