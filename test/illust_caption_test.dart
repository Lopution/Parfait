import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/entity/illust_caption.dart';

void main() {
  group('parseIllustCaption', () {
    test('plain text passes through with entity decoding', () {
      final result = parseIllustCaption('hello &amp; goodbye &lt;3');
      expect(result.unobservedTags, isEmpty);
      expect(result.spans, [
        isA<CaptionText>()
            .having((s) => s.text, 'text', 'hello & goodbye <3'),
      ]);
    });

    test('br renders as explicit breaks', () {
      final result = parseIllustCaption('a<br>b<br/>c<br />d');
      expect(
        result.spans,
        [
          const CaptionText('a'),
          const CaptionBreak(),
          const CaptionText('b'),
          const CaptionBreak(),
          const CaptionText('c'),
          const CaptionBreak(),
          const CaptionText('d'),
        ],
      );
    });

    test('links keep href and text, tags inside link text are stripped', () {
      final result = parseIllustCaption(
        'see <a href="https://www.pixiv.net/users/123">author</a> now',
      );
      expect(result.spans, [
        const CaptionText('see '),
        const CaptionLink(
          href: 'https://www.pixiv.net/users/123',
          text: 'author',
        ),
        const CaptionText(' now'),
      ]);
      expect(result.unobservedTags, isEmpty);
    });

    test('numeric entities decode', () {
      final result = parseIllustCaption('&#65; &#x42; &#9731;');
      expect(result.spans.single, isA<CaptionText>());
      expect((result.spans.single as CaptionText).text, 'A B \u2603');
    });

    test('unknown tags are stripped but stay observable', () {
      final result = parseIllustCaption(
        '<span class="x">keep</span> <b>bold</b>',
      );
      expect(
        result.spans.whereType<CaptionText>().map((s) => s.text).join(),
        'keep bold',
      );
      expect(result.unobservedTags, ['b', 'span']);
    });

    test('unclosed tag keeps the remainder as text', () {
      final result = parseIllustCaption('oops <a href="broken');
      expect(
        result.spans.whereType<CaptionText>().map((s) => s.text).join(),
        'oops <a href="broken',
      );
    });

    test('stray closing a and comments are ignored', () {
      final result = parseIllustCaption('<!-- note -->x</a>y');
      expect(
        result.spans.whereType<CaptionText>().map((s) => s.text).join(),
        'xy',
      );
    });
  });
}