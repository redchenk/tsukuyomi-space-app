import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:markdown/markdown.dart' as md;

const nativeCalloutLabels = <String, String>{
  'note': 'Note',
  'info': 'Info',
  'tip': 'Tip',
  'important': 'Important',
  'warning': 'Warning',
  'caution': 'Caution',
  'details': 'Details',
};

String _escape(String value) => const HtmlEscape().convert(value);

/// The same URL forms accepted by the site's bounded Markdown renderer.
String nativeArticleUrl(String value, {bool image = false}) {
  var source = value.trim().replaceAll('&amp;', '&');
  if (source.isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(source)) return '';
  if (source.startsWith('//')) source = 'https:$source';
  if (image &&
      RegExp(
        r'^data:image/(?:png|jpe?g|gif|webp);base64,[a-z0-9+/=\s]+$',
        caseSensitive: false,
      ).hasMatch(source)) {
    return source.replaceAll(RegExp(r'\s'), '');
  }
  final uri = Uri.tryParse(source);
  if (uri == null || uri.userInfo.isNotEmpty) return '';
  if (uri.hasScheme) {
    return ['https', 'http'].contains(uri.scheme) && uri.host.isNotEmpty
        ? source
        : '';
  }
  return RegExp(r'^(?:/(?!/)|\./|\.\./|#)').hasMatch(source) ? source : '';
}

String nativeBilibiliUrl(String value) {
  final source = value.replaceAll('&amp;', '&');
  final page =
      RegExp(
        r'[?&](?:p|page)=(\d+)',
        caseSensitive: false,
      ).firstMatch(source)?.group(1) ??
      '1';
  final bvid = RegExp(
    r'BV[a-zA-Z0-9]+',
    caseSensitive: false,
  ).firstMatch(source)?.group(0);
  final aid = RegExp(
    r'(?:av|aid=)(\d+)',
    caseSensitive: false,
  ).firstMatch(source)?.group(1);
  if (bvid == null && aid == null) return '';
  return Uri.https('player.bilibili.com', '/player.html', {
    'page': page,
    'high_quality': '1',
    'danmaku': '0',
    if (bvid != null) 'bvid': bvid else 'aid': aid!,
  }).toString();
}

class NativeArticleHeading {
  const NativeArticleHeading(this.id, this.text, this.level);
  final String id, text;
  final int level;
}

class NativeArticleDocument {
  const NativeArticleDocument(this.html, this.headings, this.anchorIds);
  final String html;
  final List<NativeArticleHeading> headings;
  final Set<String> anchorIds;
}

NativeArticleDocument parseNativeArticle(String content, String format) {
  final fragment = html.parseFragment(
    format == 'html' ? content : _markdown(content),
  );
  _sanitize(fragment);
  final headings = <NativeArticleHeading>[];
  final anchorIds = <String>{};
  for (final element in fragment.querySelectorAll('h2,h3')) {
    final id = 'article-section-${headings.length + 1}';
    element.attributes['id'] = id;
    headings.add(
      NativeArticleHeading(
        id,
        element.text.trim(),
        int.parse(element.localName!.substring(1)),
      ),
    );
  }
  for (final element in fragment.querySelectorAll('[id]')) {
    final id = element.id;
    if (id.isEmpty || !anchorIds.add(id)) element.attributes.remove('id');
  }
  return NativeArticleDocument(fragment.outerHtml, headings, anchorIds);
}

String _markdown(String source) {
  final abbreviations = <String, String>{};
  var fence = '';
  for (final line in const LineSplitter().convert(source)) {
    final marker = RegExp(r'^\s{0,3}(`{3,}|~{3,})').firstMatch(line)?.group(1);
    if (marker != null) {
      if (fence.isEmpty) {
        fence = marker[0];
      } else if (marker[0] == fence) {
        fence = '';
      }
    }
    if (fence.isNotEmpty) continue;
    final abbreviation = RegExp(r'^\*\[([^\]\n]+)\]:\s*(.+)$').firstMatch(line);
    if (abbreviation != null) {
      abbreviations[abbreviation[1]!] = abbreviation[2]!;
    }
  }
  final document = md.Document(
    withDefaultBlockSyntaxes: false,
    extensionSet: md.ExtensionSet.none,
    blockSyntaxes: [
      const md.EmptyBlockSyntax(),
      _ContainerSyntax(),
      _MediaSyntax(),
      _MathBlockSyntax(),
      _AbbreviationDefinitionSyntax(),
      const md.FencedCodeBlockSyntax(),
      const md.TableSyntax(),
      const md.FootnoteDefSyntax(),
      const md.AlertBlockSyntax(),
      const md.SetextHeaderSyntax(),
      const md.HeaderSyntax(),
      const md.CodeBlockSyntax(),
      const md.BlockquoteSyntax(),
      const md.HorizontalRuleSyntax(),
      const md.UnorderedListWithCheckboxSyntax(),
      const md.OrderedListWithCheckboxSyntax(),
      const md.LinkReferenceDefinitionSyntax(),
      const md.ParagraphSyntax(),
    ],
    inlineSyntaxes: [
      _MathInlineSyntax(),
      _SpoilerSyntax(),
      _MarkSyntax(),
      _ScriptSyntax('sub', '~'),
      _ScriptSyntax('sup', '^'),
      _InlineFootnoteSyntax(),
      if (abbreviations.isNotEmpty) _AbbreviationSyntax(abbreviations),
      md.StrikethroughSyntax(),
      md.AutolinkExtensionSyntax(),
      _LineBreakSyntax(),
    ],
  );
  final fragment = html.parseFragment(md.renderToHtml(document.parse(source)));
  for (final input in fragment.querySelectorAll('input[type=checkbox]')) {
    final check = dom.Element.tag('span')
      ..attributes['class'] = 'markdown-task-check'
      ..text = input.attributes.containsKey('checked') ? '☑ ' : '☐ ';
    input.replaceWith(check);
  }
  for (final alert in fragment.querySelectorAll('.markdown-alert')) {
    final type = alert.classes
        .firstWhere(
          (value) => value.startsWith('markdown-alert-'),
          orElse: () => 'markdown-alert-note',
        )
        .replaceFirst('markdown-alert-', '');
    alert.classes.addAll(['markdown-callout', 'markdown-callout-$type']);
  }
  _footnotes(fragment);
  return fragment.outerHtml;
}

void _footnotes(dom.DocumentFragment fragment) {
  final definitions = <String, dom.Element>{
    for (final note in fragment.querySelectorAll('li[id^="fn-"]'))
      note.id: note,
  };
  final inline = fragment.querySelectorAll('ts-footnote');
  for (var i = 0; i < inline.length; i++) {
    final id = 'inline-footnote-$i', ref = '$id-ref';
    final note = dom.Element.tag('li')..id = id;
    note.append(
      dom.Element.tag('p')..append(html.parseFragment(inline[i].innerHtml)),
    );
    note.append(
      dom.Element.tag('a')
        ..classes.add('footnote-backref')
        ..attributes['href'] = '#$ref'
        ..text = '↩',
    );
    definitions[id] = note;
    final sup = dom.Element.tag('sup')..classes.add('footnote-ref');
    sup.append(
      dom.Element.tag('a')
        ..id = ref
        ..attributes['href'] = '#$id'
        ..text = '0',
    );
    inline[i].replaceWith(sup);
  }
  final references = fragment.querySelectorAll('sup.footnote-ref > a');
  final numbers = <String, int>{};
  for (final ref in references) {
    final target = (ref.attributes['href'] ?? '').replaceFirst('#', '');
    if (!definitions.containsKey(target)) continue;
    final number = numbers.putIfAbsent(target, () => numbers.length + 1);
    ref.text = '$number';
    if (target.startsWith('inline-footnote-')) {
      final previous = ref.id;
      ref.id = 'article-footnote-$number-ref';
      for (final back in definitions[target]!.querySelectorAll('a')) {
        if (back.attributes['href'] == '#$previous') {
          back.attributes['href'] = '#${ref.id}';
        }
      }
    }
  }
  if (numbers.isEmpty) return;
  var section = fragment.querySelector('section.footnotes');
  if (section == null) {
    section = dom.Element.tag('section')..classes.add('footnotes');
    fragment.append(section);
  }
  var list = section.querySelector('ol');
  if (list == null) {
    list = dom.Element.tag('ol');
    section.append(list);
  }
  for (final entry in numbers.entries) {
    final old = entry.key,
        id = 'article-footnote-${entry.value}',
        note = definitions[entry.key]!;
    for (final a in fragment.querySelectorAll('a')) {
      if (a.attributes['href'] == '#$old') a.attributes['href'] = '#$id';
    }
    // Definitions in a nested callout are moved to the shared article footer.
    if (note.querySelector('.footnote-backref') == null) {
      for (final ref in references.where(
        (ref) => ref.attributes['href'] == '#$id',
      )) {
        note.append(
          dom.Element.tag('a')
            ..classes.add('footnote-backref')
            ..attributes['href'] = '#${ref.id}'
            ..text = '↩',
        );
      }
    }
    note.remove();
    note.id = id;
    list.append(note);
  }
}

void _sanitize(dom.DocumentFragment fragment) {
  const forbidden = {
    'script',
    'style',
    'object',
    'embed',
    'form',
    'button',
    'input',
    'select',
    'textarea',
    'meta',
    'link',
    'base',
    'svg',
    'math',
    'canvas',
    'noscript',
    'ts-ignore',
  };
  for (final element in fragment.querySelectorAll('*').toList()) {
    if (forbidden.contains(element.localName)) {
      element.remove();
      continue;
    }
    for (final key in element.attributes.keys.toList()) {
      final lower = '$key'.toLowerCase();
      if (lower.startsWith('on') ||
          [
            'srcdoc',
            'srcset',
            'style',
            'formaction',
            'download',
            'autoplay',
          ].contains(lower)) {
        element.attributes.remove(key);
      }
    }
    for (final key in ['href', 'src', 'poster']) {
      if (!element.attributes.containsKey(key)) continue;
      final safe = nativeArticleUrl(
        element.attributes[key]!,
        image: (element.localName == 'img' && key == 'src') || key == 'poster',
      );
      if (safe.isEmpty) {
        element.attributes.remove(key);
      } else {
        element.attributes[key] = safe;
      }
    }
    if (element.localName == 'iframe') {
      final src = element.attributes['src'] ?? '';
      if (Uri.tryParse(src)?.scheme != 'https') {
        element.remove();
        continue;
      }
      element.attributes['height'] =
          '${(int.tryParse(element.attributes['height'] ?? '') ?? 420).clamp(220, 900)}';
      element.attributes.remove('allow');
      element.attributes.remove('sandbox');
    }
    if (['img', 'video', 'audio', 'ts-media'].contains(element.localName) &&
        (element.attributes['src'] ?? '').isEmpty &&
        element.querySelector('source[src]') == null) {
      element.remove();
    }
  }
}

class _LineBreakSyntax extends md.InlineSyntax {
  _LineBreakSyntax() : super(r'\n');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty('br'));
    return true;
  }
}

class _MathInlineSyntax extends md.InlineSyntax {
  _MathInlineSyntax()
    : super(
        r'\$(?!\$)([^\s$](?:\\[^\n]|[^$\n])*?)\$(?!\d)',
        startCharacter: 36,
      );
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final body = match[1]!;
    if (body.trimRight() != body) {
      parser.addNode(md.Text(_escape(match[0]!)));
      return true;
    }
    parser.addNode(
      md.Element.text('ts-math', _escape(body))
        ..attributes['data-display'] = 'false',
    );
    return true;
  }
}

class _SpoilerSyntax extends md.InlineSyntax {
  _SpoilerSyntax()
    : super(r':spoiler\[((?:\\.|[^\]\\])*)\]', startCharacter: 58);
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('ts-spoiler', _escape(match[1]!)));
    return true;
  }
}

class _MarkSyntax extends md.InlineSyntax {
  _MarkSyntax()
    : super(
        r'==([^\n]+?)==(?:\{\.(primary|secondary|tertiary|error|tip)\})?',
        startCharacter: 61,
      );
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element('mark', parser.document.parseInline(match[1]!))
        ..attributes['class'] = 'markdown-mark-${match[2] ?? 'primary'}',
    );
    return true;
  }
}

class _ScriptSyntax extends md.InlineSyntax {
  _ScriptSyntax(this.tag, String marker)
    : super(
        '${RegExp.escape(marker)}([^${RegExp.escape(marker)}\\s]+)${RegExp.escape(marker)}',
      );
  final String tag;
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text(tag, _escape(match[1]!)));
    return true;
  }
}

class _InlineFootnoteSyntax extends md.InlineSyntax {
  _InlineFootnoteSyntax() : super(r'\^\[([^\]\n]+)\]', startCharacter: 94);
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element('ts-footnote', parser.document.parseInline(match[1]!)),
    );
    return true;
  }
}

class _AbbreviationSyntax extends md.InlineSyntax {
  _AbbreviationSyntax(this.values)
    : super(
        '(?<![a-zA-Z0-9_])(${values.keys.map(RegExp.escape).join('|')})(?![a-zA-Z0-9_])',
      );
  final Map<String, String> values;
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element.text('abbr', _escape(match[1]!))
        ..attributes['title'] = _escape(values[match[1]]!),
    );
    return true;
  }
}

class _AbbreviationDefinitionSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => RegExp(r'^\*\[([^\]\n]+)\]:\s*(.+)$');
  @override
  md.Node parse(md.BlockParser parser) {
    parser.advance();
    return md.Element.withTag('ts-ignore');
  }
}

class _MathBlockSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => RegExp(r'^\s{0,3}\$\$');
  @override
  bool canParse(md.BlockParser parser) {
    final first = parser.current.content.trim();
    if (first.length > 4 && first.endsWith(r'$$')) return true;
    if (first != r'$$') return false;
    for (var i = 1; parser.peek(i) != null; i++) {
      if (parser.peek(i)!.content.trim() == r'$$') return true;
    }
    return false;
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final first = parser.current.content.trim();
    parser.advance();
    var body = '';
    if (first.length > 4) {
      body = first.substring(2, first.length - 2);
    } else {
      final lines = <String>[];
      while (!parser.isDone && parser.current.content.trim() != r'$$') {
        lines.add(parser.current.content);
        parser.advance();
      }
      if (!parser.isDone) parser.advance();
      body = lines.join('\n');
    }
    return md.Element.text('ts-math', _escape(body))
      ..attributes['data-display'] = 'true';
  }
}

class _ContainerSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => RegExp(
    r'^\s{0,3}(:{3,})[ \t]*(note|info|tip|important|warning|caution|details|gallery)(?:\s+(.*)|\[(.*)\])?\s*$',
  );
  @override
  md.Node parse(md.BlockParser parser) {
    final match = pattern.firstMatch(parser.current.content)!;
    final type = match[2]!,
        rawTitle = match[3] ?? match[4] ?? nativeCalloutLabels[type] ?? '';
    final title = rawTitle.startsWith('[') && rawTitle.endsWith(']')
        ? rawTitle.substring(1, rawTitle.length - 1)
        : rawTitle;
    parser.advance();
    final lines = <md.Line>[];
    var depth = 1, fence = '';
    while (!parser.isDone) {
      final line = parser.current.content;
      final code = RegExp(r'^\s{0,3}(`{3,}|~{3,})').firstMatch(line)?.group(1);
      if (code != null) {
        if (fence.isEmpty) {
          fence = code[0];
        } else if (fence == code[0]) {
          fence = '';
        }
      }
      if (fence.isEmpty && pattern.hasMatch(line)) depth++;
      if (fence.isEmpty &&
          RegExp(r'^\s{0,3}:{3,}\s*$').hasMatch(line) &&
          --depth == 0) {
        parser.advance();
        break;
      }
      lines.add(parser.current);
      parser.advance();
    }
    final children = md.BlockParser(
      lines,
      parser.document,
    ).parseLines(parentSyntax: this);
    if (type == 'details') {
      return md.Element('details', [
        md.Element.text('summary', _escape(title)),
        ...children,
      ]);
    }
    if (type == 'gallery') {
      return md.Element('div', children)
        ..attributes['class'] = 'markdown-gallery';
    }
    return md.Element('div', [
      md.Element.text('p', _escape(title))
        ..attributes['class'] = 'markdown-callout-title',
      ...children,
    ])..attributes['class'] = 'markdown-callout markdown-callout-$type';
  }
}

class _MediaSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => RegExp(
    r'^\s{0,3}(?:::?(?:media|iframe|bilibili)\[|<iframe[\s>])',
    caseSensitive: false,
  );
  @override
  md.Node parse(md.BlockParser parser) {
    final source = parser.current.content.trim();
    parser.advance();
    final directive = RegExp(
      r'^::(media|iframe|bilibili)\[([^\]\n]*)\]\(([^\n]*)\)$',
      caseSensitive: false,
    ).firstMatch(source);
    if (directive == null) {
      if (!RegExp(
        r'^<iframe[\s\S]*</iframe>$',
        caseSensitive: false,
      ).hasMatch(source)) {
        return md.Element.text('p', _escape(source));
      }
      final iframe = html.parseFragment(source).querySelector('iframe');
      return md.Element.withTag('iframe')
        ..attributes.addAll({
          'src': _escape(iframe?.attributes['src'] ?? ''),
          'title': _escape(
            iframe?.attributes['title'] ??
                iframe?.attributes['aria-label'] ??
                'Embedded content',
          ),
          'height': iframe?.attributes['height'] ?? '420',
        });
    }
    final target = RegExp(r'''^(\S+)(?:\s+["']([^"']*)["'])?$''')
        .firstMatch(directive[3]!.trim());
    final url = target?[1] ?? directive[3]!,
        description = target?[2] ?? '',
        label = directive[2]!.isNotEmpty ? directive[2]! : description;
    final type = directive[1]!.toLowerCase();
    if (type == 'bilibili') {
      return md.Element.withTag('iframe')
        ..attributes.addAll({
          'src': _escape(nativeBilibiliUrl(url)),
          'title': _escape(label.isEmpty ? 'Bilibili video' : label),
          'height': '420',
        });
    }
    if (type == 'iframe') {
      return md.Element.withTag('iframe')
        ..attributes.addAll({
          'src': _escape(url),
          'title': _escape(label.isEmpty ? 'Embedded content' : label),
          'height': description,
        });
    }
    return md.Element.withTag('ts-media')
      ..attributes.addAll({
        'src': _escape(url),
        'title': _escape(label),
        'data-kind': directive[2]!.isNotEmpty ? description.toLowerCase() : '',
        'data-description': _escape(description),
      });
  }
}
