import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'translation_credentials.dart';

/// Retires the secure-storage and WebView state owned by the removed
/// web-login translation provider. Other sites' cookies are left untouched.
Future<void> retireLegacyTranslationData(
  TranslationCredentialStore store,
) async {
  await store.retireLegacyWebSession();
  final manager = CookieManager.instance();
  final site = WebUri('https://www.doubao.com');
  await manager.deleteCookies(url: site);
  await manager.deleteCookies(url: site, domain: '.doubao.com');
}
