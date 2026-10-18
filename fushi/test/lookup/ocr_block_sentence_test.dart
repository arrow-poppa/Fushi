import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/ocr_block_sentence.dart';

/// BUG-3487：截屏识字制卡句子从 OCR text block 里截整句。块全文是原生侧把块内
/// 各行按 `\n` 拼起来的，换行只是排版折行、不是句界。
void main() {
  int indexOf(String block, String needle) {
    final int i = block.indexOf(needle);
    expect(i, greaterThanOrEqualTo(0), reason: '测试数据里找不到「$needle」');
    return i;
  }

  test('vertical text split into columns is joined back into one sentence', () {
    // 竖排一列一行：ML Kit 把一句拆成四行。
    const String block = '吾輩は\n猫である。\n名前は\nまだ無い。';
    expect(ocrBlockSentenceAt(block, indexOf(block, '猫')), '吾輩は猫である。');
    expect(ocrBlockSentenceAt(block, indexOf(block, '名')), '名前はまだ無い。');
    expect(ocrBlockSentenceAt(block, indexOf(block, '無')), '名前はまだ無い。');
  });

  test('a sentence wrapped across lines is not cut at the line break', () {
    const String block = '今日は良い天気なので、公園に\n散歩に行きました。';
    const String whole = '今日は良い天気なので、公園に散歩に行きました。';
    expect(ocrBlockSentenceAt(block, indexOf(block, '天')), whole);
    expect(ocrBlockSentenceAt(block, indexOf(block, '散')), whole);
  });

  test('a block holding several sentences yields only the tapped one', () {
    const String block = 'これは本です！あれはペンですか？それは鉛筆です。';
    expect(ocrBlockSentenceAt(block, indexOf(block, '本')), 'これは本です！');
    expect(ocrBlockSentenceAt(block, indexOf(block, 'ペ')), 'あれはペンですか？');
    expect(ocrBlockSentenceAt(block, indexOf(block, '鉛')), 'それは鉛筆です。');
    // 点在句末标点上：归它结束的那一句。
    expect(ocrBlockSentenceAt(block, indexOf(block, '？')), 'あれはペンですか？');
  });

  test('closing quotes after the terminator stay with their sentence', () {
    const String block = '「行くぞ。」\n彼はそう言った。';
    expect(ocrBlockSentenceAt(block, indexOf(block, '行')), '「行くぞ。」');
    expect(ocrBlockSentenceAt(block, indexOf(block, '彼')), '彼はそう言った。');
  });

  test('back-to-back dialogue brackets split without a full stop', () {
    const String block = '「おはよう」\n「元気？」';
    expect(ocrBlockSentenceAt(block, indexOf(block, 'お')), '「おはよう」');
    expect(ocrBlockSentenceAt(block, indexOf(block, '元')), '「元気？」');
  });

  test('a quote followed by narration is one sentence', () {
    const String block = '「行くぞ」と\n彼は言った。';
    expect(ocrBlockSentenceAt(block, indexOf(block, '彼')), '「行くぞ」と彼は言った。');
  });

  test('ellipsis is not a sentence boundary', () {
    const String block = 'あの……実は\n話があるんだ。';
    expect(ocrBlockSentenceAt(block, indexOf(block, '話')), 'あの……実は話があるんだ。');
  });

  test('missing punctuation keeps the whole (short) block', () {
    const String block = 'もう一度\nやり直そう';
    expect(ocrBlockSentenceAt(block, indexOf(block, 'や')), 'もう一度やり直そう');
  });

  test('an over-long unpunctuated block falls back (null)', () {
    final String block = List<String>.filled(40, '設定項目です').join('\n');
    expect(ocrBlockSentenceAt(block, 3), isNull);
    // 上限可调：同一块在宽上限下照样整块返回。
    expect(ocrBlockSentenceAt(block, 3, maxLength: 1000), isNotNull);
  });

  test('English: wrapped lines get a space, periods split sentences', () {
    const String block = 'The quick brown\nfox jumps. It was 3.5 metres\nhigh!';
    expect(
      ocrBlockSentenceAt(block, indexOf(block, 'fox')),
      'The quick brown fox jumps.',
    );
    expect(
      ocrBlockSentenceAt(block, indexOf(block, 'metres')),
      'It was 3.5 metres high!',
    );
  });

  test('Chinese punctuation splits sentences', () {
    const String block = '今天天气很好。我们去\n公园散步吧！';
    expect(ocrBlockSentenceAt(block, indexOf(block, '公')), '我们去公园散步吧！');
  });

  test('out-of-range index and empty block return null', () {
    expect(ocrBlockSentenceAt('', 0), isNull);
    expect(ocrBlockSentenceAt('あいう', -1), isNull);
    expect(ocrBlockSentenceAt('あいう', 3), isNull);
  });

  // 查词窗源文本条：被点那一行 + 行尾那一句在下面几行里剩下的部分。
  group('ocrLineWithSentenceContinuation', () {
    test('a sentence wrapped onto the next line is continued there', () {
      // 「天気」被折成两行：只给第一行时扫描查词只能查到「天」。
      const String block = '今日は良い天\n気なので散歩に行った。\n次の文。';
      const String line = '今日は良い天';
      expect(
        ocrLineWithSentenceContinuation(block, 0, line),
        '今日は良い天気なので散歩に行った。',
      );
    });

    test(
      'the continuation spans several lines but stops at the sentence end',
      () {
        const String block = '吾輩は\n猫で\nある。名前は\nまだ無い。';
        expect(ocrLineWithSentenceContinuation(block, 0, '吾輩は'), '吾輩は猫である。');
      },
    );

    test('the line keeps its own text as an unchanged prefix', () {
      // 行内下标原样有效：开头必须逐字是原行（去掉行尾空白）。
      const String block = '  良い天気 \nですね。';
      const String line = '  良い天気 ';
      final String? joined = ocrLineWithSentenceContinuation(block, 0, line);
      expect(joined, '  良い天気ですね。');
      expect(joined!.startsWith(line.trimRight()), isTrue);
    });

    test('latin words broken across lines get a space back', () {
      const String block = 'The weather is\nnice today. Next one.';
      expect(
        ocrLineWithSentenceContinuation(block, 0, 'The weather is'),
        'The weather is nice today.',
      );
    });

    test('a line whose last sentence already ends on it is left alone', () {
      const String block = 'もう行く。\n今日は雨';
      expect(ocrLineWithSentenceContinuation(block, 0, 'もう行く。'), isNull);
    });

    test('the last line of the block has nothing to continue', () {
      const String block = 'まだ早い。\nもう行く。今日は雨';
      expect(
        ocrLineWithSentenceContinuation(
          block,
          indexOf(block, 'もう'),
          'もう行く。今日は雨',
        ),
        isNull,
      );
    });

    test('an offset that does not match the line is rejected', () {
      expect(ocrLineWithSentenceContinuation('まだ早い\nもう行く。', 1, 'まだ早い'), isNull);
      expect(ocrLineWithSentenceContinuation('まだ早い', -1, 'まだ早い'), isNull);
    });

    test('an unpunctuated block longer than the cap is not glued together', () {
      final String block = '${'メニュー' * 40}\n${'項目' * 40}';
      expect(ocrLineWithSentenceContinuation(block, 0, 'メニュー' * 40), isNull);
    });
  });

  group('line joining for space-delimited scripts', () {
    test('a line ending in punctuation still gets a space before the next', () {
      // Antes: 「Hello,」+「world」 virava 「Hello,world」.
      const String block = 'Hello,\nworld. Next.';
      expect(ocrBlockSentenceAt(block, 0), 'Hello, world.');
    });

    test('Cyrillic and Greek line breaks are word breaks too', () {
      expect(ocrBlockSentenceAt('Привет\nмир. Ещё.', 0), 'Привет мир.');
      expect(ocrBlockSentenceAt('Καλή\nμέρα. Άλλη.', 0), 'Καλή μέρα.');
    });

    test('a hyphen at the end of a line joins without a space', () {
      expect(
        ocrBlockSentenceAt('Das ist ein Haus-\ntür. Ende.', 0),
        'Das ist ein Haus-tür.',
      );
    });

    test('CJK next to Latin across a break stays glued as before', () {
      expect(ocrBlockSentenceAt('日本語の\nABCです。', 0), '日本語のABCです。');
    });
  });

  // 靠空格分词的文字：源文本条显示整块，被点字下标换算到拼好的整块上。
  group('ocrSpacedBlockAt', () {
    test('joins every line of a European block and maps the tapped unit', () {
      const String block =
          'Le chat dort sur\nle canapé depuis\nce matin. Il rêve.';
      const String line = 'le canapé depuis';
      final int offset = indexOf(block, line);
      final ({String text, int unit})? r = ocrSpacedBlockAt(
        block,
        offset,
        line,
        line.indexOf('canapé'),
      );
      expect(r, isNotNull);
      expect(r!.text, 'Le chat dort sur le canapé depuis ce matin. Il rêve.');
      expect(r.text.substring(r.unit, r.unit + 6), 'canapé');
    });

    test('the first and the last line map too', () {
      const String block = 'Ich gehe\nnach Hause.';
      final ({String text, int unit})? first = ocrSpacedBlockAt(
        block,
        0,
        'Ich gehe',
        0,
      );
      expect(first!.text, 'Ich gehe nach Hause.');
      expect(first.unit, 0);
      final ({String text, int unit})? last = ocrSpacedBlockAt(
        block,
        indexOf(block, 'nach'),
        'nach Hause.',
        'nach Hause.'.indexOf('Hause'),
      );
      expect(last!.text.substring(last.unit), 'Hause.');
    });

    test('leading and trailing spaces on OCR lines do not shift the index', () {
      const String block = '  Uno dos  \n  tres cuatro.';
      const String line = '  tres cuatro.';
      final ({String text, int unit})? r = ocrSpacedBlockAt(
        block,
        indexOf(block, line),
        line,
        line.indexOf('cuatro'),
      );
      expect(r!.text, 'Uno dos tres cuatro.');
      expect(r.text.substring(r.unit), 'cuatro.');
    });

    test('blocks with Japanese or Chinese are left to the line mode', () {
      const String block = '今日は\n良い天気。';
      expect(ocrSpacedBlockAt(block, 0, '今日は', 0), isNull);
      // Mesmo uma única palavra japonesa num bloco latino desliga o modo.
      expect(ocrSpacedBlockAt('Hello\nこんにちは', 0, 'Hello', 0), isNull);
    });

    test(
      'a single-line block, a bad offset or an out-of-range unit is null',
      () {
        expect(
          ocrSpacedBlockAt('One line only.', 0, 'One line only.', 2),
          isNull,
        );
        expect(ocrSpacedBlockAt('Ab\ncd', 1, 'Ab', 0), isNull);
        expect(ocrSpacedBlockAt('Ab\ncd', 0, 'Ab', 2), isNull);
        expect(ocrSpacedBlockAt('Ab\ncd', 0, 'Ab', -1), isNull);
      },
    );

    test('a block longer than the cap falls back', () {
      final String block = '${'word ' * 150}\n${'more ' * 150}';
      final String line = 'word ' * 150;
      expect(ocrSpacedBlockAt(block, 0, line, 0), isNull);
      expect(ocrSpacedBlockAt(block, 0, line, 0, maxLength: 5000), isNotNull);
    });
  });
}
