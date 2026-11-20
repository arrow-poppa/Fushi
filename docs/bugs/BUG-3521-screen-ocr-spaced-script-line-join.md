## BUG-3521 · 截屏识字：拉丁 / 西里尔 / 希腊文折行拼回时丢空格，查词窗只给被点的那一行
- **报告**：2026-10-18（用户：主要用欧洲语言；希望截屏识字查词窗拿到整块的所有行）
- **真实性**：✅ 真 bug + 需求。
  - 拼行规则只在两侧**都是拉丁字母 / 数字**时补空格（修前 `_joinLines` / `_isLatinWordChar`，`fushi/lib/src/lookup/ocr_block_sentence.dart`）：行尾是标点时「Hello,」+「world.」拼成「Hello,world.」；西里尔 / 希腊字母不在判定范围内，折行处一律粘成一个词。制卡 `{sentence}` 与 AI 的 `{{sentence}}` 都取这条拼接结果。
  - 查词窗源文本条只给被点的那一行（BUG-3520 后加了句子续行，但只往下接）：靠空格分词的语言里，同一块的上一行、下一句都点不到。
- **[x] ① 已修复**（`81a2dd0efe`）— 拼行改按文字体系判（`_lineSeparator`，`ocr_block_sentence.dart:120`）：任一侧是不靠空格分词的文字（CJK / 假名 / 全角 / 泰老高棉缅）直接相连，上一行以连字符结尾直接相连，其余补一个空格。新增 `ocrSpacedBlockAt`（`ocr_block_sentence.dart:232`）：块里没有不靠空格分词的文字、且不止一行时，把整块所有行拼成一串并把被点字下标换算过去；超过 1000 码元回落。查词窗按它显示整块、从被点字扫描查词，句子在拼好的整块上按句截（`_sourceOf`，`fushi/lib/src/pages/implementations/popup_dictionary_page.dart:173`）；日文 / 中文块仍走 BUG-3520 的「行 + 句子续行」。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/ocr_block_sentence_test.dart`（拼行 4 例：标点后补空格、西里尔 / 希腊、连字符、CJK 邻接拉丁不变；`ocrSpacedBlockAt` 6 例：整块与下标换算、首末行、行首尾空白、含 CJK 不启用、单行 / 偏移 / 越界、超长回落）；`fushi/test/pages/popup_dictionary_source_line_test.dart`（法语三行块点第二行：条上为整块、扫描从被点词起、制卡与 AI 句子为该句；条上点另一句的词换句）。
- **备注**：判据是块内容（有没有 CJK 等字符），不是语言设置：混排的块（一个日文词夹在拉丁文里）按日文处理。未在真机复测（本环境无 Android 设备）。
