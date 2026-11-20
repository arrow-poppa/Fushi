import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/screen_ocr_lines.dart';
import 'package:fushi/src/floating_ball/screen_ocr_local.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_screen_reader.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    final EnginePaths previous = enginePaths;
    root = Directory.systemTemp.createTempSync('screen_ocr_local');
    enginePaths = FixedEnginePaths(documents: root, support: root, temp: root);
    addTearDown(() {
      enginePaths = previous;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
  });

  test('engine lines become the native wire shape', () {
    final ScreenOcrLine line = screenOcrLineFromLocal(
      const PpOcrScreenLine(
        text: 'dia',
        rect: OcrRect(left: 10.4, top: 20, right: 70.6, bottom: 40),
        vertical: false,
        blockText: 'Bom dia',
        blockOffset: 4,
        glyphs: <OcrGlyphBox>[
          OcrGlyphBox(
            start: 0,
            end: 1,
            rect: OcrRect(left: 10, top: 20, right: 30, bottom: 40),
          ),
        ],
      ),
    );
    expect(line.toWire(), <String, Object?>{
      'text': 'dia',
      'left': 10,
      'top': 20,
      'right': 71,
      'bottom': 40,
      'vertical': false,
      'blockText': 'Bom dia',
      'blockOffset': 4,
      'glyphs': <int>[0, 1, 10, 20, 30, 40],
    });
  });

  test('a model is ready only when every manifest file is on disk', () async {
    const MangaOcrLocalModel model = MangaOcrLocalModel.ppocrV6Tiny;
    expect(await isScreenOcrLocalModelReady(model), isFalse);
    final Directory dir = await model.modelsDirectory();
    dir.createSync(recursive: true);
    for (final MangaOcrModelFile file in model.manifest.skip(1)) {
      File(p.join(dir.path, file.fileName)).writeAsBytesSync(<int>[1]);
    }
    expect(await isScreenOcrLocalModelReady(model), isFalse);
    File(
      p.join(dir.path, model.manifest.first.fileName),
    ).writeAsBytesSync(<int>[1]);
    expect(await isScreenOcrLocalModelReady(model), isTrue);
  });

  test('recognizing with a model that is not downloaded says so', () async {
    final ScreenOcrLocalEngine engine = ScreenOcrLocalEngine(
      factoryBuilder: () => throw StateError('must not open sessions'),
    );
    addTearDown(engine.close);
    final Uint8List png = Uint8List.fromList(
      img.encodePng(img.Image(width: 8, height: 8)),
    );
    await expectLater(
      engine.recognize(png, model: MangaOcrLocalModel.ppocrV5Korean),
      throwsA(isA<ScreenOcrLocalModelMissing>()),
    );
  });
}
