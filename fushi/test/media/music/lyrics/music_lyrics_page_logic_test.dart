import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_clock.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';

/// 歌词页里不依赖 AppModel 的判据：查词暂停、查词起点、播放项 → 歌词曲目、插值时钟。
void main() {
  test('查词暂停：设置开着且在播才暂停', () {
    expect(
      musicLyricsShouldPauseForLookup(settingEnabled: true, playing: true),
      isTrue,
    );
    expect(
      musicLyricsShouldPauseForLookup(settingEnabled: false, playing: true),
      isFalse,
    );
    expect(
      musicLyricsShouldPauseForLookup(settingEnabled: true, playing: false),
      isFalse,
    );
  });

  KaraokeLookupHit hitAt(String lineText, int charIndexInLine) =>
      KaraokeLookupHit(
        lineIndex: 0,
        syllableIndex: 0,
        charIndexInLine: charIndexInLine,
        lineText: lineText,
        globalRect: Rect.zero,
      );

  test('查词起点：日文从命中字符到行尾', () {
    expect(musicLyricsLookupSpan(hitAt('夜に駆ける', 2)), (
      start: 2,
      term: '駆ける',
    ));
  });

  test('查词起点：越界或只点到空白 / 标点时没有查词串', () {
    expect(musicLyricsLookupSpan(hitAt('ab', 99)), (start: -1, term: ''));
    expect(musicLyricsLookupSpan(hitAt('ab', -1)), (start: -1, term: ''));
    expect(musicLyricsLookupSpan(hitAt('ab！', 2)), (start: -1, term: ''));
  });

  test('查词起点：拉丁单词点中间任意字母都退到词首（不查成 bik）', () {
    for (int i = 0; i < 'bikbik'.length; i++) {
      expect(
        musicLyricsLookupSpan(hitAt('bikbik dance', i)),
        (start: 0, term: 'bikbik dance'),
        reason: 'tapped index $i',
      );
    }
    expect(musicLyricsLookupSpan(hitAt('say bikbik', 7)), (
      start: 4,
      term: 'bikbik',
    ));
    // 点在词间空格上：跳过前导空白，从下一个词起查。
    expect(musicLyricsLookupSpan(hitAt('say bikbik', 3)), (
      start: 4,
      term: 'bikbik',
    ));
  });

  test('查词起点：重音字母与组合附加符都算拉丁单词', () {
    expect(musicLyricsLookupSpan(hitAt('o coração', 6)), (
      start: 2,
      term: 'coração',
    ));
    // NFD：e + U+0301，点在附加符上仍属于这个词。
    const String nfd = 'cafe\u0301 noir';
    expect(musicLyricsLookupSpan(hitAt(nfd, 4)), (start: 0, term: nfd));
  });

  test('查词起点：UTF-16 下标按代理对映射到字位，起点回报 UTF-16 偏移', () {
    // 😀 占两个 UTF-16 码元：点后面的拉丁词时起点仍是正确的码元偏移。
    expect(musicLyricsLookupSpan(hitAt('😀 hello', 5)), (
      start: 3,
      term: 'hello',
    ));
  });

  test('查词起点：连字符复合词词典里有整词时退到复合词开头', () {
    int fullCompound(String text) =>
        text.startsWith('gaming-mode') ? 'gaming-mode'.length : 0;
    expect(
      musicLyricsLookupSpan(
        hitAt('gaming-mode on', 9),
        matchedUnits: fullCompound,
      ),
      (start: 0, term: 'gaming-mode on'),
    );
    // 词典没收复合词：停在被点那个词的词首，不查成前一段。
    expect(
      musicLyricsLookupSpan(
        hitAt('gaming-mode on', 9),
        matchedUnits: (String _) => 0,
      ),
      (start: 7, term: 'mode on'),
    );
  });

  test('CUE 虚拟曲目的起点带进歌词曲目（不认 sidecar / 内嵌）', () {
    final MusicLyricsTrackRef ref = musicLyricsTrackRefOf(
      const MusicPlayItem(
        trackUid: 'u',
        path: '/m/full.flac',
        title: 'T',
        startMs: 60000,
        endMs: 120000,
        durationMs: 60000,
      ),
    );
    expect(ref.isCueTrack, isTrue);
    expect(ref.durationMs, 60000);
  });

  test('插值时钟：在播时外推、封顶、暂停定住', () {
    expect(
      extrapolateMusicPosition(
        lastPosition: const Duration(seconds: 10),
        sinceLastEvent: const Duration(milliseconds: 80),
        playing: true,
      ),
      const Duration(milliseconds: 10080),
    );
    expect(
      extrapolateMusicPosition(
        lastPosition: const Duration(seconds: 10),
        sinceLastEvent: const Duration(seconds: 30),
        playing: true,
      ),
      const Duration(seconds: 12),
    );
    expect(
      extrapolateMusicPosition(
        lastPosition: const Duration(seconds: 10),
        sinceLastEvent: const Duration(seconds: 1),
        playing: false,
      ),
      const Duration(seconds: 10),
    );
    expect(
      extrapolateMusicPosition(
        lastPosition: const Duration(seconds: 59),
        sinceLastEvent: const Duration(seconds: 2),
        playing: true,
        duration: const Duration(seconds: 60),
      ),
      const Duration(seconds: 60),
    );
  });
}
