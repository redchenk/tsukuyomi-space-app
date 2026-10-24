import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/season_theme.dart';
import '../../core/site_localization.dart';
import '../room/room_style.dart';
import 'site_icon.dart';
import 'site_seasonal_surface.dart';

/// A single top-anchored surface shared by the mobile explore/account flows.
/// Insets are recomputed in the route so rotation and the IME cannot hide it.
Future<T?> showSiteMobilePanel<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: true,
  barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  barrierColor: const Color(0xff0c0c18).withValues(alpha: .30),
  transitionDuration: MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 180),
  transitionBuilder: (context, animation, _, child) => FadeTransition(
    opacity: animation,
    child: SlideTransition(
      position: Tween(
        begin: const Offset(0, -.015),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ),
  pageBuilder: (context, _, _) {
    final media = MediaQuery.of(context);
    final top = media.padding.top + 78;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        top,
        12,
        math.max(12, media.padding.bottom) + media.viewInsets.bottom,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: Material(
          type: MaterialType.transparency,
          child: SiteSeasonalSurface(
            radius: 24,
            menu: true,
            child: builder(context),
          ),
        ),
      ),
    );
  },
);

const _primary = [
  ('/hub', '大厅', 'home'),
  ('/room', '私人居所', 'moon'),
  ('/plaza', '月读广场', 'plaza'),
  ('/stage', '主舞台', 'book'),
];
const _groups = {
  '阅读与发现': [
    ('/wiki', '百科', 'crown'),
    ('/gallery', '图库', 'image'),
    ('/game', '辉夜快跑', 'gamepad'),
  ],
  '创作与游玩': [('/stage', '主舞台', 'book'), ('/pixel', '像素画', 'palette')],
  '更多空间': [
    ('/app/update', '应用更新', 'download'),
    ('/agent-os', 'Agent OS', 'bot'),
    ('/reality', '现实回廊', 'compass'),
    ('/friend-links', '友情链接', 'external'),
    ('/growth', '月契成长', 'sparkles'),
    ('/rss.xml', 'RSS 订阅', 'rss'),
  ],
};

class SiteMobileNavigation extends StatefulWidget {
  const SiteMobileNavigation({
    super.key,
    required this.onSelected,
    this.currentPath = '',
    this.username,
    this.administrator = false,
    this.account = false,
    this.actions = const {},
    this.onPreference,
  });
  final ValueChanged<String> onSelected;
  final ValueChanged<String>? onPreference;
  final String currentPath;
  final String? username;
  final bool administrator, account;
  final Map<String, String> actions;
  @override
  State<SiteMobileNavigation> createState() => _SiteMobileNavigationState();
}

class _SiteMobileNavigationState extends State<SiteMobileNavigation> {
  late bool account = widget.account;
  bool nativeTools = false;

  bool active(String path) {
    final current = Uri.tryParse(widget.currentPath)?.path;
    return current == path ||
        (path == '/room' && current?.startsWith('/room/') == true) ||
        (path == '/stage' &&
            (current?.startsWith('/articles/') == true ||
                current == '/editor')) ||
        (path == '/wiki' && current?.startsWith('/wiki/') == true);
  }

  Widget entry((String, String, String) item, {bool primary = false}) {
    final p = RoomStyle(context);
    final selected = active(item.$1);
    return Semantics(
      selected: selected,
      child: TextButton(
        key: ValueKey('mobile-nav-${primary ? 'primary-' : ''}${item.$1}'),
        style: TextButton.styleFrom(
          minimumSize: Size(0, primary ? 48 : 50),
          padding: EdgeInsets.symmetric(
            horizontal: primary ? 14 : 9,
            vertical: 9,
          ),
          foregroundColor: p.ink,
          backgroundColor: primary || selected
              ? p.palette.soft
              : Colors.transparent,
          side: BorderSide(
            color: selected
                ? p.accent
                : primary
                ? p.line
                : Colors.transparent,
          ),
          textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontSize: 13,
            height: 1.5,
            fontWeight: FontWeight.w500,
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: () => widget.onSelected(item.$1),
        child: Row(
          children: [
            SiteIcon(item.$3, color: p.accent),
            const SizedBox(width: 8),
            Expanded(child: SiteText(item.$2)),
          ],
        ),
      ),
    );
  }

  Widget grid(
    List<(String, String, String)> items, {
    bool primary = false,
  }) => LayoutBuilder(
    builder: (context, box) {
      // Keep the website's two columns. Large accessibility text may use one.
      final columns =
          box.maxWidth < 250 || MediaQuery.textScalerOf(context).scale(13) > 21
          ? 1
          : 2;
      return Wrap(
        spacing: 8,
        runSpacing: primary ? 8 : 5,
        children: [
          for (final item in items)
            SizedBox(
              width: (box.maxWidth - (columns - 1) * 8) / columns,
              child: entry(item, primary: primary),
            ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final p = RoomStyle(context);
    final authed = widget.username != null;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
      },
      child: FocusTraversalGroup(
        child: SingleChildScrollView(
          key: const Key('mobile-navigation-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          account ? 'YOUR SPACE' : 'EXPLORE',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 1.6,
                            color: p.muted,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SiteText(
                          account ? '账号菜单' : '还有一些值得逛逛的地方',
                          style: TextStyle(
                            fontSize: 18,
                            height: 1.5,
                            fontWeight: FontWeight.w600,
                            color: p.ink,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    autofocus: true,
                    tooltip: siteTranslate(context, '关闭导航'),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      side: BorderSide.none,
                    ),
                    onPressed: () => Navigator.pop(context),
                    icon: const SiteIcon('x'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (!account) ...[
                TextButton(
                  key: const Key('mobile-nav-search'),
                  style: TextButton.styleFrom(
                    backgroundColor: p.palette.soft,
                    foregroundColor: p.muted,
                    minimumSize: const Size(0, 44),
                    side: BorderSide(color: p.line),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                  ),
                  onPressed: () => widget.onSelected('search'),
                  child: Row(
                    children: [
                      const SiteIcon('search', size: 18),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: SiteText(
                          '搜索页面、文章…',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                grid(_primary, primary: true),
                const SizedBox(height: 20),
                for (final group in _groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 8),
                    child: SiteText(
                      group.key,
                      style: TextStyle(
                        fontSize: 11,
                        color: p.muted,
                        height: 1.5,
                      ),
                    ),
                  ),
                  grid(
                    group.value
                        .where(
                          (item) =>
                              (item.$1 != '/growth' || authed) &&
                              (item.$1 != '/app/update' ||
                                  widget.actions.containsKey('/app/update')),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                ],
              ] else ...[
                if (authed)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    child: Text(
                      widget.username!,
                      style: TextStyle(fontSize: 13, color: p.muted),
                    ),
                  ),
                for (final item
                    in authed
                        ? [
                            ('/user', '用户中心', 'user'),
                            ('/growth', '月契成长', 'sparkles'),
                            ('/notifications', '站内信', 'bell'),
                            ('/attachments', '附件库', 'image'),
                          ]
                        : [
                            ('/login', '登录', 'user'),
                            ('/register', '注册', 'badge'),
                          ])
                  entry(item),
                // Native-only tools remain available without crowding discovery.
                entry(('/room/settings', '房间设置', 'settings')),
                TextButton(
                  onPressed: () => setState(() => nativeTools = !nativeTools),
                  child: const SiteText('更多 App 功能'),
                ),
                if (nativeTools) ...[
                  TextButton.icon(
                    onPressed: () => widget.onPreference?.call('language:en'),
                    icon: const SiteIcon('languages'),
                    label: const Text('English'),
                  ),
                  entry(('/conversations', '会话与记忆', 'book')),
                  entry(('/live2d', 'Live2D 舞台', 'sparkles')),
                  entry(('/editor', '创作文章', 'book')),
                  entry(('/gallery/manage', '画廊管理', 'image')),
                  entry(('/payments', '支付中心', 'badge')),
                  if (widget.administrator) ...[
                    entry(('/admin', '内容管理', 'settings')),
                    entry(('/terminal', '管理终端', 'settings')),
                  ],
                ],
                if (authed) entry(('logout', '退出', 'arrowLeft')),
              ],
              Divider(height: 24, color: p.line),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: () => widget.onPreference?.call('theme'),
                    icon: SiteIcon(p.dark ? 'sun' : 'moon', size: 18),
                    label: SiteText(p.dark ? '浅色' : '深色'),
                  ),
                  TextButton.icon(
                    onPressed: () => widget.onPreference?.call(
                      SiteLocaleScope.maybeOf(context)?.language == 'zh'
                          ? 'language:ja'
                          : 'language:zh',
                    ),
                    icon: const SiteIcon('languages', size: 18),
                    label: Text(
                      SiteLocaleScope.maybeOf(context)?.language == 'zh'
                          ? '日本語'
                          : '中文',
                    ),
                  ),
                  if (!account)
                    TextButton.icon(
                      onPressed: () => setState(() => account = true),
                      icon: const SiteIcon('user', size: 18),
                      label: SiteText(authed ? '用户中心' : '登录'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const _SeasonChoices(),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeasonChoices extends StatelessWidget {
  const _SeasonChoices();
  @override
  Widget build(BuildContext context) {
    final season = SiteSeasonScope.maybeOf(context);
    if (season == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: season,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SiteText(
            '季节主题',
            style: TextStyle(fontSize: 11, color: RoomStyle(context).muted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in const {
                'auto': '自动',
                'spring': '春',
                'summer': '夏',
                'autumn': '秋',
                'winter': '冬',
              }.entries)
                ChoiceChip(
                  label: SiteText(entry.value),
                  selected: season.mode == entry.key,
                  onSelected: (_) async {
                    final saved = await season.select(entry.key);
                    if (!saved && context.mounted) {
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        const SnackBar(content: SiteText('主题已切换，暂时无法保存到本机')),
                      );
                    }
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}
