## BUG-3524 · 独立查词窗的源文本条不随结果滚动，也不能折叠
- **报告**：2026-10-18（用户：查词窗上方显示句子的那部分没法跟着弹窗其余部分一起滚动；希望能折叠它，并有开关决定默认是否折叠）
- **真实性**：✅ 真 bug。源文本条（`SourceLookupTextPanel`）是 `popup_dictionary_page.dart` 里 Column 的一个普通 Wrap，结果区是自带滚动的 WebView；两者不在同一个滚动面上，条既不动也没有高度上限——截屏识字整块拼进来时会把结果挤出窗口。
- **[x] ① 已修复**（`e9a92227b5`）— `fushi/lib/src/utils/components/source_lookup_strip.dart`：条随结果滚走（`SourceStripScrollAway`，基础层经 `forwardScrollToHost` 把 WebView 滚动冒泡给页面；只认用户滚动，且结果去掉条的高度后仍可滚才收起，防止来回弹）、长句在条内滚动（上限窗口高度 30%）、折叠成一行预览（箭头 / 点预览开合）；设置「默认折叠源文本」（`lookup_source_text_collapsed`）。只管显示，查词、制卡句子与 AI 句子不变。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/source_strip_scroll_away_test.dart`（收起 / 回顶出现 / 程序滚动不收 / 防回弹）、`fushi/test/pages/popup_dictionary_source_line_test.dart`（默认折叠与开合、真页面上随结果滚走与回顶出现）。
- **备注**：首页查词页的源文本条同样接上（`home_dictionary_page.dart`：卡头上边距 + 条 + 分隔线整块随结果滚走；结果滚动通知继续冒到外壳，底栏随下滑收起不受影响），测试 `fushi/test/pages/home_dictionary_source_scan_test.dart`。未在真机复测（本环境无 Android 设备）。
