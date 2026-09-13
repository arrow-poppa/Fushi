import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 查词链路上「边界明确」的入口必须真的经过 [AppModel.applyAiFallback]。
///
/// 这条守卫是 2.7.0 合并时补的：上游把弹窗里点词头 / 链接 / 汉字的那条路从
/// `onLinkClick` 直接调 `searchDictionaryResult`，改成了 `navigatePopupInPlace`
/// 自己调 `appModel.searchDictionary`。改动本身没问题，但它绕开了兜底，而且
/// **静态分析和全部单测都照常绿**——未知词点进去只是安静地什么都不发生。
/// 纯行为测试抓不到这种「整条路被搬走」的回归，所以这里按源码结构判。
void main() {
  String read(String path) {
    final File file = File(path);
    expect(
      file.existsSync(),
      isTrue,
      reason: '找不到 ${file.absolute.path}；文件搬家了就同步改这条守卫，别让它空转',
    );
    return file.readAsStringSync();
  }

  /// 取 [source] 里从 [signature] 开始的**函数体**（不是参数列表）。
  ///
  /// 先按圆括号配平跳过参数表——`navigatePopupInPlace({` 的那个 `{` 属于具名参数，
  /// 直接从它开始配大括号只会截出参数列表，而参数列表里当然找不到 applyAiFallback：
  /// 守卫会对着正确的代码报错（本守卫第一版就是这么翻的）。
  String bodyOf(String source, String signature) {
    final int start = source.indexOf(signature);
    expect(start, isNonNegative, reason: '找不到 $signature');

    final int paramsOpen = source.indexOf('(', start);
    expect(paramsOpen, isNonNegative, reason: '$signature 后面没有参数表');
    int parens = 0;
    int paramsClose = -1;
    for (int i = paramsOpen; i < source.length; i++) {
      if (source[i] == '(') parens++;
      if (source[i] == ')') {
        parens--;
        if (parens == 0) {
          paramsClose = i;
          break;
        }
      }
    }
    expect(paramsClose, isNonNegative, reason: '$signature 的参数表圆括号没配平');

    final int open = source.indexOf('{', paramsClose);
    expect(open, isNonNegative, reason: '$signature 没有函数体');
    int depth = 0;
    for (int i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) return source.substring(open, i + 1);
      }
    }
    fail('$signature 的函数体大括号没配平');
  }

  const Map<String, String> inPlaceNavigators = <String, String>{
    'lib/src/pages/base_source_page.dart':
        'Future<void> navigatePopupInPlace({',
    'lib/src/pages/implementations/dictionary_page_mixin.dart':
        'Future<void> navigatePopupInPlace({',
  };

  test('守卫没跑空：两处原地跳转都还在', () {
    for (final MapEntry<String, String> entry in inPlaceNavigators.entries) {
      expect(
        read(entry.key),
        contains(entry.value),
        reason: '${entry.key} 里没有原地跳转了？形状变了就更新本守卫',
      );
    }
  });

  test('原地跳转（词头 / 链接 / 汉字）经过 AI 兜底且声明边界明确', () {
    final List<String> offenders = <String>[];
    for (final MapEntry<String, String> entry in inPlaceNavigators.entries) {
      final String body = bodyOf(read(entry.key), entry.value);

      // 反向锚：函数体里一定有查词调用。取不到就是 bodyOf 又切错了段落，
      // 此时下面的断言全部失去意义，要报 bodyOf 的错而不是报业务代码的错。
      expect(
        body,
        contains('searchDictionary('),
        reason: '${entry.key}: bodyOf 截出来的不是函数体',
      );

      // 光有 searchDictionary 不够：必须是被 applyAiFallback 包起来的那一次。
      if (!body.contains('applyAiFallback(')) {
        offenders.add(
          '  ${entry.key}: navigatePopupInPlace 没调 applyAiFallback',
        );
        continue;
      }
      if (!body.contains('hasExplicitBoundary: true')) {
        offenders.add(
          '  ${entry.key}: 调了兜底但没声明 hasExplicitBoundary: true，'
          '等于默认 false，兜底会被 applyAiFallback 自己挡掉',
        );
      }
      final int fallbackAt = body.indexOf('applyAiFallback(');
      final int searchAt = body.indexOf('searchDictionary(');
      if (searchAt >= 0 && fallbackAt > searchAt) {
        offenders.add(
          '  ${entry.key}: applyAiFallback 在 searchDictionary 之后，'
          '没有包住它的结果',
        );
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '点词头 / 链接 / 汉字是边界明确的路径：点中的那一串就是那个词。'
          '这条路绕开兜底时，未知词只会安静地什么都不发生：\n'
          '${offenders.join("\n")}',
    );
  });

  test('扫描窗路径不许偷偷声明边界明确', () {
    // 反向锚。点按取扫描窗的入口（漫画 / PDF / 阅读器点按）边界是猜的，在日语上
    // 拿扫描窗当词兜底会造出「半句话当一个词」——参考实现用语言黑名单防的正是这个。
    const List<String> scanPaths = <String>[
      'lib/src/media/manga/reader/manga_fushi_page.dart',
      'lib/src/pages/implementations/reader_pdf_page.dart',
    ];
    final List<String> offenders = <String>[];
    for (final String path in scanPaths) {
      final String source = read(path);
      if (source.contains('hasExplicitBoundary: true')) {
        offenders.add('  $path');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '这些入口交出来的是扫描窗，不是用户划定的边界：\n${offenders.join("\n")}',
    );
  });
}
