import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';

/// BYOK means the user's own API keys sit in this app's preference table, so
/// "does this key leave the device" stops being a policy question and becomes a
/// correctness one.
///
/// [PrefRedactionPolicy] is the single predicate behind all three egress
/// channels (backup zip, Profile snapshot, Profile share JSON) plus the
/// import-side preserve, so pinning the AI keys against it pins every channel at
/// once. See `docs/agent/ai-explanation.md` §9.
///
/// The two tests that matter most are the shape-less ones: `ai_explain_custom_*`
/// endpoint and request-body JSON contain no `api_key`/`token`/`secret`
/// substring, so the shape fallback does **not** catch them. They are only
/// protected because they are named explicitly, and a future cleanup that
/// "tidies away redundant entries" would silently start exporting a user's
/// private endpoint and any key embedded in their custom body.
void main() {
  /// Every AI preference key that must never leave the device.
  const List<String> aiCredentialKeys = <String>[
    'ai_explain_openai_api_key',
    'ai_explain_gemini_api_key',
    'ai_explain_deepseek_api_key',
    'ai_explain_custom_api_key',
    'ai_explain_custom_endpoint',
    'ai_explain_custom_body_json',
  ];

  /// AI preference keys that are ordinary behaviour settings. These *should*
  /// follow Profiles and ride along with a backup — redacting them would be a
  /// silent feature regression, so the boundary is asserted in both directions.
  const List<String> aiBehaviourKeys = <String>[
    'ai_explain_provider',
    'ai_explain_auto_generate',
    'ai_explain_stream',
    'ai_explain_cancel_pending',
    'ai_explain_unknown_fallback',
    'ai_explain_prompt',
    'ai_explain_system_prompt',
    'ai_explain_temperature',
    'ai_explain_openai_model',
    'ai_explain_gemini_model',
    'ai_explain_gemini_thinking_level',
    'ai_explain_deepseek_model',
    'ai_explain_deepseek_thinking_mode',
    'ai_explain_deepseek_thinking_intensity',
    'ai_explain_custom_model',
    'ai_explain_custom_routing_mode',
    'ai_explain_custom_routing_slugs',
    'ai_explain_custom_routing_allow_fallbacks',
    'ai_explain_custom_thinking_mode',
    'ai_explain_custom_thinking_intensity',
    'ai_explain_custom_thinking_value',
  ];

  group('AI credentials never leave the device', () {
    test('every AI credential key is redacted', () {
      for (final String key in aiCredentialKeys) {
        expect(PrefRedactionPolicy.isDeviceLocalOrCredential(key), isTrue,
            reason: '$key holds a BYOK credential and must not be exported');
      }
    });

    test('every AI credential key is excluded from Profile snapshots', () {
      // Profile snapshots are a separate egress path from the backup zip: they
      // copy the whole pref table into `profile_settings`, and switching
      // Profiles writes them back. A key that follows Profiles would also be
      // copied between them, so this is both a leak and a cross-contamination
      // guard.
      for (final String key in aiCredentialKeys) {
        expect(ProfileKeys.isExcludedPref(key), isTrue,
            reason: '$key must not enter profile_settings');
      }
    });

    test('the shape-less credential keys are caught by explicit naming', () {
      // Regression guard with teeth: these two carry no credential-shaped
      // substring, so if someone removes them from `sensitiveKeys` believing the
      // shape fallback covers them, this fails.
      for (final String key in <String>[
        'ai_explain_custom_endpoint',
        'ai_explain_custom_body_json',
      ]) {
        final bool matchesShape = PrefRedactionPolicy.credentialSubstrings
            .any((String s) => key.toLowerCase().contains(s));
        expect(matchesShape, isFalse,
            reason: '$key deliberately has no credential shape; '
                'if this ever becomes true the test below stops proving anything');
        expect(PrefRedactionPolicy.sensitiveKeys.contains(key), isTrue,
            reason: '$key is only protected by being named explicitly');
      }
    });

    test('the provider API keys are named as well as shape-matched', () {
      // Belt and braces, matching this file's stated convention: an auditor must
      // see the full credential list without having to evaluate the substring
      // rule in their head.
      for (final String key in <String>[
        'ai_explain_openai_api_key',
        'ai_explain_gemini_api_key',
        'ai_explain_deepseek_api_key',
        'ai_explain_custom_api_key',
      ]) {
        expect(PrefRedactionPolicy.sensitiveKeys.contains(key), isTrue,
            reason: '$key must be listed explicitly, not left to the fallback');
      }
    });

    test('the credential registry agrees with the redaction policy', () {
      // Two registries describe the same fact; drift between them is how a key
      // ends up protected in one place and not the other.
      for (final String key in aiCredentialKeys) {
        expect(kCredentialPreferenceKeys.contains(key), isTrue,
            reason: '$key must be registered in kCredentialPreferenceKeys');
      }
    });
  });

  group('AI behaviour settings stay portable', () {
    test('behaviour keys are not redacted', () {
      for (final String key in aiBehaviourKeys) {
        expect(PrefRedactionPolicy.isDeviceLocalOrCredential(key), isFalse,
            reason: '$key is a behaviour preference and should follow backups');
      }
    });

    test('behaviour keys are not excluded from Profile snapshots', () {
      // The user asked for AI behaviour to respect Profiles; per-Profile prompt
      // or provider choices are the point of the feature.
      for (final String key in aiBehaviourKeys) {
        expect(ProfileKeys.isExcludedPref(key), isFalse,
            reason: '$key should follow the active Profile');
      }
    });

    test('no behaviour key is misfiled as a credential', () {
      for (final String key in aiBehaviourKeys) {
        expect(kCredentialPreferenceKeys.contains(key), isFalse,
            reason: '$key is not a credential');
      }
    });
  });

  group('registry completeness', () {
    test('every AI key is registered in kKnownPreferenceKeys', () {
      // The guard test scans getPref/setPref call sites, but it cannot see keys
      // that no code reads yet. This keeps the registry honest while the feature
      // is still being built out.
      for (final String key in <String>[...aiCredentialKeys, ...aiBehaviourKeys]) {
        expect(kKnownPreferenceKeys.contains(key), isTrue,
            reason: '$key must be registered before use');
      }
    });

    test('the AI key set is exactly the keys prefixed ai_explain_', () {
      // Catches a key added to the registry but forgotten here — which would
      // mean a new setting nobody classified as credential or behaviour.
      final Set<String> registered = kKnownPreferenceKeys
          .where((String k) => k.startsWith('ai_explain_'))
          .toSet();
      final Set<String> classified = <String>{
        ...aiCredentialKeys,
        ...aiBehaviourKeys,
      };
      expect(registered, classified,
          reason: 'every ai_explain_* key must be classified as either a '
              'credential or a behaviour preference');
    });
  });
}
