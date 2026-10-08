import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/app/format/content_locale.dart';

void main() {
  test('content text gets the locale of the script it needs', () {
    const zh = Locale('zh', 'CN');
    const en = Locale('en', 'US');
    expect(contentScriptLocale('制服ケイちゃん', zh), const Locale('ja'));
    expect(contentScriptLocale('ほうかご', zh), const Locale('ja'));
    expect(contentScriptLocale('힘내세요 선생님', zh), const Locale('ko'));
    // Han alone resolves through a CJK UI locale; elsewhere it needs one.
    expect(contentScriptLocale('原神', zh), isNull);
    expect(contentScriptLocale('原神', en), const Locale('ja'));
    expect(contentScriptLocale('Mika', zh), isNull);
  });
}
