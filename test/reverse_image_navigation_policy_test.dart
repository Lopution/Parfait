import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_engine.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_navigation_policy.dart';

void main() {
  final policy = ReverseImageNavigationPolicy(
    ReverseImageEngineSpecs.sauceNao.webViewHosts,
  );

  ReverseImageNavigationAction decide(String url) =>
      policy.decide(Uri.tryParse(url));

  test('saucenao.com navigates freely inside the webview', () {
    expect(
      decide('https://saucenao.com/search.php?db=999'),
      ReverseImageNavigationAction.navigate,
    );
    expect(
      decide('https://www.saucenao.com/results?x=1'),
      ReverseImageNavigationAction.navigate,
    );
    expect(
      decide('https://saucenao.com/tools.php'),
      ReverseImageNavigationAction.navigate,
    );
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

  test('Pixiv illust links open the app detail page', () {
    expect(
      decide('https://www.pixiv.net/artworks/12345'),
      ReverseImageNavigationAction.openIllust,
    );
    expect(
      decide('https://www.pixiv.net/i/99'),
      ReverseImageNavigationAction.openIllust,
    );
    // Changed: /en/artworks/<id> was previously openExternal (unmapped).
    expect(
      decide('https://www.pixiv.net/en/artworks/1'),
      ReverseImageNavigationAction.openIllust,
    );
    expect(
      decide(
        'https://www.pixiv.net/member_illust.php?mode=medium&illust_id=99',
      ),
      ReverseImageNavigationAction.openIllust,
    );
  });

  test('Pixiv user links open the app user page', () {
    expect(
      decide('https://www.pixiv.net/users/42'),
      ReverseImageNavigationAction.openUser,
    );
    expect(
      decide('https://www.pixiv.net/u/7'),
      ReverseImageNavigationAction.openUser,
    );
    expect(
      decide('https://www.pixiv.net/member.php?id=42'),
      ReverseImageNavigationAction.openUser,
    );
  });

  test('other HTTPS hosts go to the external launcher', () {
    expect(
      decide('https://example.com/result'),
      ReverseImageNavigationAction.openExternal,
    );
    expect(
      decide('https://www.pixiv.net/help'),
      ReverseImageNavigationAction.openExternal,
    );
  });

  test('non-HTTPS and malformed URLs are rejected', () {
    expect(
      decide('http://saucenao.com/x'),
      ReverseImageNavigationAction.reject,
    );
    expect(decide('javascript:alert(1)'), ReverseImageNavigationAction.reject);
    expect(decide('https://'), ReverseImageNavigationAction.reject);
    expect(decide(''), ReverseImageNavigationAction.reject);
    expect(policy.decide(null), ReverseImageNavigationAction.reject);
  });

  test('credentials or fragments in foreign links are rejected', () {
    expect(
      decide('https://user:pass@example.com/x'),
      ReverseImageNavigationAction.reject,
    );
    expect(
      decide('https://example.com/x#frag'),
      ReverseImageNavigationAction.reject,
    );
  });
}
