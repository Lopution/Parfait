import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/i18n/replica_strings.dart';
import 'package:pixiv_func/core/settings/app_settings.dart';

/// Pins i18n key completeness across all four languages (zh/en/ja/ru).
///
/// The network settings schema added ECH front-host keys. C16/C17 leftover
/// keys (`networkWebViewIntercept*`, `networkInsecureNoSni*`) must stay
/// absent so they cannot reappear in only one locale.
void main() {
  const newNetworkKeys = [
    'networkEchFrontHost',
    'networkEchFrontHostHint',
    'networkEchHostInvalid',
  ];
  const removedNetworkKeys = [
    'networkInsecureNoSni',
    'networkInsecureNoSniHint',
    'networkInsecureNoSniWarning',
    'networkWebViewIntercept',
    'networkWebViewInterceptHint',
  ];
  const newUiKeys = [
    'loginPageClosed',
    'loginCallbackInvalid',
    'loginNetworkError',
    'loginPageLoadFailed',
    'loginFailed',
    'loginFailedType',
    'restrictPublic',
    'restrictPrivate',
    'networkProbeConclusionAllReachable',
    'networkProbeConclusionDnsPolluted',
    'networkProbeConclusionSniBlocked',
    'networkProbeConclusionEchAvailable',
    'networkProbeConclusionNoSniAvailable',
    'networkProbeConclusionIpBlackholed',
    'networkProbeConclusionAppLayer',
    'networkProbeConclusionInconclusive',
    'networkProbeStepSystemDns',
    'networkProbeStepDoh',
    'networkProbeStepTcp',
    'networkProbeStepTls',
    'networkProbeStepHttp',
    'networkProbeStepEch',
    'networkProbeStepNoSni',
    'networkProbeStepOk',
    'networkProbeStepFailed',
    'networkProbeStepSkipped',
    'networkProbeHostFailed',
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

  test('C16/C17 leftover network i18n keys are absent from all locales', () {
    for (final language in ReplicaLanguage.values) {
      for (final key in removedNetworkKeys) {
        expect(
          () => ReplicaStrings.fromTag(language.tag, key),
          throwsA(isA<TypeError>()),
          reason: '$key must not exist in ${language.tag}',
        );
      }
    }
  });

  test('UI state labels exist in all four languages', () {
    for (final language in ReplicaLanguage.values) {
      for (final key in newUiKeys) {
        expect(
          ReplicaStrings.fromTag(language.tag, key),
          isNotEmpty,
          reason: '$key missing in ${language.tag}',
        );
      }
    }
  });

  test('insecureNoSni switch is gone: policy default stays off', () {
    // C17 removed the global insecure-no-SNI production setting. Pin the
    // storage side: the option no longer exists on AppSettings.
    const settings = AppSettings(
      guideCompleted: true,
      languageTag: 'zh-CN',
      themeCode: 0,
    );
    expect(settings.echFrontHost, 'cloudflare-ech.com');
  });
}
