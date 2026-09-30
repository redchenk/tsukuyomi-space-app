import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:tsukuyomi_space_app/features/site/native_article_document.dart';
import 'package:tsukuyomi_space_app/features/site/native_article_embed.dart';
import 'package:tsukuyomi_space_app/features/site/native_media_view.dart';
import 'package:tsukuyomi_space_app/features/site/native_rich_text.dart';
import 'package:tsukuyomi_space_app/features/site/site_widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reader indexes h2/h3 as the same article-section anchors for HTML and Markdown', () {
    for (final (format, body) in [
      ('markdown', '# Title\n\n## First\n\n### Child\n\n## First'),
      (
        'html',
        '<h1>Title</h1><h2 id="old">First</h2><h3>Child</h3><h2>First</h2>',
      ),
    ]) {
      final doc = parseNativeArticle(body, format);
      expect(doc.headings.map((item) => item.id), [
        'article-section-1',
        'article-section-2',
        'article-section-3',
      ]);
      expect(doc.headings.map((item) => item.level), [2, 3, 2]);
      expect(doc.headings.map((item) => item.text), [
        'First',
        'Child',
        'First',
      ]);
    }
  });
  test('Markdown supports native math, mark variants, scripts, spoilers and hard line breaks', () {
    final doc = html.parseFragment(
      parseNativeArticle(
        r'==Marked=={.error} H~2~O x^2^ ~~deleted~~ :spoiler[<secret>] $x^2$'
            '\nnext\n\n'
            r'$$\frac{a}{b}$$',
        'markdown',
      ).html,
    );
    expect(doc.querySelector('mark')!.classes, contains('markdown-mark-error'));
    expect(doc.querySelector('sub')!.text, '2');
    expect(doc.querySelector('sup')!.text, '2');
    expect(doc.querySelector('del')!.text, 'deleted');
    expect(doc.querySelector('ts-spoiler')!.text, '<secret>');
    expect(doc.querySelectorAll('ts-math').map((node) => node.text), [
      r'x^2',
      r'\frac{a}{b}',
    ]);
    expect(doc.querySelectorAll('br'), hasLength(1));
  });
  test('currency, escaped dollars, unclosed formula and indented code remain literal', () {
    for (final source in [
      r'$ 5',
      r'$5 and $10',
      r'\$x\$',
      r'$$missing',
      '    \$code\$',
    ]) {
      expect(
        html
            .parseFragment(parseNativeArticle(source, 'markdown').html)
            .querySelectorAll('ts-math'),
        isEmpty,
      );
    }
  });
  test('nested containers, bracket titles and code fences do not swallow following content', () {
    final doc = html.parseFragment(
      parseNativeArticle(
        ':::details [Read more]\n## Hidden heading\n\n:::tip Hint\nInner\n:::\n\n```text\n:::warning\n:::\n```\n:::\n\nAfter',
        'markdown',
      ).html,
    );
    expect(doc.querySelector('summary')!.text, 'Read more');
    expect(doc.querySelector('details h2')!.id, 'article-section-1');
    expect(doc.querySelector('.markdown-callout-tip')!.text, contains('Inner'));
    expect(doc.querySelector('code')!.text, contains(':::warning'));
    expect(doc.text, contains('After'));
    expect(doc.querySelectorAll('details'), hasLength(1));
  });
  test(
    'GitHub alerts, tasks, abbreviations and tables use source-site semantics',
    () {
      final doc = html.parseFragment(
        parseNativeArticle(
          '> [!WARNING]\n> Danger\n\n- [ ] Todo\n- [x] Done\n\n*[SSR]: Server Side Rendering\n\nSSR but ISSR\n\n| Name | Value |\n| --- | --- |\n| a | b |',
          'markdown',
        ).html,
      );
      expect(doc.querySelector('.markdown-callout-warning'), isNotNull);
      expect(
        doc.querySelectorAll('.markdown-task-check').map((node) => node.text),
        ['☐ ', '☑ '],
      );
      expect(doc.querySelectorAll('abbr'), hasLength(1));
      expect(
        doc.querySelector('abbr')!.attributes['title'],
        'Server Side Rendering',
      );
      expect(doc.querySelector('table tbody td')!.text, 'a');
    },
  );
  test('footnote IDs match original prefix and repeated links retain separate backlinks', () {
    final doc = html.parseFragment(
      parseNativeArticle(
        'Text[^n] again[^n], inline^[Inline **note**].\n\n[^n]: Definition **body**',
        'markdown',
      ).html,
    );
    expect(
      doc.querySelectorAll('section.footnotes li').map((node) => node.id),
      ['article-footnote-1', 'article-footnote-2'],
    );
    expect(
      doc
          .querySelectorAll('sup.footnote-ref > a')
          .map((node) => node.attributes['href']),
      ['#article-footnote-1', '#article-footnote-1', '#article-footnote-2'],
    );
    expect(
      doc
          .querySelectorAll('.footnote-backref')
          .map((node) => node.attributes['href']),
      ['#fnref-n', '#fnref-n-2', '#article-footnote-2-ref'],
    );
    expect(doc.querySelector('#article-footnote-2 strong')!.text, 'note');
  });
  test(
    'code fence preserves filename, language and exact source including HTML',
    () {
      final doc = html.parseFragment(
        parseNativeArticle(
          '```js title="index.js"\nconsole.log("<tag>");\n```',
          'markdown',
        ).html,
      );
      expect(
        doc.querySelector('pre')!.attributes['data-metadata'],
        'title="index.js"',
      );
      expect(doc.querySelector('code')!.attributes['class'], 'language-js');
      expect(doc.querySelector('code')!.text, 'console.log("<tag>");\n');
    },
  );
  test(
    'media directives remain siblings and HTTPS iframe heights are bounded',
    () {
      final doc = html.parseFragment(
        parseNativeArticle(
          '::media[Video](/api/assets/v "video")\n\n::media[Audio](/api/assets/a "audio")\n\n::bilibili[Movie](BV1abc?p=3)\n\n::iframe[Frame](https://example.com "2000")\n\nAfter',
          'markdown',
        ).html,
      );
      expect(
        doc
            .querySelectorAll('ts-media')
            .map((node) => node.attributes['data-kind']),
        ['video', 'audio'],
      );
      expect(doc.querySelectorAll('iframe'), hasLength(2));
      expect(doc.querySelectorAll('iframe').last.attributes['height'], '900');
      expect(
        doc.querySelector('iframe')!.attributes['src'],
        contains('page=3'),
      );
      expect(doc.querySelector('iframe')!.parentNode, same(doc));
      expect(doc.text, contains('After'));
    },
  );
  test(
    'legacy pasted iframe receives the same bounded URL and presentation rules',
    () {
      final doc = html.parseFragment(
        parseNativeArticle(
          '<iframe src="https://example.com" title="Embed" height="100" srcdoc="<script>bad()</script>"></iframe>',
          'markdown',
        ).html,
      );
      final iframe = doc.querySelector('iframe')!;
      expect(iframe.attributes['src'], 'https://example.com');
      expect(iframe.attributes['title'], 'Embed');
      expect(iframe.attributes['height'], '220');
      expect(iframe.attributes.containsKey('srcdoc'), isFalse);
    },
  );
  test('Markdown author HTML is escaped and HTML format removes executable inputs and unsafe URLs', () {
    final markdown = html.parseFragment(
      parseNativeArticle(
        '<script>bad()</script>\n\n<img src="file:///private/x">',
        'markdown',
      ).html,
    );
    expect(markdown.querySelector('script'), isNull);
    expect(markdown.text, contains('<script>'));
    final doc = html.parseFragment(
      parseNativeArticle(
        '<script>bad()</script><img src="file:///private/x"><a href="javascript:bad()" onclick="bad()">link</a><video src="https://example.com/v" autoplay onplay="bad()"></video><iframe src="http://example.com"></iframe>',
        'html',
      ).html,
    );
    expect(doc.querySelectorAll('script,img,iframe'), isEmpty);
    expect(doc.querySelector('a')!.attributes, isEmpty);
    expect(doc.querySelector('video')!.attributes, {
      'src': 'https://example.com/v',
    });
  });
  test(
    'URL resolution only admits original network and raster image forms',
    () {
      for (final value in [
        'javascript:alert(1)',
        'file:///private/x',
        'asset:secret',
        'data:text/html;base64,PHNjcmlwdD4=',
        'https://user:secret@example.com/x',
        'https://example.com/\nheader',
      ]) {
        expect(nativeArticleUrl(value, image: true), '');
      }
      expect(nativeArticleUrl('//example.com/x'), 'https://example.com/x');
      expect(nativeArticleUrl('../asset'), '../asset');
      expect(
        nativeArticleUrl('data:image/png;base64,AAAA', image: true),
        'data:image/png;base64,AAAA',
      );
      expect(
        nativeArticleUrl('data:image/svg+xml;base64,AAAA', image: true),
        '',
      );
      expect(
        nativeBilibiliUrl('https://www.bilibili.com/video/av123?p=2'),
        contains('aid=123'),
      );
      expect(nativeBilibiliUrl('invalid'), '');
    },
  );

  Future<void> reader(
    WidgetTester tester,
    String content, {
    String anchor = '',
    String format = 'markdown',
    ValueChanged<String>? navigate,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: ArticleBody(
                key: const ValueKey('reader'),
                content: content,
                format: format,
                site: 'https://site.test',
                initialAnchor: anchor,
                onNavigate: navigate,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 1280.0]) {
    testWidgets(
      'reader renders formulas, horizontally scrollable code/tables and native media at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await reader(
          tester,
          '## First\n\n### Child\n\n\$x^2\$\n\n```js title="x.js"\nconst x = "${List.filled(60, 'abcdef').join()}";\n```\n\n| a | b | c | d |\n| --- | --- | --- | --- |\n| value | value | value | value |\n\n::media[Movie](/api/assets/video "video")\n\n::iframe[Demo](https://example.com "300")',
        );
        expect(find.byType(Math), findsOneWidget);
        expect(find.byType(NativeCodeBlock), findsOneWidget);
        expect(find.byType(NativeMediaView), findsOneWidget);
        expect(find.byType(NativeArticleEmbed), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is SingleChildScrollView &&
                widget.scrollDirection == Axis.horizontal,
          ),
          findsAtLeastNWidgets(2),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('spoiler reveals escaped text only after activation', (
    tester,
  ) async {
    await reader(tester, ':spoiler[<secret>]');
    expect(find.text('<secret>'), findsNothing);
    await tester.tap(find.text('剧透内容（点击显示）'));
    await tester.pumpAndSettle();
    expect(find.text('<secret>'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'code copy preserves exact source and reports clipboard failure honestly',
    (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await reader(tester, '```text\nline 1\nline 2\n```');
      await tester.tap(find.text('复制代码'));
      await tester.pumpAndSettle();
      expect(copied, 'line 1\nline 2\n');
      expect(find.text('已复制'), findsOneWidget);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              throw PlatformException(code: 'blocked');
            }
            return null;
          });
      await tester.tap(find.text('已复制'));
      await tester.pumpAndSettle();
      expect(find.text('复制失败，请重试'), findsOneWidget);
      expect(find.text('已复制'), findsNothing);
    },
  );
  testWidgets(
    'initial heading anchor unfolds its containing details and same-document hash changes scroll again',
    (tester) async {
      final body =
          '## Start\n\n${List.filled(45, 'long content').join('\n')}\n\n:::details Hidden\n## Target\n\nRevealed body\n:::'
              .toString();
      await reader(tester, body, anchor: 'article-section-2');
      final expanded = tester
          .widgetList<ExpansionTile>(find.byType(ExpansionTile))
          .firstWhere(
            (tile) =>
                tile.title is Text && (tile.title as Text).data == 'Hidden',
          );
      expect(expanded.initiallyExpanded, isTrue);
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scroll.position.pixels, greaterThan(100));
      final targetOffset = scroll.position.pixels;
      await reader(tester, body, anchor: 'article-section-1');
      expect(scroll.position.pixels, lessThan(targetOffset));
      expect(
        tester.getTopLeft(find.text('Start', findRichText: true)).dy,
        inInclusiveRange(0, 150),
      );
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      final manual = scroll.position.pixels;
      await reader(tester, body, anchor: 'article-section-1');
      expect(scroll.position.pixels, closeTo(manual, 1));
      await reader(tester, body, anchor: 'missing');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'footnote and back reference stay native without dispatching site navigation',
    (tester) async {
      final navigated = <String>[];
      await reader(
        tester,
        'Reference[^n]\n\n${List.filled(45, 'body').join('\n')}\n\n[^n]: Footnote',
        navigate: navigated.add,
      );
      await tester.tap(find.text('[1]'));
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scroll.position.pixels, greaterThan(100));
      final back = find.text('↩', findRichText: true);
      await tester.ensureVisible(back);
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('[1]')).dy, inInclusiveRange(0, 150));
      expect(navigated, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'malformed or oversized TeX remains readable without breaking the article',
    (tester) async {
      await reader(
        tester,
        r'$\invalid{x}$'
        '\n\n'
        '\$\$${List.filled(4001, 'x').join()}\$\$',
      );
      expect(find.text(r'\invalid{x}'), findsOneWidget);
      expect(find.byType(SelectableText), findsAtLeastNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
}
