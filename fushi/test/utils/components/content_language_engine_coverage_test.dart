import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/content_language_picker.dart';

/// 查词引擎带去屈折规则表的每一门语言，都必须能在内容语言选择器里选到。
///
/// 选择器（[kContentLanguageOptions]）是词典 / 书 / 游戏语言、默认内容语言、查词
/// 输入法语言与 Profile 语言绑定共用的唯一清单；引擎在 `manifest.json` 里新加一门
/// 语言而这里没跟上，用户就没法给这门语言的内容指定语言。
void main() {
  test('every transform language is offered by the content language picker', () {
    const String dir = 'assets/transforms';
    final List<String> files = List<String>.from(
      jsonDecode(File('$dir/manifest.json').readAsStringSync()) as List<dynamic>,
    );
    // 按文件名取语言（`de_extended` / `en_irregular` 归到 `de` / `en`）：文件名是
    // BCP-47 标签，表内的 `language` 字段不一定是（格鲁吉亚语写的是 `kat`）。
    final Set<String> engineLanguages = <String>{
      for (final String name in files) name.split('_').first,
    };
    expect(engineLanguages, isNotEmpty);

    final Set<String> offered = <String>{
      for (final ({String? tag, String label}) option
          in kContentLanguageOptions)
        if (option.tag != null) option.tag!,
    };
    expect(
      engineLanguages.difference(offered),
      isEmpty,
      reason: 'languages with deinflection rules missing from the picker',
    );
  });

  test('picker tags are unique and labels show the tag', () {
    final List<String> tags = <String>[
      for (final ({String? tag, String label}) option
          in kContentLanguageOptions)
        option.tag!,
    ];
    expect(tags.toSet(), hasLength(tags.length));
    for (final ({String? tag, String label}) option
        in kContentLanguageOptions) {
      expect(option.label, endsWith('(${option.tag})'));
      expect(contentLanguageLabelOf(option.tag!), option.label);
    }
  });
}
