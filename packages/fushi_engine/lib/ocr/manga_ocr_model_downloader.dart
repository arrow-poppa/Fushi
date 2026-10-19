/// 漫画 OCR 模型下载器：共享 [ModelFileDownloader] 的薄适配。
///
/// `.part` 临时名 + 原子 rename、HTTP Range 断点续传、主源失败换镜像、系统代理、
/// 进度节流——全部住在 `lib/src/onnx/model_file_downloader.dart`（OCR / ASR 共用）；
/// 本文件只做两件事：把清单里的 [MangaOcrModelFile] 交给共享下载器、把共享的
/// `ModelDownloadEvent` 转成 OCR 接口面上的 [MangaOcrDownloadEvent]。构造签名与
/// `downloadAll` 契约原样保留，`MangaOcrServiceImpl` 与既有测试零改动。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_asr_core/asr_core.dart';

/// 默认进度事件的字节间隔（与共享下载器同值）。
const int kMangaOcrDownloadProgressInterval = kModelDownloadProgressInterval;

/// 模型下载器。[createClient] 可注入（测试指向本地 HttpServer）。
class MangaOcrModelDownloader {
  MangaOcrModelDownloader({
    HttpClient Function()? createClient,
    List<String> Function(MangaOcrModelFile file)? urlCandidates,
    int progressByteInterval = kMangaOcrDownloadProgressInterval,
  }) : _inner = ModelFileDownloader(
          createClient: createClient,
          urlCandidates: _adaptUrlCandidates(urlCandidates),
          progressByteInterval: progressByteInterval,
        );

  final ModelFileDownloader _inner;

  /// 两次进度事件之间至少累积的字节数（首尾事件恒发）。
  int get progressByteInterval => _inner.progressByteInterval;

  /// 把 OCR 类型的候选函数适配成共享层签名。传入的 [MangaOcrModelFile] 经
  /// `downloadAll` 的 `List<MangaOcrModelFile>` 进来，所以这里的向下转型是
  /// 结构上保证成立的，不是猜。不注入时用清单默认的
  /// [mangaOcrModelUrlCandidates]（主源 + hf-mirror）。
  static List<String> Function(DownloadableModelFile file) _adaptUrlCandidates(
    List<String> Function(MangaOcrModelFile file)? urlCandidates,
  ) {
    final List<String> Function(MangaOcrModelFile file) candidates =
        urlCandidates ?? mangaOcrModelUrlCandidates;
    return (DownloadableModelFile file) =>
        candidates(file as MangaOcrModelFile);
  }

  /// 下载清单里所有未就绪文件到 [targetDir]（契约见共享层
  /// [ModelFileDownloader.downloadAll]；就绪判定用 [isMangaOcrModelFileReady]）。
  ///
  /// 清单钉了 [MangaOcrModelFile.sha256] 的文件在最后那条 done 事件之前逐个校验：
  /// 不符的删掉并以 [StateError] 结束，下次重下。没有精确字节数的文件
  /// （[MangaOcrModelFile.expectedBytes] 为 0）只能靠这一步拦住截断与上游换档。
  Stream<MangaOcrDownloadEvent> downloadAll({
    required List<MangaOcrModelFile> files,
    required Directory targetDir,
  }) async* {
    await for (final ModelDownloadEvent event in _inner.downloadAll(
      files: files,
      targetDir: targetDir,
      isReady: isMangaOcrModelFileReady,
    )) {
      if (event.done) {
        await verifyMangaOcrModelHashes(files: files, targetDir: targetDir);
      }
      yield MangaOcrDownloadEvent(
        fileName: event.fileName,
        receivedBytes: event.receivedBytes,
        totalBytes: event.totalBytes,
        done: event.done,
      );
    }
  }
}

/// 按清单的 sha256 校验 [targetDir] 里已下好的文件；不符的删掉并抛 [StateError]。
/// 没钉 sha256 或文件不在的跳过（就绪判定另有 [isMangaOcrModelFileReady]）。
Future<void> verifyMangaOcrModelHashes({
  required List<MangaOcrModelFile> files,
  required Directory targetDir,
}) async {
  for (final MangaOcrModelFile file in files) {
    final String? expected = file.sha256;
    if (expected == null) continue;
    final File target = File(p.join(targetDir.path, file.fileName));
    if (!await target.exists()) continue;
    final Digest actual = await sha256.bind(target.openRead()).first;
    if (actual.toString() == expected.toLowerCase()) continue;
    try {
      await target.delete();
    } on FileSystemException {
      // 删不掉也要报错：坏档不能被当成可用模型。
    }
    throw StateError(
      'download ${file.fileName} sha256 mismatch: got $actual, '
      'expected $expected',
    );
  }
}
