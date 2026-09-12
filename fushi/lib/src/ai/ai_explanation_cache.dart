/// Short-lived cache for generated explanations.
///
/// Mirrors the reference extension's 60-second in-memory cache
/// (`js/display/ai-explanation-generator.js:34-38`, `:214-218`, GPL-3.0,
/// Copyright (C) 2023-2025 Yomitan Authors). See
/// `docs/agent/ai-explanation.md` §5.7.
///
/// The point is not to save money over a session — it is to stop a popup that
/// re-renders (mouse move, resize, a second lookup of the word you are still
/// reading) from paying for the same answer twice within seconds.
library;

import 'dart:convert';

import 'package:fushi/src/ai/ai_provider_config.dart';

/// How long a cached answer stays usable.
const Duration kAiExplanationCacheTtl = Duration(minutes: 1);

/// Upper bound on retained entries.
///
/// The reference never evicts — its map grows for the life of the frame. Here
/// the cache lives as long as the app, so it needs a bound; explanations are
/// multi-kilobyte strings and a long reading session produces a lot of lookups.
const int kAiExplanationCacheMaxEntries = 64;

/// Builds the cache key for one lookup.
///
/// **Divergence from the reference** (`docs/agent/ai-explanation.md` §8.3):
/// upstream keys on `[profileIndex, term, sentence]` only, so changing the
/// model, the prompt or the temperature keeps serving the previous answer for up
/// to a minute. Including [AiProviderConfig.generationSignature] is what makes
/// "change a setting, look the word up again" actually regenerate.
///
/// JSON-encoded so no field can forge a boundary, and it contains no credential:
/// the API key does not change the answer, so cache keys stay safe to log.
String buildAiExplanationCacheKey({
  required String profileId,
  required String target,
  required String sentence,
  required AiProviderConfig config,
}) {
  return jsonEncode(<Object?>[
    profileId,
    target,
    sentence,
    config.generationSignature,
  ]);
}

/// A bounded, TTL'd map from cache key to answer.
class AiExplanationCache {
  AiExplanationCache({
    this.ttl = kAiExplanationCacheTtl,
    this.maxEntries = kAiExplanationCacheMaxEntries,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _now;

  /// Insertion-ordered, so the oldest entry is the first key — that is what
  /// makes the eviction below O(1) without a separate LRU structure.
  final Map<String, _CacheEntry> _entries = <String, _CacheEntry>{};

  /// The cached answer for [key], or null when absent or stale.
  String? read(String key) {
    final _CacheEntry? entry = _entries[key];
    if (entry == null) return null;
    if (_now().difference(entry.storedAt) >= ttl) {
      _entries.remove(key);
      return null;
    }
    return entry.text;
  }

  /// Stores a completed answer.
  ///
  /// Refuses blank text: an empty answer is a failure the caller renders as a
  /// message, and caching it would keep that failure sticky for a minute.
  void write(String key, String text) {
    if (text.trim().isEmpty) return;
    // Re-insert so the entry moves to the end of the insertion order and a
    // refreshed key is not the next one evicted.
    _entries
      ..remove(key)
      ..[key] = _CacheEntry(text: text, storedAt: _now());
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Drops one entry. Regenerating uses this so the forced request cannot be
  /// answered from the cache it is trying to replace.
  void invalidate(String key) => _entries.remove(key);

  void clear() => _entries.clear();

  /// Live entry count, after pruning anything already stale. Test-facing.
  int get length {
    _entries.removeWhere(
      (String _, _CacheEntry e) => _now().difference(e.storedAt) >= ttl,
    );
    return _entries.length;
  }
}

class _CacheEntry {
  const _CacheEntry({required this.text, required this.storedAt});

  final String text;
  final DateTime storedAt;
}
