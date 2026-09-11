/// The `preferences` keys owned by the BYOK AI Explanation feature.
///
/// One place, so a typo cannot silently read a default forever — the pattern
/// the rest of the repo enforces through `kKnownPreferenceKeys`, whose guard
/// test rejects any key not registered there.
///
/// 🔴 The six keys in [credentials] must never leave the device. They are
/// registered in `PrefRedactionPolicy.sensitiveKeys` and
/// `kCredentialPreferenceKeys`; see `docs/agent/ai-explanation.md` §9.
library;

abstract final class AiPrefKeys {
  // Behaviour — these follow Profiles and ride along with a backup.
  static const String provider = 'ai_explain_provider';
  static const String autoGenerate = 'ai_explain_auto_generate';
  static const String stream = 'ai_explain_stream';
  static const String cancelPending = 'ai_explain_cancel_pending';
  static const String unknownFallback = 'ai_explain_unknown_fallback';
  static const String prompt = 'ai_explain_prompt';
  static const String systemPrompt = 'ai_explain_system_prompt';
  static const String temperature = 'ai_explain_temperature';

  static const String openaiModel = 'ai_explain_openai_model';

  static const String geminiModel = 'ai_explain_gemini_model';
  static const String geminiThinkingLevel = 'ai_explain_gemini_thinking_level';

  static const String deepseekModel = 'ai_explain_deepseek_model';
  static const String deepseekThinkingMode =
      'ai_explain_deepseek_thinking_mode';
  static const String deepseekThinkingIntensity =
      'ai_explain_deepseek_thinking_intensity';

  static const String customModel = 'ai_explain_custom_model';
  static const String customRoutingMode = 'ai_explain_custom_routing_mode';
  static const String customRoutingSlugs = 'ai_explain_custom_routing_slugs';
  static const String customRoutingAllowFallbacks =
      'ai_explain_custom_routing_allow_fallbacks';
  static const String customThinkingMode = 'ai_explain_custom_thinking_mode';
  static const String customThinkingIntensity =
      'ai_explain_custom_thinking_intensity';
  static const String customThinkingValue = 'ai_explain_custom_thinking_value';

  // 🔴 Credentials and credential-bearing values — device-local, never exported.
  static const String openaiApiKey = 'ai_explain_openai_api_key';
  static const String geminiApiKey = 'ai_explain_gemini_api_key';
  static const String deepseekApiKey = 'ai_explain_deepseek_api_key';
  static const String customApiKey = 'ai_explain_custom_api_key';

  /// A private address, and it can carry a query credential. Its name has no
  /// credential shape, so it is protected only by being named explicitly.
  static const String customEndpoint = 'ai_explain_custom_endpoint';

  /// Deep-merged into the request body, and can contain a key outright. Same
  /// shape-less problem as [customEndpoint].
  static const String customRequestBodyJson = 'ai_explain_custom_body_json';

  /// Every key that must be excluded from backup, Profile snapshots and Profile
  /// sharing. Asserted against `PrefRedactionPolicy` by
  /// `fushi/test/ai/ai_credential_redaction_test.dart`.
  static const Set<String> credentials = <String>{
    openaiApiKey,
    geminiApiKey,
    deepseekApiKey,
    customApiKey,
    customEndpoint,
    customRequestBodyJson,
  };
}
