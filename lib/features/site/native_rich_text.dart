import '../../core/site_localization.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:highlight/highlight.dart' as syntax;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import 'native_article_document.dart';
import 'native_article_embed.dart';
import 'native_media_view.dart';

class NativeRichText extends StatefulWidget {
  const NativeRichText({
    super.key,
    required this.content,
    required this.format,
    required this.site,
    this.onNavigate,
    this.initialAnchor = '',
    this.headers,
    this.trackReading = true,
  });
  final String content, format, site, initialAnchor;
  final ValueChanged<String>? onNavigate;
  final Map<String, String>? headers;
  final bool trackReading;
  @override
  State<NativeRichText> createState() => _NativeRichTextState();
}

class _NativeRichTextState extends State<NativeRichText> {
  late NativeArticleDocument document;
  final anchors = <String, GlobalKey>{};
  final openedDetails = <String>{};
  final detailAncestors = <String, List<String>>{};
  ScrollPosition? position;
  final readingProgress = ValueNotifier(0.0);
  final activeHeading = ValueNotifier('');
  bool measurementScheduled = false;
  int revision = 0;
  @override
  void initState() {
    super.initState();
    parse();
  }

  void parse() {
    revision++;
    document = parseNativeArticle(widget.content, widget.format);
    anchors.clear();
    openedDetails.clear();
    detailAncestors.clear();
    final fragment = html.parseFragment(document.html);
    var index = 0;
    for (final details in fragment.querySelectorAll('details')) {
      details.attributes['data-native-details'] = 'details-${++index}';
      if (details.attributes.containsKey('open')) {
        openedDetails.add('details-$index');
      }
    }
    for (final element in fragment.querySelectorAll('[id]')) {
      anchors[element.id] = GlobalKey(debugLabel: element.id);
      final parents = <String>[];
      dom.Element? parent = element.parent;
      while (parent != null) {
        if (parent.localName == 'details') {
          parents.add(parent.attributes['data-native-details']!);
        }
        parent = parent.parent;
      }
      detailAncestors[element.id] = parents;
    }
    document = NativeArticleDocument(
      fragment.outerHtml,
      document.headings,
      document.anchorIds,
    );
    readingProgress.value = 0;
    activeHeading.value = document.headings.firstOrNull?.id ?? '';
    if (widget.initialAnchor.isNotEmpty) scheduleAnchor(widget.initialAnchor);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = widget.trackReading
        ? Scrollable.maybeOf(context)?.position
        : null;
    if (next != position) {
      position?.removeListener(scheduleMeasurement);
      position = next;
      position?.addListener(scheduleMeasurement);
    }
  }

  @override
  void didUpdateWidget(covariant NativeRichText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackReading != widget.trackReading) {
      position?.removeListener(scheduleMeasurement);
      position = widget.trackReading
          ? Scrollable.maybeOf(context)?.position
          : null;
      position?.addListener(scheduleMeasurement);
    }
    if (oldWidget.content != widget.content ||
        oldWidget.format != widget.format ||
        oldWidget.site != widget.site ||
        !mapEquals(oldWidget.headers, widget.headers)) {
      parse();
    } else if (oldWidget.initialAnchor != widget.initialAnchor &&
        widget.initialAnchor.isNotEmpty) {
      scheduleAnchor(widget.initialAnchor);
    }
  }

  @override
  void dispose() {
    revision++;
    position?.removeListener(scheduleMeasurement);
    readingProgress.dispose();
    activeHeading.dispose();
    super.dispose();
  }

  void scheduleAnchor(String id) {
    final request = revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && revision == request) jump(id);
    });
  }

  Future<bool> jump(String value) async {
    var id = value.startsWith('#') ? value.substring(1) : value;
    try {
      id = Uri.decodeComponent(id);
    } on FormatException {
      return false;
    }
    if (!anchors.containsKey(id)) return false;
    final request = revision;
    final parents = detailAncestors[id] ?? [];
    if (!openedDetails.containsAll(parents)) {
      setState(() => openedDetails.addAll(parents));
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || request != revision) return false;
    final target = anchors[id]?.currentContext;
    if (target == null || !target.mounted) return false;
    if (document.headings.any((heading) => heading.id == id)) {
      activeHeading.value = id;
    }
    await Scrollable.ensureVisible(
      target,
      alignment: .05,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 250),
    );
    return true;
  }

  void scheduleMeasurement() {
    if (measurementScheduled) return;
    measurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      measurementScheduled = false;
      if (mounted) measure();
    });
  }

  void measure() {
    if (!mounted) return;
    final body = context.findRenderObject();
    if (body is! RenderBox || !body.hasSize) return;
    final top = body.localToGlobal(Offset.zero).dy;
    final height = MediaQuery.sizeOf(context).height;
    final distance = body.size.height - height + 160;
    final nextProgress = distance > 0
        ? ((112 - top) / distance).clamp(0.0, 1.0)
        : (top + body.size.height <= height ? 1.0 : 0.0);
    var nextHeading = document.headings.firstOrNull?.id ?? '';
    for (final heading in document.headings) {
      final box = anchors[heading.id]?.currentContext?.findRenderObject();
      if (box is RenderBox &&
          box.hasSize &&
          box.localToGlobal(Offset.zero).dy <= 150) {
        nextHeading = heading.id;
      }
    }
    if ((nextProgress - readingProgress.value).abs() > .005) {
      readingProgress.value = nextProgress;
    }
    if (nextHeading != activeHeading.value) activeHeading.value = nextHeading;
  }

  Uri? target(String value, {bool image = false}) {
    final safe = nativeArticleUrl(value, image: image);
    if (safe.isEmpty) return null;
    return endpointUri(widget.site).resolve(safe);
  }

  Map<String, String>? imageHeaders(Uri uri) =>
      uri.origin == endpointUri(widget.site).origin ? widget.headers : null;
  Future<bool> open(String value) async {
    if (value.startsWith('#') && await jump(value)) return true;
    final uri = target(value);
    if (uri == null || !['https', 'http'].contains(uri.scheme)) return false;
    if (widget.onNavigate != null) {
      widget.onNavigate!(value);
      return true;
    }
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget image(dom.Element element) {
    final uri = target(element.attributes['src'] ?? '', image: true);
    if (uri == null) return Text(element.attributes['alt'] ?? '');
    final alt = element.attributes['alt'] ?? '图片';
    Uint8List? bytes;
    if (uri.scheme == 'data') {
      try {
        bytes = uri.data?.contentAsBytes();
      } on FormatException {
        return Text(alt);
      }
    }
    final decodeWidth =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .ceil()
            .clamp(1, 1600);
    final ImageProvider<Object> provider = bytes != null
        ? MemoryImage(bytes)
        : NetworkImage('$uri', headers: imageHeaders(uri));
    Widget picture({bool expand = false}) => Image(
      image: expand
          ? provider
          : ResizeImage(
              provider,
              width: decodeWidth,
              policy: ResizeImagePolicy.fit,
            ),
      fit: BoxFit.contain,
      semanticLabel: alt,
      errorBuilder: (_, _, _) =>
          Text('$alt（${siteTranslate(context, '图片暂不可用')}）'),
    );
    return Semantics(
      button: true,
      label: '查看$alt',
      child: InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => Dialog(
            child: Stack(
              children: [
                Positioned.fill(
                  child: InteractiveViewer(
                    minScale: .5,
                    maxScale: 8,
                    child: Center(child: picture(expand: true)),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: siteTranslate(context, '关闭图片'),
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 650),
          child: picture(),
        ),
      ),
    );
  }

  Widget htmlWidget(
    String source, {
    bool table = true,
    String ignoredAnchor = '',
  }) => HtmlWidget(
    source,
    rebuildTriggers: [revision, openedDetails.join(',')],
    baseUrl: endpointUri(widget.site),
    textStyle: TextStyle(
      fontSize: 17,
      height: 1.85,
      color: Theme.of(context).colorScheme.onSurface,
    ),
    onTapUrl: open,
    customStylesBuilder: (element) {
      final classes = element.classes;
      if (element.localName == 'ts-math' &&
          element.attributes['data-display'] == 'true') {
        return {'display': 'block'};
      }
      if (element.localName == 'ts-media' || element.localName == 'iframe') {
        return {'display': 'block'};
      }
      if (element.localName == 'mark') {
        final variant = classes.firstOrNull ?? '';
        final scheme = Theme.of(context).colorScheme;
        final color = variant.endsWith('error')
            ? scheme.errorContainer
            : variant.endsWith('secondary')
            ? scheme.secondaryContainer
            : variant.endsWith('tertiary')
            ? scheme.tertiaryContainer
            : variant.endsWith('tip')
            ? const Color(0x3344aa88)
            : scheme.primaryContainer;
        return {
          'background-color':
              '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
        };
      }
      if (classes.contains('markdown-callout-title') ||
          classes.contains('markdown-alert-title')) {
        return {'font-weight': 'bold'};
      }
      return null;
    },
    customWidgetBuilder: (element) {
      final tag = element.localName;
      if (tag == 'img') return image(element);
      if (tag == 'pre') {
        final code = element.querySelector('code');
        final language = (code?.attributes['class'] ?? '')
            .replaceFirst('language-', '')
            .split(' ')
            .first;
        final title =
            RegExp(r'title="([^"\n]*)"')
                .firstMatch(element.attributes['data-metadata'] ?? '')
                ?.group(1) ??
            language;
        return NativeCodeBlock(
          code: code?.text ?? element.text,
          language: language,
          title: title,
        );
      }
      if (tag == 'ts-math') {
        final source = element.text;
        if (source.length > 4000) {
          return SelectableText(
            source,
            style: const TextStyle(fontFamily: 'monospace'),
          );
        }
        final display = element.attributes['data-display'] == 'true';
        final formula = Math.tex(
          source,
          settings: const TexParserSettings(
            maxExpand: 300,
            strict: Strict.ignore,
          ),
          mathStyle: display ? MathStyle.display : MathStyle.text,
          textStyle: TextStyle(
            fontSize: display ? 20 : 17,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          onErrorFallback: (_) => SelectableText(
            source,
            style: TextStyle(
              fontFamily: 'monospace',
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        );
        return display
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: formula,
                ),
              )
            : formula;
      }
      if (tag == 'ts-spoiler') return NativeSpoiler(text: element.text);
      if (tag == 'abbr') {
        return Tooltip(
          message: element.attributes['title'] ?? '',
          child: Text(
            element.text,
            style: const TextStyle(
              decoration: TextDecoration.underline,
              decorationStyle: TextDecorationStyle.dotted,
            ),
          ),
        );
      }
      if (tag == 'iframe') {
        return NativeArticleEmbed(
          url: element.attributes['src']!,
          title: element.attributes['title'] ?? 'Embedded content',
          height: double.parse(element.attributes['height']!),
          onOpen: () => open(element.attributes['src']!),
        );
      }
      if (['video', 'audio', 'ts-media'].contains(tag)) {
        final value =
            element.attributes['src'] ??
            element.querySelector('source')?.attributes['src'] ??
            '';
        final uri = target(value);
        if (uri == null) return const SizedBox();
        final kind = tag == 'ts-media'
            ? element.attributes['data-kind'] ?? ''
            : tag;
        final title = element.attributes['title'] ?? uri.host;
        if (kind == 'video' || kind == 'audio') {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                NativeMediaView(
                  url: '$uri',
                  headers: imageHeaders(uri),
                  poster: target(
                    element.attributes['poster'] ?? '',
                    image: true,
                  )?.toString(),
                ),
                Text(title.isEmpty ? uri.host : title),
              ],
            ),
          );
        }
        return Card(
          child: ListTile(
            leading: const Icon(Icons.attach_file),
            title: Text(title.isEmpty ? uri.host : title),
            subtitle: Text(element.attributes['data-description'] ?? uri.host),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => open(value),
          ),
        );
      }
      if (tag == 'details') {
        final id = element.attributes['data-native-details']!;
        final clone = element.clone(true)..querySelector('summary')?.remove();
        return Card(
          child: ExpansionTile(
            key: ValueKey('$id:${openedDetails.contains(id)}'),
            initiallyExpanded: openedDetails.contains(id),
            maintainState: true,
            title: Text(element.querySelector('summary')?.text ?? 'Details'),
            onExpansionChanged: (expanded) => setState(() {
              if (expanded) {
                openedDetails.add(id);
              } else {
                openedDetails.remove(id);
              }
            }),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: htmlWidget(clone.innerHtml),
              ),
            ],
          ),
        );
      }
      if (element.classes.contains('markdown-callout')) {
        final type = element.classes.firstWhere(
          (value) => value.startsWith('markdown-callout-'),
          orElse: () => 'markdown-callout-note',
        );
        final color = type.endsWith('warning') || type.endsWith('caution')
            ? Theme.of(context).colorScheme.error
            : type.endsWith('tip')
            ? const Color(0xff36876e)
            : Theme.of(context).colorScheme.primary;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .08),
            border: Border(left: BorderSide(width: 4, color: color)),
          ),
          child: htmlWidget(element.innerHtml),
        );
      }
      if (element.classes.contains('markdown-gallery')) {
        return LayoutBuilder(
          builder: (context, constraints) => Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final child in element.children)
                SizedBox(
                  width: constraints.maxWidth > 540
                      ? (constraints.maxWidth - 12) / 2
                      : constraints.maxWidth,
                  child: htmlWidget(child.outerHtml),
                ),
            ],
          ),
        );
      }
      if (tag == 'table' && table) {
        return LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: constraints.maxWidth,
                maxWidth:
                    (element
                                    .querySelectorAll('tr')
                                    .firstOrNull
                                    ?.children
                                    .length ??
                                1) *
                            180.0 <
                        constraints.maxWidth
                    ? constraints.maxWidth
                    : (element
                                  .querySelectorAll('tr')
                                  .firstOrNull
                                  ?.children
                                  .length ??
                              1) *
                          180.0,
              ),
              child: htmlWidget(element.outerHtml, table: false),
            ),
          ),
        );
      }
      if (tag == 'sup' && element.classes.contains('footnote-ref')) {
        final link = element.querySelector('a');
        if (link == null) return null;
        return InkWell(
          key: anchors[link.id],
          onTap: () => open(link.attributes['href'] ?? ''),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Text(
              '[${link.text}]',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        );
      }
      if (tag == 'a' && element.classes.contains('footnote-backref')) {
        return Tooltip(
          message: '返回引用',
          child: InkWell(
            onTap: () => open(element.attributes['href'] ?? ''),
            child: Text(
              element.text,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ),
        );
      }
      if (element.id.isNotEmpty &&
          element.id != ignoredAnchor &&
          !['a', 'span'].contains(tag)) {
        return Container(
          key: anchors[element.id],
          child: htmlWidget(
            element.outerHtml,
            table: table,
            ignoredAnchor: element.id,
          ),
        );
      }
      return null;
    },
  );
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.trackReading && document.headings.length > 1)
        Card(
          child: ExpansionTile(
            initiallyExpanded: MediaQuery.sizeOf(context).width >= 1100,
            title: const SiteText('文章目录'),
            children: [
              ValueListenableBuilder(
                valueListenable: readingProgress,
                builder: (context, value, _) =>
                    LinearProgressIndicator(value: value),
              ),
              ValueListenableBuilder(
                valueListenable: activeHeading,
                builder: (context, value, _) => Column(
                  children: [
                    for (final heading in document.headings)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.only(
                          left: heading.level == 3 ? 32 : 16,
                          right: 16,
                        ),
                        selected: heading.id == value,
                        title: Text(heading.text),
                        onTap: () => jump(heading.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      RepaintBoundary(child: SelectionArea(child: htmlWidget(document.html))),
    ],
  );
}

class NativeSpoiler extends StatefulWidget {
  const NativeSpoiler({super.key, required this.text});
  final String text;
  @override
  State<NativeSpoiler> createState() => _NativeSpoilerState();
}

class _NativeSpoilerState extends State<NativeSpoiler> {
  bool revealed = false;
  @override
  Widget build(BuildContext context) => Semantics(
    button: !revealed,
    label: revealed ? widget.text : '点击显示剧透内容',
    child: InkWell(
      onTap: revealed ? null : () => setState(() => revealed = true),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          child: revealed ? Text(widget.text) : const SiteText('剧透内容（点击显示）'),
        ),
      ),
    ),
  );
}

class NativeCodeBlock extends StatefulWidget {
  const NativeCodeBlock({
    super.key,
    required this.code,
    this.language = '',
    this.title = '',
  });
  final String code, language, title;
  @override
  State<NativeCodeBlock> createState() => _NativeCodeBlockState();
}

class _NativeCodeBlockState extends State<NativeCodeBlock> {
  bool copied = false;
  List<InlineSpan>? spans;
  bool? dark;
  static const languages = {
    'javascript',
    'typescript',
    'python',
    'json',
    'bash',
    'css',
    'xml',
    'sql',
    'java',
    'cpp',
    'yaml',
    'markdown',
    'diff',
  };
  static const aliases = {
    'js': 'javascript',
    'ts': 'typescript',
    'py': 'python',
    'sh': 'bash',
    'shell': 'bash',
    'html': 'xml',
    'c++': 'cpp',
    'yml': 'yaml',
    'md': 'markdown',
  };
  @override
  void didUpdateWidget(covariant NativeCodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code ||
        oldWidget.language != widget.language) {
      spans = null;
      copied = false;
    }
  }

  List<InlineSpan> highlight(bool isDark) {
    final language =
        aliases[widget.language.toLowerCase()] ?? widget.language.toLowerCase();
    if (widget.code.length > 20000 || !languages.contains(language)) {
      return [TextSpan(text: widget.code)];
    }
    final colors = <String, Color>{
      'keyword': isDark ? const Color(0xffc792ea) : const Color(0xff7c3d9f),
      'string': isDark ? const Color(0xffc3e88d) : const Color(0xff277842),
      'number': isDark ? const Color(0xfff78c6c) : const Color(0xffaa521b),
      'comment': isDark ? const Color(0xff8292a2) : const Color(0xff617481),
      'title': isDark ? const Color(0xff82aaff) : const Color(0xff2866aa),
      'built_in': isDark ? const Color(0xffffcb6b) : const Color(0xff986b1f),
      'literal': isDark ? const Color(0xffffcb6b) : const Color(0xff986b1f),
      'attr': isDark ? const Color(0xff82aaff) : const Color(0xff2866aa),
      'addition': const Color(0xff36876e),
      'deletion': const Color(0xffc04d59),
    };
    TextSpan span(syntax.Node node) => TextSpan(
      text: node.value,
      style: TextStyle(color: colors[node.className]),
      children: node.children?.map(span).toList(),
    );
    try {
      return syntax.highlight
          .parse(widget.code, language: language)
          .nodes!
          .map(span)
          .toList();
    } catch (_) {
      return [TextSpan(text: widget.code)];
    }
  }

  Future<void> copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.code));
      if (mounted) setState(() => copied = true);
    } catch (_) {
      if (mounted) setState(() => copied = false);
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: SiteText('复制失败，请重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (spans == null || dark != isDark) {
      spans = highlight(isDark);
      dark = isDark;
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    widget.title.isEmpty
                        ? widget.language.isEmpty
                              ? 'text'
                              : widget.language
                        : widget.title,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: copy,
                icon: Icon(copied ? Icons.check : Icons.copy, size: 16),
                label: SiteText(copied ? '已复制' : '复制代码'),
              ),
            ],
          ),
          const Divider(height: 1),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(16),
            child: SelectableText.rich(
              TextSpan(children: spans),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                height: 1.55,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
