import '../../core/site_localization.dart';

import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

import '../../core/models.dart';
import '../room/room_controller.dart';
import '../room/room_style.dart';
import 'native_site_shell.dart';
import 'site_widgets.dart';

class WikiPage extends StatefulWidget {
  const WikiPage({
    super.key,
    required this.controller,
    this.path = '/wiki',
    required this.onGo,
    this.onTheme,
  });
  final RoomController controller;
  final String path;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  @override
  State<WikiPage> createState() => _WikiPageState();
}

class _WikiSpoiler extends StatefulWidget {
  const _WikiSpoiler({super.key, required this.child});
  final Widget child;
  @override
  State<_WikiSpoiler> createState() => _WikiSpoilerState();
}

class _WikiSpoilerState extends State<_WikiSpoiler> {
  bool _revealed = false;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => setState(() => _revealed = !_revealed),
    borderRadius: BorderRadius.circular(4),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: _revealed
            ? Theme.of(context).colorScheme.surfaceContainerHighest
            : Colors.black87,
        borderRadius: BorderRadius.circular(4),
      ),
      child: _revealed
          ? widget.child
          : const SiteText(
              '点击显示剧透',
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
    ),
  );
}

class _WikiPageState extends State<WikiPage> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _anchors = <String, GlobalKey>{};
  String _characterGroup = 'all', _musicGroup = 'all', _variant = '';
  Map<String, dynamic> get data => SiteArchive.wiki;
  String get site => widget.controller.settings.siteUrl;
  Map<String, dynamic>? get entry {
    final parts = Uri.parse(widget.path).pathSegments;
    return parts.length == 3
        ? SiteArchive.entry(
            parts[1] == 'characters' ? 'character' : 'term',
            parts[2],
          )
        : null;
  }

  bool get isEntry => Uri.parse(widget.path).pathSegments.length > 1;
  GlobalKey _key(String id) => _anchors.putIfAbsent(id, GlobalKey.new);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialAnchor());
  }

  @override
  void didUpdateWidget(covariant WikiPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _variant = '';
      _anchors.clear();
      if (_scroll.hasClients) _scroll.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) => _initialAnchor());
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _initialAnchor() {
    final fragment = Uri.parse(widget.path).fragment;
    if (fragment.isNotEmpty) _jump(fragment);
  }

  Future<void> _jump(String id) async {
    final target = _anchors[id]?.currentContext;
    if (target == null) return;
    await Scrollable.ensureVisible(
      target,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 240),
      alignment: .04,
    );
  }

  Future<bool> _link(String value) async {
    if (value.startsWith('#')) {
      await _jump(Uri.decodeComponent(value.substring(1)));
    } else {
      widget.onGo(value);
    }
    return true;
  }

  Widget _html(String html) => HtmlWidget(
    html,
    buildAsync: false,
    baseUrl: endpointUri(site),
    textStyle: const TextStyle(fontSize: 16, height: 1.85),
    onTapUrl: _link,
    customWidgetBuilder: (element) {
      if (element.localName == 'span' &&
          element.classes.contains('wiki-source-blackout')) {
        return _WikiSpoiler(
          key: ValueKey(element.innerHtml),
          child: _html(element.innerHtml),
        );
      }
      if (element.localName == 'img') {
        final value = element.attributes['src'] ?? '';
        if (SiteArchive.imageAsset(value) != null) {
          return nativeSiteImage(
            site,
            value,
            fit: BoxFit.contain,
            label: element.attributes['alt'] ?? '',
          );
        }
      }
      if (element.localName == 'details') {
        final summary = element.querySelector('summary');
        final title = summary?.text ?? '展开详细内容';
        final clone = element.clone(true)..querySelector('summary')?.remove();
        return ExpansionTile(
          title: Text(title),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: _html(clone.innerHtml),
            ),
          ],
        );
      }
      return null;
    },
  );
  Widget _section(
    String id,
    String title,
    Widget content, {
    String subtitle = '',
  }) => NativeSiteSection(
    key: _key(id),
    title: title,
    subtitle: subtitle,
    child: content,
  );
  Widget _prose(String id) => _html(textOf(mapOf(data['sectionProse']), id));
  List<List<dynamic>> _pairs(dynamic value) => value is List
      ? value.whereType<List>().map((item) => List<dynamic>.from(item)).toList()
      : [];
  Widget _facts(dynamic values, {bool html = false}) => Column(
    children: [
      for (final pair in _pairs(values))
        if (pair.length >= 2)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: MediaQuery.sizeOf(context).width < 430 ? 85 : 140,
                  child: Text(
                    '${pair[0]}',
                    style: TextStyle(color: RoomStyle(context).muted),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: html
                      ? _html('${pair[1]}')
                      : SelectableText(
                          '${pair[1]}',
                          style: const TextStyle(height: 1.6),
                        ),
                ),
              ],
            ),
          ),
    ],
  );
  Widget _chips(
    List<Map<String, dynamic>> groups,
    String selected,
    ValueChanged<String> update,
  ) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final group in groups)
        ChoiceChip(
          label: Text(textOf(group, 'label')),
          selected: group['id'] == selected,
          onSelected: (_) => setState(() => update(textOf(group, 'id'))),
        ),
    ],
  );
  Widget _grid(List<Widget> children, {double minWidth = 330}) => LayoutBuilder(
    builder: (context, box) {
      final columns = (box.maxWidth / minWidth).floor().clamp(1, 3);
      final width = (box.maxWidth - 14 * (columns - 1)) / columns;
      return Wrap(
        spacing: 14,
        runSpacing: 14,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
  @override
  Widget build(BuildContext context) => NativeSiteShell(
    controller: widget.controller,
    title: '超辉夜姬！Wiki',
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    scrollController: _scroll,
    floatingActionButton: FloatingActionButton.small(
      tooltip: '返回页面顶部',
      onPressed: () => _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      ),
      child: const Icon(Icons.arrow_upward),
    ),
    child: isEntry ? _entry() : _overview(),
  );
  Widget _overview() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            nativeSiteImage(
              site,
              '/assets/images/wiki/wiki-hero-original.webp',
              height: MediaQuery.sizeOf(context).width < 430 ? 350 : 280,
              width: double.infinity,
            ),
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xd9000018), Color(0x44000018)],
                  ),
                ),
              ),
            ),
            const Positioned.fill(
              child: Padding(
                padding: EdgeInsets.all(26),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SiteText(
                      'TSUKUYOMI ARCHIVE / FAN WIKI',
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                    SizedBox(height: 12),
                    SiteText(
                      '超辉夜姬！Wiki',
                      style: TextStyle(color: Colors.white, fontSize: 32),
                    ),
                    SiteText(
                      '超かぐや姫！ · Cosmic Princess Kaguya!',
                      style: TextStyle(color: Colors.white70),
                    ),
                    SizedBox(height: 14),
                    SiteText(
                      '非官方粉丝整理 · 原创动画电影 · 2026\n音乐 × 科幻 × 青春',
                      style: TextStyle(color: Colors.white, height: 1.7),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      NativeSiteSection(
        title: '词条目录',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in rowsOf(data['tocEntries']))
                  OutlinedButton(
                    onPressed: () => _jump(textOf(item, 'id')),
                    child: Text('${item['index']} ${item['label']}'),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            TextField(
              key: const Key('wiki-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: siteTranslate(context, '词条速查'),
                hintText: siteTranslate(context, '角色、歌曲、术语…'),
                prefixIcon: const Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 10),
            ..._searchResults(),
          ],
        ),
      ),
      nativeSiteFeedback(
        context,
        '非官方网站。正文依据公开资料整理，完整结局默认折叠；角色中文名以本站通行译法为准，日文原名为准。资料核验至 ${data['verifiedAt']}。',
      ),
      _section(
        'overview',
        '本作介绍',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _prose('overview'),
            _facts(data['infoRows']),
            const SizedBox(height: 16),
            for (final item in rowsOf(data['timeline']))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.timeline),
                title: Text('${item['date']} · ${item['label']}'),
                subtitle: Text(textOf(item, 'detail')),
              ),
          ],
        ),
      ),
      _section(
        'story',
        '故事简介',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _prose('story'),
            ExpansionTile(
              title: const SiteText('展开完整剧情与结局剧透'),
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SiteText('严重剧透警告：以下内容揭示角色身份、离别、时间循环与最终结局。'),
                ),
                for (final item in _pairs(data['spoilerSteps']))
                  ListTile(
                    title: Text('${item[0]}'),
                    subtitle: Text(
                      '${item[1]}',
                      style: const TextStyle(height: 1.75),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      _section(
        'characters',
        '登场人物',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _chips(
              rowsOf(data['characterGroups']),
              _characterGroup,
              (v) => _characterGroup = v,
            ),
            const SizedBox(height: 16),
            _grid([
              for (final item in rowsOf(data['characters']).where(
                (item) =>
                    _characterGroup == 'all' ||
                    (item['groups'] as List).contains(_characterGroup),
              ))
                InkWell(
                  key: _key(textOf(item, 'id')),
                  onTap: () => widget.onGo(
                    '/wiki/characters/${textOf(item, 'id').replaceFirst('entry-', '')}',
                  ),
                  child: SiteCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        nativeSiteImage(
                          site,
                          textOf(item, 'image'),
                          height: 160,
                          width: double.infinity,
                          fit: BoxFit.contain,
                          label: textOf(item, 'imageAlt'),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          textOf(item, 'name'),
                          style: const TextStyle(fontSize: 22),
                        ),
                        Text(
                          '${item['original']} · CV ${item['cv']}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          textOf(item, 'description'),
                          style: const TextStyle(height: 1.8),
                        ),
                        Wrap(
                          children: [
                            for (final id in item['relatedTerms'] as List)
                              TextButton(
                                onPressed: () => _termQuick('$id'),
                                child: Text(
                                  textOf(
                                    SiteArchive.entry('term', '$id') ?? {},
                                    'title',
                                    '$id',
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ]),
          ],
        ),
      ),
      _section(
        'world',
        '世界观与术语',
        Column(
          children: [
            _prose('world'),
            _grid([
              for (final item in rowsOf(
                data['terms'],
              ).where((item) => !['remember', 'reply'].contains(item['id'])))
                SiteCard(
                  key: _key(textOf(item, 'target')),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        textOf(item, 'label'),
                        style: const TextStyle(fontSize: 22),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        textOf(item, 'summary'),
                        style: const TextStyle(height: 1.8),
                      ),
                      const SizedBox(height: 10),
                      Text((item['aliases'] as List).join(' · ')),
                      TextButton(
                        onPressed: () =>
                            widget.onGo('/wiki/terms/${item['id']}'),
                        child: const SiteText('查看独立词条'),
                      ),
                    ],
                  ),
                ),
            ]),
          ],
        ),
      ),
      _section(
        'music',
        '相关音乐',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _prose('music'),
            _chips(
              rowsOf(data['musicGroups']),
              _musicGroup,
              (v) => _musicGroup = v,
            ),
            const SizedBox(height: 14),
            for (final song in rowsOf(data['music']).where(
              (song) => _musicGroup == 'all' || song['category'] == _musicGroup,
            ))
              Padding(
                key: _key(textOf(song, 'id')),
                padding: const EdgeInsets.only(bottom: 16),
                child: SiteCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${song['type']} · ${song['category']}',
                        style: TextStyle(
                          color: RoomStyle(context).muted,
                          fontSize: 11,
                        ),
                      ),
                      Text(
                        textOf(song, 'title'),
                        style: const TextStyle(fontSize: 21),
                      ),
                      _facts([
                        ['创作', song['creator']],
                        ['演唱', song['performer']],
                      ]),
                      Text(textOf(song, 'note')),
                    ],
                  ),
                ),
              ),
            OutlinedButton(
              onPressed: () =>
                  widget.onGo('https://www.cho-kaguyahime.com/music/'),
              child: const SiteText('官方 Music 页面'),
            ),
          ],
        ),
      ),
      _section(
        'staff-cast',
        '制作与配音',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SiteText('制作人员', style: TextStyle(fontSize: 20)),
            _facts(data['staff']),
            const SizedBox(height: 18),
            const SiteText('声优阵容', style: TextStyle(fontSize: 20)),
            _facts(data['cast']),
          ],
        ),
      ),
      _section(
        'release',
        '上映、票房与衍生作品',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _prose('release'),
            for (final row in rowsOf(data['boxOfficeMilestones']))
              ListTile(
                title: Text(textOf(row, 'day')),
                trailing: Text(textOf(row, 'gross')),
              ),
            _grid([
              for (final work in rowsOf(data['derivativeWorks']))
                SiteCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      nativeSiteImage(
                        site,
                        textOf(work, 'image'),
                        height: 220,
                        width: double.infinity,
                        fit: BoxFit.contain,
                        label: textOf(work, 'imageAlt'),
                      ),
                      const SizedBox(height: 14),
                      Text(textOf(work, 'type')),
                      Text(
                        textOf(work, 'title'),
                        style: const TextStyle(fontSize: 20),
                      ),
                      Text(
                        textOf(work, 'detail'),
                        style: const TextStyle(height: 1.7),
                      ),
                      _facts([
                        ['制作', work['credits']],
                        ['出版', work['publisher']],
                        ['发行', work['release']],
                        ['ISBN', work['isbn']],
                      ]),
                    ],
                  ),
                ),
            ]),
          ],
        ),
      ),
      _section(
        'references',
        '资料与版权说明',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _prose('references'),
            for (final reference in rowsOf(data['references']))
              ListTile(
                key: _key(textOf(reference, 'id')),
                contentPadding: EdgeInsets.zero,
                title: Text(textOf(reference, 'label')),
                subtitle: Text(
                  '${reference['scope']}（核验：${data['verifiedAt']}）',
                ),
                trailing: const Icon(Icons.open_in_new),
                onTap: () => widget.onGo(textOf(reference, 'url')),
              ),
          ],
        ),
      ),
      NativeSiteSection(
        title: '相关词条索引',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final group in rowsOf(data['navigationGroups'])) ...[
              Text(textOf(group, 'title')),
              Wrap(
                children: [
                  for (final link in rowsOf(group['links']))
                    TextButton(
                      onPressed: () => link['route'] == null
                          ? _jump(textOf(link, 'target'))
                          : widget.onGo(textOf(link, 'route')),
                      child: Text(textOf(link, 'label')),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    ],
  );
  List<Widget> _searchResults() {
    final query = _search.text.trim().toLowerCase();
    final all = rowsOf(data['quickEntries']);
    final results = query.isEmpty
        ? all.take(7)
        : all
              .where(
                (entry) => [
                  entry['label'],
                  entry['meta'],
                  ...(entry['keywords'] as List),
                ].join(' ').toLowerCase().contains(query),
              )
              .take(10);
    return [
      if (results.isEmpty) const SiteText('未找到匹配词条'),
      for (final item in results)
        ListTile(
          dense: true,
          title: Text(textOf(item, 'label')),
          subtitle: Text(textOf(item, 'meta')),
          trailing: const Icon(Icons.arrow_forward, size: 16),
          onTap: () => widget.onGo(textOf(item, 'route')),
        ),
    ];
  }

  void _termQuick(String slug) {
    final term = SiteArchive.entry('term', slug);
    if (term == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(textOf(term, 'title'), style: const TextStyle(fontSize: 26)),
              const SizedBox(height: 16),
              Text(
                textOf(term, 'summary'),
                style: const TextStyle(height: 1.8),
              ),
              const SizedBox(height: 14),
              Text((term['aliases'] as List).join(' · ')),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  widget.onGo(SiteArchive.entryPath(term));
                },
                child: const SiteText('打开独立词条'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _entry() {
    final item = entry;
    if (item == null) {
      return NativeSiteSection(
        title: '词条未找到',
        child: FilledButton(
          onPressed: () => widget.onGo('/wiki'),
          child: const SiteText('返回 Wiki 总览'),
        ),
      );
    }
    final variants = rowsOf(item['imageVariants']);
    final image =
        variants.where((v) => v['id'] == _variant).firstOrNull ??
        variants.firstOrNull ??
        item;
    final source = mapOf(item['source']);
    final sections = rowsOf(source['sections'])
        .where((s) => s['id'] != 'source-notes')
        .toList();
    final links = [
      if (source.isNotEmpty) {'id': 'source-profile', 'label': '基本资料（源条目）'},
      if (source.isNotEmpty)
        ...sections.map((s) => {'id': s['id'], 'label': s['title']})
      else
        ..._pairs(item['sections'])
            .asMap()
            .entries
            .map((s) => {'id': 'section-${s.key + 1}', 'label': s.value[0]}),
      if ((item['spoiler'] as List).isNotEmpty && source.isEmpty)
        {'id': 'spoiler', 'label': '剧透经历'},
      {'id': 'related', 'label': '关联词条'},
      {'id': 'sources', 'label': '资料来源'},
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => widget.onGo('/wiki'),
            icon: const Icon(Icons.arrow_back),
            label: const SiteText('返回 Wiki 总览'),
          ),
        ),
        NativeSiteSection(
          title: textOf(item, 'title'),
          subtitle: '${item['original']} · ${item['kindLabel']}',
          child: LayoutBuilder(
            builder: (context, box) {
              final copy = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    textOf(item, 'headline'),
                    style: const TextStyle(height: 1.8, fontSize: 17),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final tag in item['tags'] as List)
                        Chip(label: Text('$tag')),
                    ],
                  ),
                  _facts(item['facts']),
                ],
              );
              final visual = Column(
                children: [
                  if (variants.length > 1)
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final variant in variants)
                          ChoiceChip(
                            label: Text(textOf(variant, 'label')),
                            selected: image['id'] == variant['id'],
                            onSelected: (_) => setState(
                              () => _variant = textOf(variant, 'id'),
                            ),
                          ),
                      ],
                    ),
                  nativeSiteImage(
                    site,
                    textOf(image, 'image'),
                    height: 310,
                    width: double.infinity,
                    fit: BoxFit.contain,
                    label: textOf(image, 'imageAlt'),
                  ),
                  Text(
                    '图源：${mapOf(image['imageSource'])['title'] ?? ''}${mapOf(image['imageSource'])['page'] == null ? '' : ' 第 ${mapOf(image['imageSource'])['page']} 页'}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              );
              return box.maxWidth > 720
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: copy),
                        const SizedBox(width: 24),
                        Expanded(flex: 2, child: visual),
                      ],
                    )
                  : Column(
                      children: [visual, const SizedBox(height: 18), copy],
                    );
            },
          ),
        ),
        NativeSiteSection(
          title: '本页目录',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final link in links)
                OutlinedButton(
                  onPressed: () => _jump('${link['id']}'),
                  child: Text('${link['label']}'),
                ),
            ],
          ),
        ),
        if (source.isNotEmpty) ...[
          _section(
            'source-profile',
            '基本资料（源条目）',
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final row in rowsOf(source['profileRows']))
                  row['group'] == true
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            textOf(row, 'label'),
                            style: const TextStyle(fontSize: 20),
                          ),
                        )
                      : _facts([
                          [row['label'], row['valueHtml']],
                        ], html: true),
              ],
            ),
          ),
          for (final section in sections)
            _section(
              textOf(section, 'id'),
              textOf(section, 'title'),
              _html(textOf(section, 'html')),
            ),
        ] else ...[
          for (final row in _pairs(item['sections']).asMap().entries)
            _section(
              'section-${row.key + 1}',
              '${row.value[0]}',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final paragraph in row.value[1] as List)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: SelectableText(
                        '$paragraph',
                        style: const TextStyle(fontSize: 16, height: 1.85),
                      ),
                    ),
                ],
              ),
            ),
          if ((item['spoiler'] as List).isNotEmpty)
            _section(
              'spoiler',
              '剧透经历',
              ExpansionTile(
                title: const SiteText('展开身份与结局相关内容'),
                children: [
                  for (final paragraph in item['spoiler'] as List)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        '$paragraph',
                        style: const TextStyle(height: 1.85),
                      ),
                    ),
                ],
              ),
            ),
        ],
        _section(
          'related',
          '关联词条',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final related in rowsOf(item['related']))
                    OutlinedButton(
                      onPressed: () =>
                          widget.onGo(SiteArchive.entryPath(related)),
                      child: Text(textOf(related, 'label')),
                    ),
                ],
              ),
              for (final song in rowsOf(item['songs']))
                ListTile(
                  title: Text(textOf(song, 'title')),
                  subtitle: Text(textOf(song, 'creator')),
                  onTap: () => widget.onGo('/wiki#${song['id']}'),
                ),
            ],
          ),
        ),
        _section(
          'sources',
          '资料来源',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (mapOf(item['moegirl'])['url'] != null)
                OutlinedButton.icon(
                  onPressed: () =>
                      widget.onGo(textOf(mapOf(item['moegirl']), 'url')),
                  icon: const Icon(Icons.open_in_new),
                  label: const SiteText('跳转至萌娘百科'),
                ),
              for (final link in rowsOf(item['sourceLinks']))
                ListTile(
                  title: Text(textOf(link, 'label')),
                  subtitle: Text(textOf(link, 'url')),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => widget.onGo(textOf(link, 'url')),
                ),
              Text(
                '资料核验至 ${item['verifiedAt']}。正文与图片来源沿用原站档案。',
                style: TextStyle(color: RoomStyle(context).muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
