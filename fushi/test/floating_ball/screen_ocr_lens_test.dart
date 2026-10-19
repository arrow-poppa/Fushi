import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/floating_ball_channel.dart';
import 'package:fushi/src/floating_ball/screen_ocr_lens.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

/// 一个字一个区：[cells] 按阅读顺序给每个非空白字的框（LTRB），空白跳过。
MokuroBlock _block(
  String sentence,
  List<List<double>> cells, {
  bool vertical = false,
}) {
  final List<MangaOcrTextRegion> regions = <MangaOcrTextRegion>[];
  int cell = 0;
  for (int i = 0; i < sentence.length; i++) {
    if (sentence[i].trim().isEmpty) continue;
    final List<double> box = cells[cell++];
    regions.add(
      MangaOcrTextRegion(
        rectangle: MokuroRect.fromLTRB(box[0], box[1], box[2], box[3]),
        utf16Start: i,
        utf16End: i + 1,
      ),
    );
  }
  return MokuroBlock(
    rectangle: const MokuroRect.fromLTRB(0, 0, 1000, 1000),
    isVertical: vertical,
    fontSize: 10,
    zIndex: 0,
    lines: <String>[sentence],
    regions: regions,
  );
}

MokuroImage _image(List<MokuroBlock> blocks) => MokuroImage(
  url: 'screen_ocr.jpg',
  size: const MokuroSize(1080, 2400),
  blocks: blocks,
);

/// 横排：每字 10 宽，[row] 行、从 [column] 列起。
List<List<double>> _row(int count, {required double row, double column = 0}) =>
    <List<double>>[
      for (int i = 0; i < count; i++)
        <double>[
          (column + i) * 10,
          row * 30,
          (column + i) * 10 + 10,
          row * 30 + 20,
        ],
    ];

class _FailingLens implements GoogleLensMangaOcrRunner {
  @override
  Future<MokuroImage> recognizePageBytes(
    Uint8List source, {
    required String relativeUrl,
    required String language,
  }) => Future<MokuroImage>.error(const GoogleLensOcrException('x', 'down'));

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
    bool onlyMissing = true,
    required String language,
    MangaOcrPageFocus? focus,
  }) => const Stream<MangaOcrVolumeEvent>.empty();

  @override
  Future<void> clearCache(String imageDirPath) async {}
}

void main() {
  test('一段折成两行：按逐字区拆回视觉行，带段落全文与偏移', () {
    // 「Привет мир」在第 0 行，「снова」折到第 1 行。
    const String sentence = 'Привет мир снова';
    final List<ScreenOcrLensLine> lines = screenOcrLinesFromLens(
      _image(<MokuroBlock>[
        _block(sentence, <List<double>>[
          ..._row(6, row: 0),
          ..._row(3, row: 0, column: 7),
          ..._row(5, row: 1),
        ]),
      ]),
    );
    expect(lines.map((ScreenOcrLensLine l) => l.text), <String>[
      'Привет мир',
      'снова',
    ]);
    expect(lines[0].blockText, sentence);
    expect(lines[0].blockOffset, 0);
    expect(lines[1].blockOffset, 11);
    expect(
      sentence.substring(
        lines[1].blockOffset,
        lines[1].blockOffset + lines[1].text.length,
      ),
      lines[1].text,
    );
    // 逐字框的区间相对行文本：第二行首字就是 0。
    expect(lines[1].glyphs.first.start, 0);
    expect(lines[1].glyphs.first.end, 1);
    expect(lines[0].glyphs.last.end, lines[0].text.length);
    expect(lines[0].rect, const Rect.fromLTRB(0, 0, 100, 20));
    expect(lines[1].rect, const Rect.fromLTRB(0, 30, 50, 50));
  });

  test('竖排按列折行', () {
    // 右列「日本」，左列「語」。
    final List<ScreenOcrLensLine> lines = screenOcrLinesFromLens(
      _image(<MokuroBlock>[
        _block('日本語', <List<double>>[
          <double>[100, 0, 120, 20],
          <double>[100, 20, 120, 40],
          <double>[60, 0, 80, 20],
        ], vertical: true),
      ]),
    );
    expect(lines.map((ScreenOcrLensLine l) => l.text), <String>['日本', '語']);
    expect(lines.every((ScreenOcrLensLine l) => l.isVertical), isTrue);
    expect(lines[1].blockOffset, 2);
  });

  test('没有逐字区的段落整段当一行，用段落框', () {
    final List<ScreenOcrLensLine> lines = screenOcrLinesFromLens(
      _image(<MokuroBlock>[
        const MokuroBlock(
          rectangle: MokuroRect.fromLTRB(5, 6, 105, 26),
          isVertical: false,
          fontSize: 10,
          zIndex: 0,
          lines: <String>['Ελληνικά'],
        ),
      ]),
    );
    expect(lines.single.text, 'Ελληνικά');
    expect(lines.single.rect, const Rect.fromLTRB(5, 6, 105, 26));
    expect(lines.single.glyphs, isEmpty);
  });

  test('toWire：坐标取整、逐字框扁平成六元组', () {
    final ScreenOcrLensLine line = screenOcrLinesFromLens(
      _image(<MokuroBlock>[
        _block('ab', <List<double>>[
          <double>[0.4, 0.6, 10.4, 20.6],
          <double>[10.4, 0.6, 20.4, 20.6],
        ]),
      ]),
    ).single;
    final Map<String, Object?> wire = line.toWire();
    expect(wire['text'], 'ab');
    expect(
      <Object?>[wire['left'], wire['top'], wire['right'], wire['bottom']],
      <int>[0, 1, 20, 21],
    );
    expect(wire['glyphs'], <int>[0, 1, 0, 1, 10, 21, 1, 2, 10, 1, 20, 21]);
    expect(wire['blockText'], 'ab');
    expect(wire['blockOffset'], 0);
  });

  test('Dart 选取页拿到同样的行与原图尺寸', () {
    final SystemOcrPageResult page = screenOcrPageFromLens(
      _image(<MokuroBlock>[
        _block('Hola mundo', <List<double>>[
          ..._row(4, row: 0),
          ..._row(5, row: 1),
        ]),
      ]),
    );
    expect(page.imageWidth, 1080);
    expect(page.imageHeight, 2400);
    expect(page.lines.map((SystemOcrTextLine l) => l.text), <String>[
      'Hola',
      'mundo',
    ]);
  });

  test('Lens 出错返回 null（调用方退回系统 OCR）', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    expect(
      await recognizeScreenWithLens(
        Uint8List(4),
        language: 'ru',
        runner: _FailingLens(),
      ),
      isNull,
    );
  });

  group('原生截屏 OCR 经通道向 Dart 要 Lens 结果', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      FloatingBallChannel.debugResetHandler();
    });

    tearDown(FloatingBallChannel.debugResetHandler);

    Future<Object?> call(String method, [Object? arguments]) async {
      Object? reply;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            FloatingBallChannel.channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, arguments),
            ),
            (ByteData? data) {
              reply = const StandardMethodCodec().decodeEnvelope(data!);
            },
          );
      return reply;
    }

    test('没装回调时不走 Lens', () async {
      await FloatingBallChannel.installHandler(
        onLookup: (_) {},
        onScreenOcrFinished: () {},
      );
      expect(await call('screenOcrUsesLens'), isFalse);
      expect(
        await call('recognizeScreenOcrLens', <String, Object?>{
          'image': Uint8List(4),
        }),
        isNull,
      );
    });

    test('回调的结果原样回给原生；图片字段不对就回 null', () async {
      final List<int> seen = <int>[];
      await FloatingBallChannel.installHandler(
        onLookup: (_) {},
        onScreenOcrFinished: () {},
        onScreenOcrUsesLens: () async => true,
        onRecognizeScreenOcrLens: (Uint8List image) async {
          seen.add(image.length);
          return <String, Object?>{'lines': <Object?>[]};
        },
      );
      expect(await call('screenOcrUsesLens'), isTrue);
      expect(
        await call('recognizeScreenOcrLens', <String, Object?>{
          'image': Uint8List(3),
        }),
        <String, Object?>{'lines': <Object?>[]},
      );
      expect(
        await call('recognizeScreenOcrLens', <String, Object?>{'image': 'x'}),
        isNull,
      );
      expect(seen, <int>[3]);
    });
  });
}
