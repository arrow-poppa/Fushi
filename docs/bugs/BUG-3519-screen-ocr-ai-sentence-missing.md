## BUG-3519 · 截屏识字查词窗不给 AI 解释传句子（首查只解释孤立的词）
- **报告**：2026-10-18（用户：Android 截屏识字查词时 AI 解释像是只收到了词、没有句子，要再点一次才像带上了语境）
- **真实性**：✅ 真 bug，两处根因。
  - app 外查词窗（`PopupDictionaryPage`，截屏识字 / 悬浮字幕点字都走它）自己构造 `DictionaryPopupLayer`，从没传 `aiSentence`，`{{sentence}}` 恒为空串——句子明明已经算好给制卡用了（`_sourceSentence`，BUG-3487）。`fushi/lib/src/pages/implementations/popup_dictionary_page.dart:813`（修前该处无 `aiSentence:`）。
  - 通用时序：`DictionaryPopupWebView` 只在结果推送那一刻（`_pushResults` → `_beginAiLookupJs`）读一次 `widget.aiSentence`；宿主在结果之后才定下句子时，AI 已按旧句子（多为空）发出，句子变了也不重问，用户得再查一次同一个词才拿到带语境的解释。`fushi/lib/src/pages/implementations/dictionary_popup_webview.dart:1762`（修前 `didUpdateWidget` 只比较 result / lookupPending）。
- **[x] ① 已修复**（`5e427719be`）— 查词窗按与制卡补 `{sentence}` 同一判据给基础层传句子（`_aiSentenceFor`，`popup_dictionary_page.dart:476`）：基础层当前词条仍出自外部入口那一行才给，原地跳到释义里的别的词、嵌套层、搜索栏另查都给空串。弹窗 WebView 在结果不变、句子变了时只重启 AI 这一块（`_restartAiForSentence`，`dictionary_popup_webview.dart:1728`），控制器按新的 (词, 句子) 换缓存键并按「取消未完成请求」放弃旧请求。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_dictionary_source_line_test.dart`：截屏识字首查时基础层 `aiSentence` 即为块里的整句、条上点下一行的字仍是同一句；整串入口与搜索栏另查不带句子。
- **备注**：未在真机复测（本环境无 Android 设备）。`_restartAiForSentence` 依赖真 WebView，widget 层没有可落地的测试面，靠控制器既有用例（`test/ai/ai_explanation_controller_test.dart`）保证换目标即放弃旧请求。
