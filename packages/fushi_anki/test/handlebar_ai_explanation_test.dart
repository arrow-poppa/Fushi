import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 走**真实落卡渲染路径**（`renderMediaPayload` → `buildMinedFields`）的最小 repo，
/// 与 `handlebar_clip_timestamp_test.dart` 同款。
///
/// 这个 harness 在这里不是可选项：`renderMediaPayload` 会把 `AnkiMiningPayload`
/// **逐字段重建**一份，新字段漏抄就会让整条落卡路径恒空串，而直调
/// `AnkiHandlebarRenderer.render` 的纯渲染器测试照样全绿。`{ai-explanation}` 加进来
/// 时就差点栽在这一跳上。
class _RenderPathRepo extends BaseAnkiRepository {
  @override
  Future<AnkiFetchResult> fetchConfiguration() => throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) => throw UnimplementedError();

  @override
  Future<bool> isDuplicate(String expression, String reading) =>
      throw UnimplementedError();

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) =>
      throw UnimplementedError();

  @override
  Future<bool> createDeck(String name) => throw UnimplementedError();

  RenderedMinedFields renderFor({
    required AnkiSettings settings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
  }) => renderMediaPayload(
    settings: settings,
    payload: payload,
    context: context,
    coverRef: null,
    sentenceAudioRef: null,
    processedAudio: '',
    dictionaryMediaTags: const <String, String>{},
  );
}

/// `{ai-explanation}` 是**纯追加**的标记：它不改 `{popup-selection-text}` 的语义，
/// 也不改任何既有标记的行为。这两条在下面各有一条负向用例咬住，因为「加一个标记
/// 顺手改了另一个」正是这类改动最容易出的事故。
///
/// 契约见 docs/agent/ai-explanation.md §11。
void main() {
  const String answer = '「猫」在这句里指真正的猫，不是比喻。';

  const AnkiMiningPayload payload = AnkiMiningPayload(
    expression: '猫',
    reading: 'ねこ',
    glossary: 'cat',
    glossaryFirst: 'cat',
    popupSelectionText: '真正的猫',
    aiExplanation: answer,
  );

  const AnkiMiningContext context = AnkiMiningContext(sentence: '猫が好きです。');

  String render(String template, [AnkiMiningPayload? p]) =>
      AnkiHandlebarRenderer.render(template, p ?? payload, context);

  group('{ai-explanation}', () {
    test('渲染出最终答案', () {
      expect(render('{ai-explanation}'), answer);
    });

    test('没有 AI 解释时是空串，不是占位文案', () {
      expect(
        render(
          '{ai-explanation}',
          const AnkiMiningPayload(expression: '猫'),
        ),
        isEmpty,
      );
    });

    test('登记在可选标记清单里（设置页才选得到）', () {
      expect(AnkiHandlebarOptions.coreOptions, contains('{ai-explanation}'));
    });

    test('不在「已弃用别名」里', () {
      expect(
        AnkiHandlebarOptions.deprecatedAliases,
        isNot(contains('{ai-explanation}')),
      );
    });

    test('保留换行与 Unicode', () {
      const String multiline = '第一行\n第二行\n\n🐱';
      expect(
        render(
          '{ai-explanation}',
          const AnkiMiningPayload(expression: '猫', aiExplanation: multiline),
        ),
        multiline,
      );
    });
  });

  group('不影响既有标记', () {
    test('{popup-selection-text} 仍然只给用户选中的那一段', () {
      // 两者共存时各给各的：选中一段解释去制卡，SelectionText 给那一段，
      // {ai-explanation} 给完整答案。谁也不吞谁。
      expect(render('{popup-selection-text}'), '真正的猫');
      expect(render('{ai-explanation}'), answer);
    });

    test('{glossary} / {glossary-first} 不受影响', () {
      expect(render('{glossary}'), 'cat');
      expect(render('{glossary-first}'), 'cat');
    });

    test('{expression} / {reading} / {sentence} 不受影响', () {
      expect(render('{expression}'), '猫');
      expect(render('{reading}'), 'ねこ');
      expect(render('{sentence}'), '猫が好きです。');
    });
  });

  group('wire 形态', () {
    test('旧 payload 没有这个键时退化成空串', () {
      // 浏览器扩展与远端 API 发来的 JSON 不会带它；行为必须逐字节不变。
      final AnkiMiningPayload parsed = AnkiMiningPayload.fromJson(
        <String, dynamic>{'expression': '猫'},
      );
      expect(parsed.aiExplanation, isEmpty);
    });

    test('应用内 WebView 桥的全字符串形态能解出来', () {
      final AnkiMiningPayload parsed = AnkiMiningPayload.fromJson(
        <String, dynamic>{'expression': '猫', 'aiExplanation': answer},
      );
      expect(parsed.aiExplanation, answer);
    });
  });

  group('真实落卡路径', () {
    test('renderMediaPayload 把 aiExplanation 带过那一跳', () {
      // 这条就是本文件存在的理由：renderMediaPayload 逐字段重建 payload，
      // 漏抄就恒空串，而上面那些纯渲染器用例全都照样绿。
      final _RenderPathRepo repo = _RenderPathRepo();
      final RenderedMinedFields rendered = repo.renderFor(
        settings: const AnkiSettings(
          fieldMappings: <String, String>{
            'Expression': '{expression}',
            'AiNote': '{ai-explanation}',
          },
        ),
        payload: payload,
        context: context,
      );
      expect(rendered.fields['AiNote'], answer,
          reason: '落卡路径上必须拿得到答案，而不是空串');
      expect(rendered.fields['Expression'], '猫');
    });
  });
}
