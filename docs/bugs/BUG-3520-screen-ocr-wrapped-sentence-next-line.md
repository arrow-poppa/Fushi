## BUG-3520 · 截屏识字查词窗：一句折到下一行时源文本条看不到下一行、跨行的词查不全
- **报告**：2026-10-18（用户：截屏识字的句子有两行时识别不到下面那一行）
- **真实性**：✅ 真 bug。原生侧只把被点的那一行作为 `EXTRA_PROCESS_TEXT` 交给查词窗（`ScreenOcrService.onSelectionTap`），块全文 `sourceBlock` 只用于截制卡句子（BUG-3487）；源文本条与首查的扫描后缀都只取这一行（`fushi/lib/src/pages/implementations/popup_dictionary_page.dart:212`，修前 `final String text = widget.searchTerm;`）。一句折到下一行时条上看不到下一行，跨行的词（「天」在行尾、「気」在下一行行首）只能查到「天」。
- **[x] ① 已修复**（`5e427719be`）— 新增 `ocrLineWithSentenceContinuation`（`fushi/lib/src/lookup/ocr_block_sentence.dart:161`）：被点的那一行 + 行尾那一句在下面几行里的剩余部分，按 OCR 折行规则拼接（CJK 直连、拉丁词补空格），行文本原样作前缀，行内下标无需换算；行尾那句在本行就结束、行是块尾、偏移对不上或超过 200 码元时返回 null 保持原样。查词窗的源文本条与首查扫描改用它（`_sourceTextOf`，`popup_dictionary_page.dart:169`）；条上点到接上的那部分时按行尾那一句取制卡句子。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/ocr_block_sentence_test.dart`（`ocrLineWithSentenceContinuation` 组 8 例）；`fushi/test/pages/popup_dictionary_source_line_test.dart`（跨行首查扫描为「天気ですね。」、条上为整句、点下一行的「気」仍是同一句）。既有 BUG-2899 / BUG-3487 用例不变（行尾那句在本行结束时条上仍是整行）。
- **备注**：只往下接，不往上接（往上接会让被点字的行内下标失效）。未在真机复测（本环境无 Android 设备）。
