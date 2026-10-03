import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html;
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../../core/site_localization.dart';
import '../room/room_style.dart';
import '../room/room_controller.dart';
import '../room/room_music.dart';
import 'native_rich_text.dart';
import 'site_search.dart';
import 'site_chrome.dart';
import 'site_explore_menu.dart';

const siteDestinations = <String, String>{
  '/hub': '中枢大厅',
  '/room': '私人居所',
  '/stage': '主舞台',
  '/plaza': '月读广场',
  '/conversations': '会话与记忆',
  '/growth': '月契成长',
  '/user': '个人中心',
  '/notifications': '站内信',
  '/wiki': '月读百科',
  '/gallery': '幻想画廊',
  '/pixel': '像素工坊',
  '/game': '辉夜跑酷',
  '/friend-links': '友情链接',
  '/reality': '现实连接',
  '/editor': '创作文章',
  '/attachments': '附件管理',
};
String siteDestinationLabel(BuildContext context, String path) {
  const keys = {
    '/hub': 'hubTitle',
    '/room': 'room',
    '/stage': 'stage',
    '/plaza': 'plaza',
    '/user': 'ucTitle',
    '/notifications': 'notifications',
    '/wiki': 'wiki',
    '/gallery': 'gallery',
    '/pixel': 'arena',
    '/game': 'game',
    '/reality': 'reality',
    '/editor': 'editorTitle',
    '/attachments': 'attachments',
    '/agent-os': 'agentOs',
  };
  final key = keys[path];
  return key == null
      ? siteTranslate(context, siteDestinations[path] ?? path)
      : siteTr(context, key);
}

String textOf(Map value, String key, [String fallback = '']) =>
    '${value[key] ?? fallback}';
Map<String, dynamic> mapOf(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Map<String, dynamic>> rowsOf(dynamic value) =>
    value is List ? value.whereType<Map>().map(mapOf).toList() : [];
String plainText(String source) => html.parseFragment(source).text ?? '';
String dateText(dynamic value) {
  final date = value is num
      ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
      : DateTime.tryParse('$value');
  if (date == null) return '';
  final local = date.toLocal();
  return '${local.year}/${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')}';
}

Future<bool> openSiteLink(String base, String value) async {
  final url = endpointUri(base).resolve(value);
  if (!['https', 'http'].contains(url.scheme) || url.userInfo.isNotEmpty) {
    return false;
  }
  return launchUrl(url, mode: LaunchMode.externalApplication);
}

class SiteCard extends StatelessWidget {
  const SiteCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(22),
  });
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Material(
    color: RoomStyle(context).surface.withValues(alpha: .95),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: RoomStyle(context).line),
    ),
    child: Padding(padding: padding, child: child),
  );
}

/// Editorial page heading shared by the website's content surfaces.
class SitePageHero extends StatelessWidget {
  const SitePageHero({
    super.key,
    required this.title,
    this.kicker = '',
    this.subtitle = '',
    this.actions,
    this.background,
    this.translate = true,
  });
  final String title, kicker, subtitle;
  final Widget? actions;
  final Widget? background;
  final bool translate;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: SiteCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            if (background != null) Positioned.fill(child: background!),
            if (background != null)
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xef10111f), Color(0xa610111f)],
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (kicker.isNotEmpty)
                    SiteText(
                      kicker,
                      style: TextStyle(
                        fontSize: 11,
                        color: background == null
                            ? RoomStyle(context).accent
                            : Colors.white70,
                        letterSpacing: 1,
                      ),
                    ),
                  const SizedBox(height: 8),
                  SiteText(
                    title,
                    translate: translate,
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w600,
                      color: background == null ? null : Colors.white,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    SiteText(
                      subtitle,
                      translate: translate,
                      style: TextStyle(
                        height: 1.7,
                        color: background == null
                            ? RoomStyle(context).muted
                            : Colors.white70,
                      ),
                    ),
                  ],
                  if (actions != null) ...[
                    const SizedBox(height: 20),
                    actions!,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class SiteResponsiveGrid extends StatelessWidget {
  const SiteResponsiveGrid({
    super.key,
    required this.children,
    this.minWidth = 280,
    this.maxColumns = 3,
    this.spacing = 16,
  });
  final List<Widget> children;
  final double minWidth, spacing;
  final int maxColumns;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final columns = (box.maxWidth / (minWidth * scale)).floor().clamp(
        1,
        maxColumns,
      );
      final width = (box.maxWidth - spacing * (columns - 1)) / columns;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

/// The same fixed scenery and editorial tint used by the website and Room.
class SiteBackground extends StatelessWidget {
  const SiteBackground({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Image.asset(
        'assets/images/moonlit-lake.png',
        fit: BoxFit.cover,
        cacheWidth:
            (MediaQuery.sizeOf(context).width *
                    MediaQuery.devicePixelRatioOf(context))
                .ceil()
                .clamp(1, 2560),
        excludeFromSemantics: true,
      ),
      ColoredBox(color: RoomStyle(context).background.withValues(alpha: .80)),
      child,
    ],
  );
}

class SiteAvatar extends StatefulWidget {
  const SiteAvatar({
    super.key,
    required this.value,
    required this.name,
    required this.site,
    this.size = 40,
    this.headers,
  });
  final String value, name, site;
  final double size;
  final Map<String, String>? headers;
  @override
  State<SiteAvatar> createState() => _SiteAvatarState();
}

class _SiteAvatarState extends State<SiteAvatar> {
  String? decodedValue;
  Uint8List? decodedBytes;
  @override
  Widget build(BuildContext context) {
    final value = widget.value, name = widget.name, site = widget.site;
    final size = widget.size, headers = widget.headers;
    final fallback = Center(
      child: Text(
        name.isEmpty ? '月' : name.characters.first,
        style: TextStyle(fontSize: size * .4, color: Colors.white),
      ),
    );
    Widget picture = fallback;
    final decodeSize = (size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 512);
    try {
      if (value.startsWith('data:image/') && value.contains(';base64,')) {
        if (decodedValue != value) {
          decodedBytes = base64Decode(value.split(';base64,').last);
          decodedValue = value;
        }
        picture = Image(
          image: ResizeImage(
            MemoryImage(decodedBytes!),
            width: decodeSize,
            height: decodeSize,
            policy: ResizeImagePolicy.fit,
          ),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
        );
      } else if (value.isNotEmpty) {
        final uri = endpointUri(site).resolve(value);
        if (['https', 'http'].contains(uri.scheme)) {
          picture = Image(
            image: ResizeImage(
              NetworkImage(
                '$uri',
                headers: uri.origin == endpointUri(site).origin
                    ? headers
                    : null,
              ),
              width: decodeSize,
              height: decodeSize,
              policy: ResizeImagePolicy.fit,
            ),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback,
          );
        }
      }
    } catch (_) {
      picture = fallback;
    }
    return ClipOval(
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xffec4899), Color(0xff8b5cf6)],
          ),
        ),
        child: picture,
      ),
    );
  }
}

class SiteHeader extends StatelessWidget {
  const SiteHeader({
    super.key,
    required this.title,
    required this.onGo,
    required this.onLogin,
    this.username,
    this.onTheme,
    this.role,
  });
  final String title;
  final String? username;
  final String? role;
  final ValueChanged<String> onGo;
  final VoidCallback onLogin;
  final VoidCallback? onTheme;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final style = RoomStyle(context);
      final compact =
          box.maxWidth <
          1160 * (MediaQuery.textScalerOf(context).scale(14) / 14);
      final path = ModalRoute.of(context)?.settings.name ?? '';
      final controller = SiteControllerScope.maybeOf(context);
      final music = SiteMusicScope.maybeOf(context);
      final administrator =
          username != null && (role == 'admin' || role == 'super_admin');
      final explore = SiteExploreMenu(
        currentPath: path,
        administrator: administrator,
        showLabel: !compact,
        actions: {
          'search': '搜索月读空间',
          'music': '全站音乐',
          'theme': '切换主题',
          'language:zh': '中文',
          'language:ja': '日本語',
          'language:en': 'English',
        },
        onSelected: (value) {
          if (value == 'theme') {
            onTheme?.call();
          } else if (value == 'search') {
            if (controller != null) showSiteSearch(context, controller, onGo);
          } else if (value == 'music') {
            if (music != null) showRoomMusic(context, music);
          } else if (value.startsWith('language:')) {
            SiteLocaleScope.maybeOf(context)?.setLanguage(value.substring(9));
          } else {
            onGo(value);
          }
        },
      );
      return SiteCard(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 20,
          vertical: compact ? 6 : 10,
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => onGo('/hub'),
                child: Row(
                  children: [
                    if (!compact) ...[
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: style.soft,
                          border: Border.all(color: style.line),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          CupertinoIcons.moon_circle,
                          color: style.accent,
                          size: 25,
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SiteText(
                            '月读空间',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: RoomStyle.serif,
                              fontSize: 21,
                              height: 1.2,
                              letterSpacing: 2,
                            ),
                          ),
                          SiteText(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              height: 1.4,
                              color: style.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!compact) ...[
              for (final route in ['/hub', '/stage', '/plaza', '/wiki'])
                TextButton(
                  onPressed: () => onGo(route),
                  style: TextButton.styleFrom(
                    foregroundColor: path == route ? style.accent : style.muted,
                    backgroundColor: path == route ? style.soft : null,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: SiteText(
                    const {
                      '/hub': '中枢',
                      '/stage': '舞台',
                      '/plaza': '广场',
                      '/wiki': '百科',
                    }[route]!,
                  ),
                ),
              explore,
              const SizedBox(width: 12),
              if (controller != null)
                OutlinedButton.icon(
                  onPressed: () => showSiteSearch(context, controller, onGo),
                  icon: const Icon(Icons.search, size: 19),
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SiteText('搜索', style: const TextStyle(fontSize: 13)),
                      const SizedBox(width: 12),
                      Text(
                        '⌘ K',
                        style: TextStyle(fontSize: 10, color: style.muted),
                      ),
                    ],
                  ),
                ),
              const SizedBox(width: 8),
            ],
            if (username != null &&
                SiteChromeScope.maybeOf(context)?.authed == true)
              IconButton(
                onPressed: () => onGo('/notifications'),
                tooltip: siteTr(context, 'notifications'),
                icon: const SiteNotificationBadge(),
              ),
            if (!compact)
              IconButton(
                onPressed: onTheme,
                icon: Icon(
                  Theme.of(context).brightness == Brightness.dark
                      ? CupertinoIcons.sun_max
                      : CupertinoIcons.moon,
                ),
                tooltip: siteTranslate(
                  context,
                  Theme.of(context).brightness == Brightness.dark
                      ? '切换浅色主题'
                      : '切换深色主题',
                ),
              ),
            if (compact)
              IconButton(
                onPressed: onLogin,
                icon: _SiteAccountPicture(username: username),
                tooltip: username ?? siteTr(context, 'login'),
              )
            else
              PopupMenuButton<String>(
                tooltip: username ?? siteTr(context, 'login'),
                onSelected: onGo,
                itemBuilder: (_) => [
                  for (final entry
                      in (username == null
                              ? {'/login': '登录', '/register': '注册'}
                              : {
                                  '/user': '个人中心',
                                  '/growth': '月契成长',
                                  '/notifications': '站内信',
                                  '/attachments': '附件管理',
                                  if (administrator) '/admin': '内容管理',
                                })
                          .entries)
                    PopupMenuItem(
                      value: entry.key,
                      child: SiteText(entry.value),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SiteAccountPicture(username: username),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 100),
                        child: Text(
                          username ?? siteTr(context, 'login'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      const Icon(Icons.expand_more, size: 16),
                    ],
                  ),
                ),
              ),
            if (compact) explore,
            if (!compact) ...[
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => onGo('/room'),
                icon: const Icon(CupertinoIcons.moon, size: 17),
                label: const SiteText('进入房间'),
              ),
            ],
          ],
        ),
      );
    },
  );
}

/// Only profile/identity changes rebuild the picture, not streaming chat tokens.
class _SiteAccountPicture extends StatefulWidget {
  const _SiteAccountPicture({required this.username});
  final String? username;
  @override
  State<_SiteAccountPicture> createState() => _SiteAccountPictureState();
}

class _SiteAccountPictureState extends State<_SiteAccountPicture> {
  RoomController? room;
  (String?, String?, String?, bool?, String?)? signature;
  (String?, String?, String?, bool?, String?) get currentSignature => (
    room?.account?.id,
    room?.account?.avatar,
    room?.settings.siteUrl,
    room?.sessionExpired,
    room?.site.cookie,
  );
  void changed() {
    final next = currentSignature;
    if (next != signature && mounted) setState(() => signature = next);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context
        .dependOnInheritedWidgetOfExactType<SiteControllerScope>()
        ?.controller;
    if (next != room) {
      room?.removeListener(changed);
      room = next;
      room?.addListener(changed);
      signature = currentSignature;
    }
  }

  @override
  void dispose() {
    room?.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final account = room?.sessionExpired == true ? null : room?.account;
    if (widget.username == null || account == null || account.avatar.isEmpty) {
      return const Icon(CupertinoIcons.person_crop_circle, size: 28);
    }
    return SiteAvatar(
      key: ValueKey('nav-account-avatar:${account.id}'),
      value: account.avatar,
      name: account.displayName,
      site: room!.settings.siteUrl,
      headers: room!.site.cookie == null
          ? null
          : {'Cookie': room!.site.cookie!},
      size: 28,
    );
  }
}

class ArticleBody extends StatelessWidget {
  const ArticleBody({
    super.key,
    required this.content,
    required this.format,
    required this.site,
    this.onNavigate,
    this.initialAnchor = '',
    this.headers,
  });
  final String content, format, site, initialAnchor;
  final ValueChanged<String>? onNavigate;
  final Map<String, String>? headers;

  @override
  Widget build(BuildContext context) => NativeRichText(
    content: content,
    format: format,
    site: site,
    onNavigate: onNavigate,
    initialAnchor: initialAnchor,
    headers: headers,
  );
}

/// The website returns a flat list; replies belong below their root message.
List<Map<String, dynamic>> messageThreads(List<Map<String, dynamic>> messages) {
  final copies = {
    for (final m in messages)
      '${m['id']}': {...m, 'replies': <Map<String, dynamic>>[]},
  };
  bool hasParent(Map m) =>
      m['parent_id'] != null && m['parent_id'] != 0 && m['parent_id'] != '';
  final roots = copies.values.where((m) => !hasParent(m)).toList();
  for (final m in copies.values.where(hasParent)) {
    Map<String, dynamic>? root = m;
    final seen = <String>{};
    while (root != null && hasParent(root)) {
      if (!seen.add('${root['id']}')) {
        root = null;
        break;
      }
      root = copies['${root['parent_id']}'];
    }
    // Match the website: deleted parents and cyclic legacy rows are not roots.
    if (root != null) (root['replies'] as List<Map<String, dynamic>>).add(m);
  }
  for (final m in roots) {
    (m['replies'] as List<Map<String, dynamic>>).sort(
      (a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'),
    );
  }
  return roots;
}
