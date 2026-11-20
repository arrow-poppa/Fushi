/// 截屏 / 拍照识字的本地引擎：PaddleOCR 权重（与漫画 / 视频字幕 OCR 共用同一份
/// 下载，`MangaOcrLocalModel`）跑在 ONNX Runtime 上，整张截屏交
/// `PpOcrScreenReader`（引擎包）读成屏幕行。
///
/// 推理会话建一次要几百毫秒，所以读完不立刻关：同一个模型在 [kScreenOcrLocalIdle]
/// 内再用直接复用，过了就关掉还内存；换模型时先关旧的。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/floating_ball/screen_ocr_lines.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/ocr_host_bindings.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:fushi_engine/ocr/ppocr_screen_reader.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 读完一张后会话最多留多久。
const Duration kScreenOcrLocalIdle = Duration(minutes: 2);

/// 选中的模型还没下完（设置页会引导下载；截屏时只能退回系统 OCR）。
class ScreenOcrLocalModelMissing implements Exception {
  const ScreenOcrLocalModelMissing(this.model);

  final MangaOcrLocalModel model;

  @override
  String toString() => 'ScreenOcrLocalModelMissing(${model.key})';
}

/// [model] 的文件是否都在本机（不量大小、不校验内容，下载器转正前已校验）。
Future<bool> isScreenOcrLocalModelReady(MangaOcrLocalModel model) async {
  final Directory dir = await model.modelsDirectory();
  return model.manifest.every(
    (MangaOcrModelFile file) =>
        isMangaOcrModelFileReady(File(p.join(dir.path, file.fileName))),
  );
}

/// 一次本地识别的结果：屏幕行 + 送检图尺寸。
class ScreenOcrLocalRead {
  const ScreenOcrLocalRead({
    required this.lines,
    required this.width,
    required this.height,
  });

  final List<ScreenOcrLine> lines;
  final int width;
  final int height;
}

class _LoadedReader {
  _LoadedReader(this.model, this.detector, this.reader, this._sessions);

  final MangaOcrLocalModel model;
  final PpOcrLineDetectorModel detector;
  final PpOcrScreenReader reader;
  final List<OcrSession> _sessions;

  Future<void> close() async {
    for (final OcrSession session in _sessions) {
      try {
        await session.close();
      } catch (error, stack) {
        ErrorLogService.instance.log('screen_ocr_local.close', error, stack);
      }
    }
  }
}

/// 本地截屏识别器（全应用一份，见 [instance]）。
class ScreenOcrLocalEngine {
  ScreenOcrLocalEngine({
    OcrSessionFactory Function()? factoryBuilder,
    Duration idle = kScreenOcrLocalIdle,
  }) : _factoryBuilder = factoryBuilder,
       _idle = idle;

  static final ScreenOcrLocalEngine instance = ScreenOcrLocalEngine();

  final OcrSessionFactory Function()? _factoryBuilder;
  final Duration _idle;

  _LoadedReader? _loaded;
  Future<_LoadedReader>? _loading;
  Timer? _idleTimer;

  /// 串行化：同一时刻只读一张，会话不并发使用、也不会在用的时候被空闲计时关掉。
  Future<void> _tail = Future<void>.value();

  /// 识别 [bytes]（PNG / JPEG）。模型没下完抛 [ScreenOcrLocalModelMissing]（先于
  /// 解图检查，没下模型时不白解一张整屏图）；图解不开与其余错误照常抛给调用方，
  /// 由它退回系统 OCR。
  Future<ScreenOcrLocalRead> recognize(
    Uint8List bytes, {
    required MangaOcrLocalModel model,
  }) {
    final Completer<ScreenOcrLocalRead> done = Completer<ScreenOcrLocalRead>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await _recognize(bytes, model));
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  Future<ScreenOcrLocalRead> _recognize(
    Uint8List bytes,
    MangaOcrLocalModel model,
  ) async {
    _idleTimer?.cancel();
    try {
      final _LoadedReader loaded = await _readerFor(model);
      final img.Image? image = await compute(img.decodeImage, bytes);
      if (image == null) {
        throw const FormatException('screen OCR image could not be decoded');
      }
      final List<PpOcrScreenLine> lines = await loaded.reader.read(image);
      return ScreenOcrLocalRead(
        lines: <ScreenOcrLine>[
          for (final PpOcrScreenLine line in lines)
            screenOcrLineFromLocal(line),
        ],
        width: image.width,
        height: image.height,
      );
    } finally {
      _idleTimer = Timer(_idle, () => unawaited(close()));
    }
  }

  Future<_LoadedReader> _readerFor(MangaOcrLocalModel model) async {
    // 行检测器是全局选择（[mangaOcrLineDetectorChoice]），设置页改了下一张就换。
    final PpOcrLineDetectorModel detector = mangaOcrLineDetectorChoice;
    final _LoadedReader? loaded = _loaded;
    if (loaded != null &&
        loaded.model == model &&
        loaded.detector == detector) {
      return loaded;
    }
    if (loaded != null) {
      _loaded = null;
      await loaded.close();
    }
    final Future<_LoadedReader> loading = _loading ??= _open(model, detector);
    try {
      return _loaded = await loading;
    } finally {
      _loading = null;
    }
  }

  Future<_LoadedReader> _open(
    MangaOcrLocalModel model,
    PpOcrLineDetectorModel detector,
  ) async {
    if (!await isScreenOcrLocalModelReady(model)) {
      throw ScreenOcrLocalModelMissing(model);
    }
    final OcrSessionFactory Function()? builder =
        _factoryBuilder ?? ocrSessionFactoryBuilder;
    if (builder == null) throw StateError('ocr_session_factory_unavailable');
    final OcrSessionFactory factory = builder();
    Set<OcrExecutionProvider> available = const <OcrExecutionProvider>{};
    try {
      available = await factory.availableAcceleratedProviders();
    } catch (error, stack) {
      // 探测失败按只有 CPU 处理：截屏识字不该因此整个不可用。
      ErrorLogService.instance.log('screen_ocr_local.providers', error, stack);
    }
    List<OcrExecutionProvider> providers(OcrModelKind kind) =>
        selectOcrExecutionProviders(
          kind: kind,
          platform: _platform(),
          availableProviders: available,
        );
    final Directory dir = await model.modelsDirectory();
    final OcrSession det = await factory.createSession(
      p.join(dir.path, model.lineDetectorFileName(detector)),
      providers: providers(OcrModelKind.detection),
    );
    OcrSession? rec;
    try {
      rec = await factory.createSession(
        p.join(dir.path, model.recognizerFileName),
        providers: providers(OcrModelKind.recognition),
      );
      final String dict = await File(
        p.join(dir.path, model.dictFileName),
      ).readAsString();
      return _LoadedReader(
        model,
        detector,
        PpOcrScreenReader.fromModels(
          detector: PpOcrLineDetector(det),
          recognizer: PpOcrLineRecognizer(
            rec,
            vocab: buildPpOcrCtcVocab(parsePpOcrCharacterDict(dict)),
          ),
          traits: model.scriptTraits,
        ),
        <OcrSession>[det, rec],
      );
    } catch (_) {
      try {
        await rec?.close();
      } finally {
        await det.close();
      }
      rethrow;
    }
  }

  /// 关掉会话（空闲计时到了 / 宿主收起悬浮球）。下次识别重新建。
  Future<void> close() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final _LoadedReader? loaded = _loaded;
    _loaded = null;
    await loaded?.close();
  }

  static OcrPlatform _platform() {
    if (Platform.isWindows) return OcrPlatform.windows;
    if (Platform.isMacOS) return OcrPlatform.macos;
    if (Platform.isAndroid) return OcrPlatform.android;
    if (Platform.isIOS) return OcrPlatform.ios;
    return OcrPlatform.linux;
  }
}

/// 引擎包的屏幕行 → 宿主的屏幕行（Flutter 几何类型）。
ScreenOcrLine screenOcrLineFromLocal(PpOcrScreenLine line) => ScreenOcrLine(
  text: line.text,
  rect: _rect(line.rect),
  isVertical: line.vertical,
  blockText: line.blockText,
  blockOffset: line.blockOffset,
  glyphs: <ScreenOcrGlyph>[
    for (final OcrGlyphBox glyph in line.glyphs)
      ScreenOcrGlyph(
        start: glyph.start,
        end: glyph.end,
        rect: _rect(glyph.rect),
      ),
  ],
);

Rect _rect(OcrRect rect) =>
    Rect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom);
