import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/reverse_image/sauce_nao_navigation_policy.dart';

void main() {
  SauceNaoNavigationAction decide(String url) =>
      SauceNaoNavigationPolicy.decide(Uri.tryParse(url));

  test('saucenao.com navigates freely inside the webview', () {
    expect(
      decide('https://saucenao.com/search.php?db=999'),
      SauceNaoNavigationAction.navigate,
    );
    expect(
      decide('https://www.saucenao.com/results?x=1'),
      SauceNaoNavigationAction.navigate,
    );
    expect(
      decide('https://saucenao.com/tools.php'),
      SauceNaoNavigationAction.navigate,
    );
  });

  test('Pixiv illust links open the app detail page', () {
    expect(
      decide('https://www.pixiv.net/artworks/12345'),
      SauceNaoNavigationAction.openIllust,
    );
    expect(
      decide('https://www.pixiv.net/i/99'),
      SauceNaoNavigationAction.openIllust,
    );
  });

  test('Pixiv user links open the app user page', () {
    expect(
      decide('https://www.pixiv.net/users/42'),
      SauceNaoNavigationAction.openUser,
    );
    expect(
      decide('https://www.pixiv.net/u/7'),
      SauceNaoNavigationAction.openUser,
    );
  });

  test('other HTTPS hosts go to the external launcher', () {
    expect(
      decide('https://example.com/result'),
      SauceNaoNavigationAction.openExternal,
    );
    expect(
      decide('https://www.pixiv.net/en/artworks/1'),
    SauceNaoNavigationAction.openExternal,
    );
  });

  test('non-HTTPS and malformed URLs are rejected', () {
    expect(decide('http://saucenao.com/x'), SauceNaoNavigationAction.reject);
    expect(decide('javascript:alert(1)'), SauceNaoNavigationAction.reject);
    expect(decide('https://'), SauceNaoNavigationAction.reject);
    expect(decide(''), SauceNaoNavigationAction.reject);
    expect(
      SauceNaoNavigationPolicy.decide(null),
      SauceNaoNavigationAction.reject,
    );
  });

  test('credentials or fragments in foreign links are rejected', () {
    expect(
      decide('https://user:pass@example.com/x'),
      SauceNaoNavigationAction.reject,
    );
    expect(
      decide('https://example.com/x#frag'),
      SauceNaoNavigationAction.reject,
    );
  });
}
