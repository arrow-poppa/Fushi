/// Reads and writes the user's BYOK API keys.
///
/// A separate type from the settings store on purpose. Credentials have
/// different rules from every other preference — they never leave the device,
/// never follow a Profile, never reach a log — and giving them their own narrow
/// surface makes those rules reviewable in one place instead of scattered
/// through a 3000-line preferences class.
///
/// See `docs/agent/ai-explanation.md` §9.
///
/// ## Storage reality
///
/// Keys are stored as plaintext rows in the Drift `preferences` table, exactly
/// like every other secret in this repo today (`yomitan_api_key`,
/// `jimaku_api_key`, the qBittorrent password, the SFTP private keys). There is
/// **no** `flutter_secure_storage`, keychain or keystore integration anywhere in
/// Fushi, so this feature does not invent one for itself — that would be a
/// repo-wide change with its own migration story.
///
/// What does protect them is the export boundary: [AiPrefKeys.credentials] are
/// registered in `PrefRedactionPolicy`, which is the single predicate behind
/// backup archives, Profile snapshots and Profile sharing. This is a real
/// limitation and is recorded as such in the feature document — base64 is not
/// encryption, and neither is a plaintext row.
library;

import 'package:fushi/src/ai/ai_pref_keys.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

/// The narrow surface the AI layer uses to reach a credential.
abstract interface class AiCredentialStore {
  /// The stored key for [provider], trimmed. Empty when unset.
  String readApiKey(AiProvider provider);

  /// Whether [provider] has a usable key.
  bool hasApiKey(AiProvider provider);

  Future<void> writeApiKey(AiProvider provider, String apiKey);

  /// Forgets one provider's key.
  Future<void> clearApiKey(AiProvider provider);
}

/// The default implementation, backed by the app's `preferences` table.
class PrefsAiCredentialStore implements AiCredentialStore {
  const PrefsAiCredentialStore(this._prefs);

  final PrefStore _prefs;

  /// The preference key holding [provider]'s credential.
  static String keyFor(AiProvider provider) {
    switch (provider) {
      case AiProvider.openai:
        return AiPrefKeys.openaiApiKey;
      case AiProvider.gemini:
        return AiPrefKeys.geminiApiKey;
      case AiProvider.deepseek:
        return AiPrefKeys.deepseekApiKey;
      case AiProvider.custom:
        return AiPrefKeys.customApiKey;
    }
  }

  @override
  String readApiKey(AiProvider provider) {
    final Object? value = _prefs.getPref(keyFor(provider), defaultValue: '');
    return value is String ? value.trim() : '';
  }

  @override
  bool hasApiKey(AiProvider provider) => readApiKey(provider).isNotEmpty;

  @override
  Future<void> writeApiKey(AiProvider provider, String apiKey) {
    // Trimmed on the way in, so a key pasted with a trailing newline works on
    // every provider rather than failing only on the ones that do not trim.
    return _prefs.setPref(keyFor(provider), apiKey.trim());
  }

  @override
  Future<void> clearApiKey(AiProvider provider) =>
      _prefs.setPref(keyFor(provider), '');
}
