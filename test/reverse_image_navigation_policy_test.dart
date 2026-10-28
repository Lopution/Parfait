import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/reverse_image/reverse_image_engine.dart';
import 'package:parfait/core/reverse_image/reverse_image_navigation_policy.dart';

void main() {
  final policy = ReverseImageNavigationPolicy(
    ReverseImageEngineSpecs.sauceNao.webViewHosts,
  );

  ReverseImageNavigationAction decide(String url) =>
      policy.decide(Uri.tryParse(url));

  test('each link gets its action', () {
    const navigate = ReverseImageNavigationAction.navigate;
    const openIllust = ReverseImageNavigationAction.openIllust;
    const openUser = ReverseImageNavigationAction.openUser;
    const openExternal = ReverseImageNavigationAction.openExternal;
    const reject = ReverseImageNavigationAction.reject;
    for (final (url, action) in [
      // saucenao.com navigates freely inside the webview.
      ('https://saucenao.com/search.php?db=999', navigate),
      ('https://www.saucenao.com/results?x=1', navigate),
      ('https://saucenao.com/tools.php', navigate),
      // Pixiv links open the app's detail and user pages.
      ('https://www.pixiv.net/artworks/12345', openIllust),
      ('https://www.pixiv.net/i/99', openIllust),
      ('https://www.pixiv.net/en/artworks/1', openIllust),
      (
        'https://www.pixiv.net/member_illust.php?mode=medium&illust_id=99',
        openIllust,
      ),
      ('https://www.pixiv.net/users/42', openUser),
      ('https://www.pixiv.net/u/7', openUser),
      ('https://www.pixiv.net/member.php?id=42', openUser),
      // Other HTTPS links go to the external launcher.
      ('https://example.com/result', openExternal),
      ('https://www.pixiv.net/help', openExternal),
      // Non-HTTPS, malformed, and foreign links with credentials or a
      // fragment are rejected.
      ('http://saucenao.com/x', reject),
      ('javascript:alert(1)', reject),
      ('https://', reject),
      ('', reject),
      ('https://user:pass@example.com/x', reject),
      ('https://example.com/x#frag', reject),
    ]) {
      expect(decide(url), action, reason: url);
    }
    expect(policy.decide(null), reject);
  });

  test('each engine host set scopes its own webview', () {
    for (final spec in ReverseImageEngineSpecs.all.values) {
      final enginePolicy = ReverseImageNavigationPolicy(spec.webViewHosts);
      for (final host in spec.webViewHosts) {
        expect(
          enginePolicy.decide(Uri.parse('https://$host/')),
          ReverseImageNavigationAction.navigate,
          reason: '${spec.engine} should navigate inside $host',
        );
      }
      // A foreign engine's host is never in-scope for this webview.
      final foreign = ReverseImageEngineSpecs.all.values
          .expand((other) => other.webViewHosts)
          .firstWhere((host) => !spec.webViewHosts.contains(host));
      expect(
        enginePolicy.decide(Uri.parse('https://$foreign/')),
        isNot(ReverseImageNavigationAction.navigate),
        reason: '${spec.engine} must not navigate to $foreign',
      );
    }
  });
}
