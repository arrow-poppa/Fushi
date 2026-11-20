## BUG-3525 · Google Lens 把用空格分词语言的折行粘成一个词
- **报告**：2026-10-19（接入截屏识字 Google Lens 时审代码发现；用户要用 Lens 读俄文、希腊文）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/ocr/google_lens_protocol.dart` 的 `decodeResponse` 把段落各行 `_normalize`（trim）后直接 `join()` 成句：CJK 没问题，但英文 / 俄文 / 葡语等折行的段落里，上一行末词与下一行首词之间的空格被吃掉（「мир」+「снова」→「мирснова」），查词与制卡句子都错。漫画整卷 OCR、在线直读、视频画面识别都走这条。
- **[x] ① 已修复**（`0fa466de22`）— 用空格分词的语言（与 `_normalize` 去不去词间空白同一口径：除 ja / zh 外）行间补一个空格；上一行以连字符结尾时不补（折行断词与带连字符的复合词保持一个词）。逐字区的 UTF-16 偏移按补空格后的行起点计算。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/ocr/google_lens_protocol_test.dart`（「spaced languages join wrapped lines with a space」：俄文两行成句、第二行逐字区仍对准；「a line ending in a hyphen keeps the word together」）。
- **备注**：后续（`agent/claude-ai-explanation-v3.0.0-lens-auto`）改为按文字本身判断、不再看请求语言：挨着假名 / 汉字的空白去掉、行间接缝挨着假名 / 汉字时不补空格，其余（拉丁、西里尔、希腊、韩文）保留词间空格——混排的一段各自成立，漫画语言设成日语也不会再把俄文的词间空格吃掉。日文 / 中文行为不变（同文件既有「上」「下」两行测试仍为「上下」）。未在真机上对真实 Lens 响应复测（本环境无 Android 设备）。
