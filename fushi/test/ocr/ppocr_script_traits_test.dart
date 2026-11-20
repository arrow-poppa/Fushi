import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/ctc_column_ocr_recognizer.dart';
import 'package:fushi_engine/ocr/ocr_glyph_boxes.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_script_traits.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:fushi_engine/ocr/ppocr_screen_reader.dart';
import 'package:fushi_engine/ocr/routing_ocr_recognizer.dart';
import 'package:image/image.dart' as img;

class _DeadSession implements OcrSession {
  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) =>
      throw StateError('fake must not run a session');

  @override
  Future<void> close() async {}
}

class _FakeLineDetector extends PpOcrLineDetector {
  _FakeLineDetector(this.lines) : super(_DeadSession());

  final List<PpTextLine> lines;

  @override
  Future<List<PpTextLine>> detect(img.Image crop) async => lines;
}

/// Replies with [replies] in call order. Each reply gets one token per
/// character, evenly spread over the line image, so glyph boxes can be built.
class _QueueRecognizer extends PpOcrLineRecognizer {
  _QueueRecognizer(this.replies)
    : super(_DeadSession(), vocab: const <String>['']);

  final List<String> replies;
  final List<img.Image> lines = <img.Image>[];

  @override
  Future<PpOcrPositionedLine> recognizeLinePositioned(img.Image line) async {
    lines.add(line);
    final String text = replies[lines.length - 1];
    final double step = line.width / text.length;
    return PpOcrPositionedLine(
      text: text,
      confidence: 0.9,
      tokens: <OcrLineToken>[
        for (int i = 0; i < text.length; i++)
          OcrLineToken(
            start: i,
            end: i + 1,
            left: i * step,
            right: (i + 1) * step,
          ),
      ],
    );
  }
}

PpTextLine _line(double l, double t, double r, double b) => PpTextLine(
  rect: OcrRect(left: l, top: t, right: r, bottom: b),
  score: 1,
);

const OcrScriptTraits _latin = OcrScriptTraits(
  verticalText: false,
  dropRuby: false,
  spaceBetweenLines: true,
);

void main() {
  group('line joining', () {
    test('adds a space between words of spaced scripts only', () {
      expect(needsOcrLineSpace('Hello', 'world'), isTrue);
      expect(needsOcrLineSpace('Привет,', 'мир'), isTrue);
      expect(needsOcrLineSpace('안녕', '하세요'), isTrue);
      // Hyphenated line break, existing whitespace, Japanese seams.
      expect(needsOcrLineSpace('exam-', 'ple'), isFalse);
      expect(needsOcrLineSpace('Hello ', 'world'), isFalse);
      expect(needsOcrLineSpace('今日は', 'いい天気'), isFalse);
      expect(needsOcrLineSpace('ABC', '日本'), isFalse);
      expect(needsOcrLineSpace('', 'x'), isFalse);
    });

    test('hangs the space on the previous line so join() still matches', () {
      final List<String> lines = joinOcrLineTexts(<String>[
        'The quick',
        'brown fox',
        '日本',
      ], spaces: true);
      expect(lines, <String>['The quick ', 'brown fox', '日本']);
      expect(joinOcrLineTexts(<String>['a', 'b'], spaces: false), <String>[
        'a',
        'b',
      ]);
    });

    test(
      'right-to-left text is reversed but Latin and digit runs keep order',
      () {
        // CTC reads Arabic left to right on the image: visual order.
        expect(restoreRtlOcrText('ابج'), 'جبا');
        expect(restoreRtlOcrText('ب 2024 ا'), 'ا 2024 ب');
        expect(restoreRtlOcrText('بOKا'), 'اOKب');
      },
    );
  });

  group('CtcColumnOcrRecognizer with non-Japanese traits', () {
    test(
      'a tall Latin block is read as horizontal lines joined by a space',
      () async {
        final img.Image page = img.Image(width: 200, height: 200);
        final _QueueRecognizer recognizer = _QueueRecognizer(<String>[
          'Hello',
          'world',
        ]);
        final CtcColumnOcrRecognizer ctc = CtcColumnOcrRecognizer(
          // Tall boxes: with Japanese traits these would vote vertical and be
          // rotated into columns.
          lineDetector: _FakeLineDetector(<PpTextLine>[
            _line(10, 10, 30, 70),
            _line(10, 80, 30, 140),
          ]),
          lineRecognizer: recognizer,
          traits: _latin,
        );
        final OcrRecognition read = await ctc.recognizeWithLines(
          page,
          const OcrRect(left: 0, top: 0, right: 80, bottom: 160),
          vertical: true,
        );
        expect(read.vertical, isFalse);
        expect(read.text, 'Hello world');
        expect(read.lines, <String>['Hello ', 'world']);
        // Lines were not rotated into columns: each crop keeps its shape.
        for (final img.Image line in recognizer.lines) {
          expect(line.width, lessThan(line.height));
        }
        // The second line's glyphs start after the inserted space.
        final List<OcrGlyphBox> glyphs = read.glyphBoxes!;
        expect(glyphs, hasLength(10));
        expect(glyphs[5].start, 6);
        expect(read.text.substring(glyphs[5].start, glyphs[5].end), 'w');
      },
    );

    test('Japanese traits keep the existing behaviour', () async {
      final img.Image page = img.Image(width: 200, height: 200);
      final CtcColumnOcrRecognizer ctc = CtcColumnOcrRecognizer(
        lineDetector: _FakeLineDetector(<PpTextLine>[
          _line(10, 10, 60, 30),
          _line(10, 40, 60, 60),
        ]),
        lineRecognizer: _QueueRecognizer(<String>['ab', 'cd']),
      );
      final OcrRecognition read = await ctc.recognizeWithLines(
        page,
        const OcrRect(left: 0, top: 0, right: 80, bottom: 80),
        vertical: false,
      );
      expect(read.text, 'abcd');
    });
  });

  group('RoutingOcrRecognizer with non-Japanese traits', () {
    test(
      'Arabic lines come back in logical order without glyph boxes',
      () async {
        final img.Image page = img.Image(width: 200, height: 100);
        final RoutingOcrRecognizer routing = RoutingOcrRecognizer(
          mangaOcr: CtcColumnOcrRecognizer(
            lineDetector: _FakeLineDetector(const <PpTextLine>[]),
            lineRecognizer: _QueueRecognizer(const <String>[]),
          ),
          lineDetector: _FakeLineDetector(<PpTextLine>[
            _line(10, 10, 150, 30),
            _line(10, 40, 150, 60),
          ]),
          lineRecognizer: _QueueRecognizer(<String>['ابج', 'دهو']),
          traits: const OcrScriptTraits(
            verticalText: false,
            dropRuby: false,
            spaceBetweenLines: true,
            rightToLeft: true,
          ),
        );
        final List<OcrRecognition> read = await routing.recognizeOriented(
          page,
          <OcrRect>[const OcrRect(left: 0, top: 0, right: 180, bottom: 80)],
        );
        expect(read.single.text, 'جبا وهد');
        expect(read.single.glyphBoxes, isNull);
      },
    );

    test('Latin rows are joined with a space and glyphs follow it', () async {
      final img.Image page = img.Image(width: 200, height: 100);
      final RoutingOcrRecognizer routing = RoutingOcrRecognizer(
        mangaOcr: CtcColumnOcrRecognizer(
          lineDetector: _FakeLineDetector(const <PpTextLine>[]),
          lineRecognizer: _QueueRecognizer(const <String>[]),
        ),
        lineDetector: _FakeLineDetector(<PpTextLine>[
          _line(10, 10, 150, 30),
          _line(10, 40, 150, 60),
        ]),
        lineRecognizer: _QueueRecognizer(<String>['Bom', 'dia']),
        traits: _latin,
      );
      final OcrRecognition read = (await routing.recognizeOriented(
        page,
        <OcrRect>[const OcrRect(left: 0, top: 0, right: 180, bottom: 80)],
      )).single;
      expect(read.text, 'Bom dia');
      final List<OcrGlyphBox> glyphs = read.glyphBoxes!;
      expect(
        <String>[
          for (final OcrGlyphBox glyph in glyphs)
            read.text.substring(glyph.start, glyph.end),
        ],
        <String>['B', 'o', 'm', 'd', 'i', 'a'],
      );
    });
  });

  group('screen reader', () {
    test('stacked and same-row lines form one block, distant ones do not', () {
      final List<PpOcrScreenBlock> blocks = groupPpOcrScreenLines(
        const <OcrRect>[
          // Paragraph: two stacked lines plus a fragment on the first row.
          OcrRect(left: 10, top: 10, right: 200, bottom: 30),
          OcrRect(left: 10, top: 36, right: 180, bottom: 56),
          OcrRect(left: 215, top: 10, right: 300, bottom: 30),
          // A button far below.
          OcrRect(left: 10, top: 400, right: 80, bottom: 420),
          // A taller heading right above the paragraph (different size).
          OcrRect(left: 10, top: -50, right: 300, bottom: 0),
        ],
        verticalText: false,
      );
      expect(blocks, hasLength(3));
      expect(blocks[0].lines, hasLength(1)); // heading
      expect(blocks[1].lines, hasLength(3)); // paragraph
      expect(blocks[2].lines, hasLength(1)); // button
    });

    test('vertical columns group right to left when the script has them', () {
      final List<PpOcrScreenBlock> blocks =
          groupPpOcrScreenLines(const <OcrRect>[
            OcrRect(left: 100, top: 10, right: 120, bottom: 200),
            OcrRect(left: 126, top: 10, right: 146, bottom: 180),
          ], verticalText: true);
      expect(blocks, hasLength(1));
      expect(blocks.single.vertical, isTrue);
      expect(blocks.single.lines.first.left, 126);
      // Without vertical text the same boxes are two separate rows.
      expect(
        groupPpOcrScreenLines(const <OcrRect>[
          OcrRect(left: 100, top: 10, right: 120, bottom: 200),
          OcrRect(left: 126, top: 10, right: 146, bottom: 180),
        ], verticalText: false).every((PpOcrScreenBlock b) => !b.vertical),
        isTrue,
      );
    });

    test(
      'reads lines with block text, offsets and line-relative glyphs',
      () async {
        final List<img.Image> detectorInputs = <img.Image>[];
        final PpOcrScreenReader reader = PpOcrScreenReader(
          detectLines: (img.Image image) async {
            detectorInputs.add(image);
            // Coordinates in the downscaled detector image (half size).
            return const <OcrRect>[
              OcrRect(left: 5, top: 5, right: 100, bottom: 15),
              OcrRect(left: 5, top: 18, right: 90, bottom: 28),
            ];
          },
          readLine: (img.Image line) async {
            final String text = _reads++ == 0 ? 'Bom' : 'dia';
            final double step = line.width / text.length;
            return PpOcrPositionedLine(
              text: text,
              confidence: 0.9,
              tokens: <OcrLineToken>[
                for (int i = 0; i < text.length; i++)
                  OcrLineToken(
                    start: i,
                    end: i + 1,
                    left: i * step,
                    right: (i + 1) * step,
                  ),
              ],
            );
          },
          traits: _latin,
        );
        _reads = 0;
        final List<PpOcrScreenLine> lines = await reader.read(
          img.Image(width: 2560, height: 1440),
        );
        // The long side was scaled down to the detector cap.
        expect(detectorInputs.single.width, kPpOcrScreenDetMaxSide);
        expect(lines, hasLength(2));
        expect(lines[0].text, 'Bom');
        expect(lines[0].blockText, 'Bom dia');
        expect(lines[0].blockOffset, 0);
        expect(lines[1].blockOffset, 4);
        // Boxes are back in screenshot pixels.
        expect(lines[0].rect.left, 10);
        expect(lines[0].rect.right, 200);
        expect(lines[0].glyphs, hasLength(3));
        expect(lines[1].glyphs.first.start, 0);
      },
    );

    test('drops low-confidence and empty reads', () async {
      final PpOcrScreenReader reader = PpOcrScreenReader(
        detectLines: (img.Image image) async => const <OcrRect>[
          OcrRect(left: 0, top: 0, right: 50, bottom: 10),
          OcrRect(left: 0, top: 100, right: 50, bottom: 110),
          OcrRect(left: 0, top: 200, right: 2, bottom: 210),
        ],
        readLine: (img.Image line) async => PpOcrPositionedLine(
          text: _reads++ == 0 ? '口' : '',
          confidence: 0.1,
          tokens: const <OcrLineToken>[],
        ),
      );
      _reads = 0;
      expect(await reader.read(img.Image(width: 100, height: 300)), isEmpty);
    });
  });
}

int _reads = 0;
