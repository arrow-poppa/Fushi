## BUG-4219 · 音乐歌词点拉丁单词中间的字母只查到半个词（bikbik → bik）
- **报告**：2026-11-25（用户：合并最新版后，音乐歌词里点 `bikbik` 查的是 `bik`；其它模块没见到）
- **真实性**：✅ 真 bug。拉丁单词「退到词首」的取词规则（`fushi/lib/src/lookup/latin_word_lookup.dart` 的 `latinLookupStartAt`）已接进视频字幕（`subtitleTranscriptLookupSpan`）、源文本条 / 截屏识字（`sourceLookupSuffixAt`）、悬浮歌词（`lookupWordAtIndex`），但音乐歌词页自己的取词函数没迁：`musicLyricsLookupTerm`（修前 `fushi/lib/src/pages/implementations/music/music_lyrics_page.dart:168`）直接 `lineText.substring(charIndexInLine)`。卡拉 OK 命中测试（`karaoke_line_layout.dart:265` `hitTest`）回报的是音节里**被点的那个字**，于是点 `bikbik` 的后半段就从 `bik…` 起查。
- **[x] ① 已修复**（本提交）— `musicLyricsLookupSpan`（`music_lyrics_page.dart`）把命中的 UTF-16 下标换成字位下标后交给视频字幕同一份 `subtitleTranscriptLookupSpan`（拉丁词退到词首、连字符复合词按词典探测、跳过前导空白 / 标点，CJK 起点不变），再把起点换回 UTF-16 偏移；`_onLookup` 用新起点切源注音区间（`musicLyricsRubySpans`），点在纯空白 / 标点上不再暂停、不弹空浮层。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/lyrics/music_lyrics_page_logic_test.dart`（日文起点不变；越界 / 纯标点；`bikbik` 每个字母都退到词首；词间空格；重音字母与 NFD 组合附加符；代理对下标映射；连字符复合词有 / 无整词）。
- **备注**：本机无 Flutter SDK，测试未在本地执行，靠 `linux-x64-artifact.yml` 的定向测试步骤验证；未在设备上复测音乐歌词页。
