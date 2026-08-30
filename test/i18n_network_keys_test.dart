import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/i18n/replica_strings.dart';
import 'package:pixiv_func/core/settings/app_settings.dart';

/// Pins i18n key completeness across all four languages (zh/en/ja/ru).
///
/// The network settings schema added new keys (ECH front host, insecure
/// fallback tier) — this fixture catches a translation landing in only one
/// language. It additionally asserts the insecureNoSni settings default to
/// OFF (PRD R6/AC7).
void main() {
  const newNetworkKeys = [
    'networkEchFrontHost',
    'networkEchFrontHostHint',
    'networkEchHostInvalid',
    'networkInsecureNoSni',
    'networkInsecureNoSniHint',
    'networkInsecureNoSniWarning',
  ];

  test('new network i18n keys exist in all four languages', () {
    for (final language in ReplicaLanguage.values) {
      for (final key in newNetworkKeys) {
        expect(
          ReplicaStrings.fromTag(language.tag, key),
          isNotEmpty,
          reason: '$key missing in ${language.tag}',
        );
      }
    }
  });

  test('insecureNoSni setting defaults to off when absent from storage', () {
    // Covered by AppSettings defaults; assert through the provider-level
    // effective value used by the policy (which reads the same default).
    // This test guards the R6 gate: no probe failure may flip it.
    // (The policy ctor is exercised in restricted_compat_network_test;
    // here we pin the storage default.)
    const settings = AppSettings(
      guideCompleted: true,
      languageTag: 'zh-CN',
      themeCode: 0,
    );
    expect(settings.insecureNoSniEnabled, isFalse);
    expect(settings.echFrontHost, 'cloudflare-ech.com');
  });
}
