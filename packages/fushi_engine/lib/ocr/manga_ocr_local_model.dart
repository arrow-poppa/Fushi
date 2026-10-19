/// Selectable local recognizers: per-column CTC with the manga fine-tune
/// (Japanese, the default) plus the stock PaddleOCR recognizers for other
/// scripts (PP-OCRv6 small / tiny and the PP-OCRv5 Korean / Cyrillic / Greek /
/// Arabic models). Every model shares the comic text
/// detector and the PP-OCRv6 small line detector and runs on ONNX Runtime CPU
/// on all five platforms. The kha-white manga-ocr model and Baberu were both
/// removed in 2026-10; their keys fall back to the default.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_fingerprint.dart' as model_fp;
import 'package:fushi_engine/ocr/ocr_script_traits.dart';

/// 默认本地模型：逐列 CTC（五端都能跑、约 42 MB）。
const MangaOcrLocalModel kDefaultMangaOcrLocalModel =
    MangaOcrLocalModel.mangaCtc;

enum MangaOcrLocalModel {
  mangaCtc('manga_ctc'),

  /// PP-OCRv6 small rec：中日文 + 带变音符的拉丁文（罗马尼亚语的 ș ț 只有它有）。
  ppocrV6Small('ppocr_v6_small'),

  /// PP-OCRv6 tiny rec：拉丁字母语言（英、葡、西、法、德、波兰……）。
  ppocrV6Tiny('ppocr_v6_tiny'),
  ppocrV5Korean('ppocr_v5_korean'),
  ppocrV5Cyrillic('ppocr_v5_cyrillic'),
  ppocrV5Greek('ppocr_v5_greek'),
  ppocrV5Arabic('ppocr_v5_arabic');

  const MangaOcrLocalModel(this.key);
  final String key;

  /// 已删除模型的 key（`manga_ocr`：2026-10 删除的 kha-white manga-ocr；
  /// `manga_ocr_cuda`：Windows 本地 Python + torch CUDA 档；`baberu`：2026-10
  /// 删除的 genshiai-daichi/baberu-ocr）与未知值一律落回
  /// [kDefaultMangaOcrLocalModel]：旧偏好 / 备份 / 互联对端可能还带着这些 key。
  static MangaOcrLocalModel fromKey(String key) {
    for (final MangaOcrLocalModel model in values) {
      if (model.key == key) return model;
    }
    return kDefaultMangaOcrLocalModel;
  }

  /// A preference restored from Windows must not select unsupported models on
  /// another device. Settings, imports and inference share this resolution.
  static MangaOcrLocalModel forPlatform(String key, {String? operatingSystem}) {
    final MangaOcrLocalModel model = fromKey(key);
    return (operatingSystem ?? Platform.operatingSystem) == 'windows' ||
            model.availableOnAllPlatforms
        ? model
        : kDefaultMangaOcrLocalModel;
  }

  /// 纯 ONNX Runtime CPU 推理、出包五端都能跑的模型；只给 Windows 的模型在
  /// 这里返回 false（目前没有：2026-10 删掉的 Baberu 曾是唯一一个）。
  bool get availableOnAllPlatforms => true;

  /// 识别权重读的文字有哪些排版特征（竖排 / 振假名 / 行间空格 / 书写方向）。
  OcrScriptTraits get scriptTraits => switch (this) {
    mangaCtc => OcrScriptTraits.japanese,
    // 中日文竖排与注音照旧；同一套权重也读拉丁文，行间空格按文字本身补，读中日
    // 文时一个都不会补。
    ppocrV6Small => const OcrScriptTraits(spaceBetweenLines: true),
    ppocrV6Tiny ||
    ppocrV5Korean ||
    ppocrV5Cyrillic ||
    ppocrV5Greek => const OcrScriptTraits(
      verticalText: false,
      dropRuby: false,
      spaceBetweenLines: true,
    ),
    ppocrV5Arabic => const OcrScriptTraits(
      verticalText: false,
      dropRuby: false,
      spaceBetweenLines: true,
      rightToLeft: true,
    ),
  };

  /// 页面补检（`page_text_sweep.dart`）只留日文过半的块，且只有漫画微调权重对
  /// 装饰字读得可靠；别的权重不建补检。
  bool get sweepsMissedText => this == mangaCtc;

  /// 块识别权重的落盘名（逐列 CTC 与横排行路径共用这一个会话）。
  String get recognizerFileName => switch (this) {
    mangaCtc => kMangaCtcRecFileName,
    ppocrV6Small => kPpOcrRecFileName,
    _ => _ppOcrSpec.recFileName,
  };

  /// 识别权重的 CTC 字典（`inference.yml`）落盘名。
  String get dictFileName => switch (this) {
    mangaCtc || ppocrV6Small => kPpOcrRecDictFileName,
    _ => _ppOcrSpec.dictFileName,
  };

  _PpOcrRecSpec get _ppOcrSpec => switch (this) {
    ppocrV6Tiny => _kPpOcrV6TinyRec,
    ppocrV5Korean => _kPpOcrV5KoreanRec,
    ppocrV5Cyrillic => _kPpOcrV5CyrillicRec,
    ppocrV5Greek => _kPpOcrV5GreekRec,
    ppocrV5Arabic => _kPpOcrV5ArabicRec,
    mangaCtc || ppocrV6Small => throw StateError('$this has no extra rec spec'),
  };

  List<MangaOcrModelFile> get manifest => switch (this) {
    mangaCtc => kMangaCtcOcrModelManifest,
    ppocrV6Small => <MangaOcrModelFile>[
      ..._kPpOcrSharedDetectors,
      const MangaOcrModelFile(
        fileName: kPpOcrRecFileName,
        url:
            'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx/'
            'resolve/$kPpOcrRecRevision/inference.onnx',
        expectedBytes: 21159378,
        role: MangaOcrModelRole.recognizer,
      ),
      _kPpOcrSmallRecDict,
    ],
    _ => <MangaOcrModelFile>[..._kPpOcrSharedDetectors, ..._ppOcrSpec.files],
  };

  String get cacheSignature => switch (this) {
    // 不能以 kLocalMangaOcrEngineSignature 开头：那样已删除的 manga-ocr 留下的 v4
    // 旧缓存会被当成可补几何的来源，把 manga-ocr 的文字冒充成 CTC 的结果
    // （BUG-2813 的升级路径）。
    mangaCtc => 'local-onnx-ctc-kellenok-v0.2-$kMangaOcrPipelineRevision',
    ppocrV6Small =>
      'local-onnx-ctc-ppocrv6-small-${kPpOcrRecRevision.substring(0, 8)}'
          '-$kMangaOcrPipelineRevision',
    _ =>
      'local-onnx-ctc-$key-${_ppOcrSpec.revision.substring(0, 8)}'
          '-$kMangaOcrPipelineRevision',
  };

  /// 每个模型一个兄弟目录（`<support>/ocr_models/<name>`），删一个不波及另一个。
  /// 父目录由 [model_fp.defaultMangaOcrModelsDir]（旧 manga-ocr 目录）的 parent
  /// 求得。
  Future<Directory> modelsDirectory() async {
    final Directory legacy = await model_fp.defaultMangaOcrModelsDir();
    final String sibling = switch (this) {
      mangaCtc => 'manga-ctc',
      _ => key.replaceAll('_', '-'),
    };
    return Directory(p.join(legacy.parent.path, sibling));
  }
}

/// 按 [model] 的模型目录 / 清单 / 缓存签名解析本机已安装模型的逐页缓存签名
/// （只读缓存的消费方：向导探测 / 重开恢复；BUG-1173）。
///
/// 数据根解析在没有 platform channel 的纯 Dart 测试环境会抛，这里退回该模型的
/// 基线签名 [MangaOcrLocalModel.cacheSignature]——含义明确：「拿不到已安装模型
/// 身份」，此时只会命中修复前的旧缓存目录，绝不会把新旧模型的结果混起来。
Future<String> resolveInstalledLocalMangaOcrEngineSignature({
  MangaOcrLocalModel model = kDefaultMangaOcrLocalModel,
}) async {
  try {
    return await model_fp.resolveLocalMangaOcrEngineSignature(
      await model.modelsDirectory(),
      manifest: model.manifest,
      baseSignature: model.cacheSignature,
    );
  } catch (_) {
    return model.cacheSignature;
  }
}

/// 已删除模型留在 `<support>/ocr_models/` 下的兄弟目录名。
///
/// `manga-cuda`：2026-10 删除的 Windows 本地 Python + torch cu128 档，一套
/// 4~10 GB；`manga-baberu`：2026-10 删除的 Baberu（约 270 MB，目录里那份
/// `detector-v4-s_int8.onnx` 是它自己的副本，`manga-ctc` 另有一份，整目录删不波及
/// CTC）。枚举值没了之后，设置页与「设置 › 存储」都不再有能删它们的入口。
const List<String> kRemovedMangaOcrModelDirNames = <String>[
  'manga-cuda',
  'manga-baberu',
];

/// 已删除的 kha-white manga-ocr 本地模型留在旧目录 `<support>/ocr_models/manga/`
/// 里的专属文件（各自的 `.part` 断点残留一并删）。
///
/// 同目录里的 PP-OCRv6 三件套（`ppocrv6_small_det.onnx` /
/// `ppocrv6_small_rec.onnx` / `ppocrv6_small_rec.yml`）**刻意不在此列**：
/// galgame 查词校准 OCR（`gal_lookup_calibration_ocr.dart`）会复用这个目录里
/// 已有的那三份，删了等于让它再下一份 31 MB。
const List<String> kRemovedMangaOcrLegacyFileNames = <String>[
  'encoder_model.onnx',
  'decoder_model.onnx',
  'vocab.txt',
  'cross_kv.onnx',
  'decoder_kv.onnx',
  'detector-v4-s_int8.onnx',
  model_fp.kMangaOcrModelFingerprintFileName,
];

/// 旧 manga-ocr 目录名（[model_fp.defaultMangaOcrModelsDir] 的 basename）。
const String kLegacyMangaOcrModelDirName = 'manga';

/// 尽力删掉已删除模型的遗留数据，返回实际删掉的**条目数**：每删掉一个
/// [kRemovedMangaOcrModelDirNames] 目录、[kRemovedMangaOcrLegacyFileNames] 里的
/// 一个文件（或它的 `.part`）、以及删空后的旧 `manga/` 目录本身，各计 1。
///
/// 宿主启动时调一次即可（幂等：不在就什么都不做）。删除失败（文件被占用 /
/// 权限）只记日志不抛：不能因为清理旧档挡住启动，下次启动会再试。
/// [ocrModelsRoot] 默认是 `<support>/ocr_models`，测试注入临时目录。
Future<int> deleteRemovedMangaOcrModelDirs({Directory? ocrModelsRoot}) async {
  final Directory root;
  try {
    root = ocrModelsRoot ?? (await model_fp.defaultMangaOcrModelsDir()).parent;
  } catch (error, stack) {
    // 启动时 fire-and-forget 调用：数据根解析失败不能变成未处理异常。
    engineLog.log('deleteRemovedMangaOcrModelDirs', error, stack);
    return 0;
  }
  int deleted = 0;
  for (final String name in kRemovedMangaOcrModelDirNames) {
    final Directory dir = Directory(p.join(root.path, name));
    try {
      if (!await dir.exists()) continue;
      await dir.delete(recursive: true);
      deleted++;
    } on FileSystemException catch (error, stack) {
      engineLog.log('deleteRemovedMangaOcrModelDirs[$name]', error, stack);
    }
  }
  deleted += await _deleteRemovedMangaOcrLegacyFiles(
    Directory(p.join(root.path, kLegacyMangaOcrModelDirName)),
  );
  return deleted;
}

/// 从旧 `manga/` 目录删 [kRemovedMangaOcrLegacyFileNames]（含 `.part`）；目录删空
/// 了连目录一起删。返回删掉的条目数。
Future<int> _deleteRemovedMangaOcrLegacyFiles(Directory legacy) async {
  try {
    if (!await legacy.exists()) return 0;
  } on FileSystemException catch (error, stack) {
    engineLog.log('deleteRemovedMangaOcrModelDirs[manga]', error, stack);
    return 0;
  }
  int deleted = 0;
  for (final String name in kRemovedMangaOcrLegacyFileNames) {
    for (final String fileName in <String>[name, '$name.part']) {
      final File file = File(p.join(legacy.path, fileName));
      try {
        if (!await file.exists()) continue;
        await file.delete();
        deleted++;
      } on FileSystemException catch (error, stack) {
        engineLog.log(
          'deleteRemovedMangaOcrModelDirs[manga/$fileName]',
          error,
          stack,
        );
      }
    }
  }
  try {
    if (await legacy.list().isEmpty) {
      await legacy.delete();
      deleted++;
    }
  } on FileSystemException catch (error, stack) {
    engineLog.log('deleteRemovedMangaOcrModelDirs[manga]', error, stack);
  }
  return deleted;
}

/// 漫画逐列 CTC 的列识别权重：Kellenok/PP-OCRv6_manga 的 rec v0.2（Apache-2.0，在
/// PP-OCRv6 small rec 上用 Manga109-s 与 AnimeText 微调）。与 PP-OCRv6 small rec 同
/// 输入契约、同一份 18710 项词表，字典沿用 [kPpOcrRecDictFileName]。钉 revision 的
/// 理由同 PP-OCRv6（`main` 可变）；该 revision 下 LFS sha256 为
/// de12c84c63e62c80339e882e675983d886670dcb6f0147e1ed041afd6fa81888。
const String kMangaCtcRecRevision = 'ba1d479e8a61a20e8318c9758c73fbbbd290b98d';
const String kMangaCtcRecFileName = 'kellenok_manga_rec_v0.2.onnx';

/// 逐列 CTC：检测器 + PP-OCRv6 small det（列 / 行检测）+ 字典 + 漫画 rec（竖列与横行
/// 都用它读）。约 42 MB。
const List<MangaOcrModelFile> kMangaCtcOcrModelManifest = <MangaOcrModelFile>[
  MangaOcrModelFile(
    fileName: 'detector-v4-s_int8.onnx',
    url:
        'https://huggingface.co/ogkalu/comic-text-and-bubble-detector/'
        'resolve/main/detector-v4-s_int8.onnx',
    expectedBytes: 11120765,
    role: MangaOcrModelRole.detector,
  ),
  MangaOcrModelFile(
    fileName: kPpOcrDetFileName,
    url:
        'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_det_onnx/'
        'resolve/$kPpOcrDetRevision/inference.onnx',
    expectedBytes: 9880512,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: kPpOcrRecDictFileName,
    url:
        'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx/'
        'resolve/$kPpOcrRecRevision/inference.yml',
    expectedBytes: 150579,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: kMangaCtcRecFileName,
    url:
        'https://huggingface.co/Kellenok/PP-OCRv6_manga/'
        'resolve/$kMangaCtcRecRevision/rec/manga_rec_v0.2.onnx',
    expectedBytes: 21167540,
    role: MangaOcrModelRole.recognizer,
  ),
];

/// 通用 PP-OCR 识别权重共用的两个检测器（与 [kMangaCtcOcrModelManifest] 前两项
/// 同一份文件）：漫画页的文字块检测 + 块内行 / 列检测。
const List<MangaOcrModelFile> _kPpOcrSharedDetectors = <MangaOcrModelFile>[
  MangaOcrModelFile(
    fileName: 'detector-v4-s_int8.onnx',
    url:
        'https://huggingface.co/ogkalu/comic-text-and-bubble-detector/'
        'resolve/main/detector-v4-s_int8.onnx',
    expectedBytes: 11120765,
    role: MangaOcrModelRole.detector,
  ),
  MangaOcrModelFile(
    fileName: kPpOcrDetFileName,
    url:
        'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_det_onnx/'
        'resolve/$kPpOcrDetRevision/inference.onnx',
    expectedBytes: 9880512,
    role: MangaOcrModelRole.recognizer,
  ),
];

const MangaOcrModelFile _kPpOcrSmallRecDict = MangaOcrModelFile(
  fileName: kPpOcrRecDictFileName,
  url:
      'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx/'
      'resolve/$kPpOcrRecRevision/inference.yml',
  expectedBytes: 150579,
  role: MangaOcrModelRole.recognizer,
);

/// PaddlePaddle 官方 HF 仓里的一套识别权重（`inference.onnx` + 同目录
/// `inference.yml` 字典，Apache-2.0），钉 revision；onnx 的 sha256 是该 revision
/// 下的 LFS 哈希。
///
/// 这几个文件的精确字节数没有核实过（本仓开发环境到不了 HF API），
/// `expectedBytes` 记 0、完整性靠 sha256；`estimatedBytes` 只给设置页展示，按同一
/// 权重 FP16 转换产物的 2.003 倍估（PP-OCRv6 small 两个已知文件实测比例）。
class _PpOcrRecSpec {
  const _PpOcrRecSpec({
    required this.repo,
    required this.revision,
    required this.recFileName,
    required this.dictFileName,
    required this.sha256,
    required this.estimatedRecBytes,
    required this.estimatedDictBytes,
  });

  final String repo;
  final String revision;
  final String recFileName;
  final String dictFileName;
  final String sha256;
  final int estimatedRecBytes;
  final int estimatedDictBytes;

  List<MangaOcrModelFile> get files => <MangaOcrModelFile>[
    MangaOcrModelFile(
      fileName: recFileName,
      url: 'https://huggingface.co/$repo/resolve/$revision/inference.onnx',
      expectedBytes: 0,
      estimatedBytes: estimatedRecBytes,
      sha256: sha256,
      role: MangaOcrModelRole.recognizer,
    ),
    MangaOcrModelFile(
      fileName: dictFileName,
      url: 'https://huggingface.co/$repo/resolve/$revision/inference.yml',
      expectedBytes: 0,
      estimatedBytes: estimatedDictBytes,
      role: MangaOcrModelRole.recognizer,
    ),
  ];
}

const _PpOcrRecSpec _kPpOcrV6TinyRec = _PpOcrRecSpec(
  repo: 'PaddlePaddle/PP-OCRv6_tiny_rec_onnx',
  revision: '2612ab37152ae0a677521bae4e1e3d4fb4cf7c30',
  recFileName: 'ppocrv6_tiny_rec.onnx',
  dictFileName: 'ppocrv6_tiny_rec.yml',
  sha256: '9ef676d6ed3c88256a2d92c640c44f25b0c40947e111b14b8be8f594091563e6',
  estimatedRecBytes: 4447000,
  estimatedDictBytes: 56000,
);

const _PpOcrRecSpec _kPpOcrV5KoreanRec = _PpOcrRecSpec(
  repo: 'PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx',
  revision: '5c6f574b8e2230adf4287b33e736d71b9fabd28e',
  recFileName: 'ppocrv5_korean_rec.onnx',
  dictFileName: 'ppocrv5_korean_rec.yml',
  sha256: '92f0b7785e64fc9090106a241cf4c1eb97472824558272751b88a2a4476d3a08',
  estimatedRecBytes: 13392000,
  estimatedDictBytes: 96000,
);

const _PpOcrRecSpec _kPpOcrV5CyrillicRec = _PpOcrRecSpec(
  repo: 'PaddlePaddle/cyrillic_PP-OCRv5_mobile_rec_onnx',
  revision: '2cef88145434beb8afa9dd82d77d799eb1ad7b29',
  recFileName: 'ppocrv5_cyrillic_rec.onnx',
  dictFileName: 'ppocrv5_cyrillic_rec.yml',
  sha256: '5371ee1ddaa7983cc62d0818d99e982b6804638c85e4f960d59a574094e172e5',
  estimatedRecBytes: 8013000,
  estimatedDictBytes: 7000,
);

const _PpOcrRecSpec _kPpOcrV5GreekRec = _PpOcrRecSpec(
  repo: 'PaddlePaddle/el_PP-OCRv5_mobile_rec_onnx',
  revision: '8152b89d2ee0e1d4c92decab75fe75e5e3d836b6',
  recFileName: 'ppocrv5_greek_rec.onnx',
  dictFileName: 'ppocrv5_greek_rec.yml',
  sha256: '2acf17fcaea2bc81b878e311e6263b8885f48bb03796f75f9f30ed3242bbaa6d',
  estimatedRecBytes: 7772000,
  estimatedDictBytes: 3300,
);

const _PpOcrRecSpec _kPpOcrV5ArabicRec = _PpOcrRecSpec(
  repo: 'PaddlePaddle/arabic_PP-OCRv5_mobile_rec_onnx',
  revision: '14aaedcd75825982689ecf5cd64ab33ee083215a',
  recFileName: 'ppocrv5_arabic_rec.onnx',
  dictFileName: 'ppocrv5_arabic_rec.yml',
  sha256: '799113ebf267fbe742deb99eb36e8d42c9ddc5291ceacf92add41b4d52a59110',
  estimatedRecBytes: 7963000,
  estimatedDictBytes: 6200,
);

/// 语言代码（BCP 47 主标签，如 `pt`、`ru`）→ 读这种文字的本地识别权重。日文给
/// 漫画微调权重；其余按 Lookupper 的语言表：中文与罗马尼亚语
/// 用 PP-OCRv6 small，拉丁字母语言用 tiny，西里尔 / 韩 / 希腊 / 阿拉伯各用
/// PP-OCRv5 的专用权重。认不出的语言回退 tiny（拉丁）。
MangaOcrLocalModel localMangaOcrModelForLanguage(String languageCode) {
  final String code = languageCode.toLowerCase().split(RegExp('[-_]')).first;
  return switch (code) {
    'ja' => MangaOcrLocalModel.mangaCtc,
    'zh' || 'yue' || 'ro' => MangaOcrLocalModel.ppocrV6Small,
    'ko' => MangaOcrLocalModel.ppocrV5Korean,
    'ru' ||
    'uk' ||
    'bg' ||
    'be' ||
    'mk' ||
    'sr' ||
    'kk' ||
    'mn' => MangaOcrLocalModel.ppocrV5Cyrillic,
    'el' || 'grc' => MangaOcrLocalModel.ppocrV5Greek,
    'ar' || 'fa' || 'ur' => MangaOcrLocalModel.ppocrV5Arabic,
    _ => MangaOcrLocalModel.ppocrV6Tiny,
  };
}
