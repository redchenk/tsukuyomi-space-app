import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html;
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../../core/site_localization.dart';
import '../room/room_style.dart';
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

class SiteAvatar extends StatelessWidget {
  const SiteAvatar({
    super.key,
    required this.value,
    required this.name,
    required this.site,
    this.size = 40,
  });
  final String value, name, site;
  final double size;
  @override
  Widget build(BuildContext context) {
    final fallback = Center(
      child: Text(
        name.isEmpty ? '月' : name.characters.first,
        style: TextStyle(fontSize: size * .4, color: Colors.white),
      ),
    );
    Widget picture = fallback;
    try {
      if (value.startsWith('data:image/') && value.contains(';base64,')) {
        picture = Image.memory(
          base64Decode(value.split(';base64,').last),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
        );
      } else if (value.isNotEmpty) {
        final uri = endpointUri(site).resolve(value);
        if (['https', 'http'].contains(uri.scheme)) {
          picture = Image.network(
            '$uri',
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
        color: RoomStyle(context).primary,
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
      final compact =
          box.maxWidth <
          1050 * (MediaQuery.textScalerOf(context).scale(14) / 14);
      return SiteCard(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 24,
          vertical: compact ? 6 : 10,
        ),
        child: Row(
          children: [
            if (!compact)
              Icon(
                CupertinoIcons.moon,
                color: RoomStyle(context).accent,
                size: 26,
              ),
            if (!compact) const SizedBox(width: 10),
            Expanded(
              child: InkWell(
                onTap: () => onGo('/hub'),
                child: Column(
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
                      style: const TextStyle(fontSize: 10, height: 1.2),
                    ),
                  ],
                ),
              ),
            ),
            if (!compact)
              if (SiteControllerScope.maybeOf(context) case final controller?)
                IconButton(
                  onPressed: () => showSiteSearch(context, controller, onGo),
                  icon: const Icon(Icons.search),
                  tooltip: '搜索月读空间',
                ),
            if (!compact)
              if (SiteMusicScope.maybeOf(context) case final music?)
                IconButton(
                  onPressed: () => showRoomMusic(context, music),
                  icon: const Icon(CupertinoIcons.music_note_2),
                  tooltip: '全站音乐',
                ),
            if (!compact) const SiteLanguageMenu(),
            if (!compact)
              for (final path in ['/hub', '/stage', '/plaza', '/wiki'])
                TextButton(
                  onPressed: () => onGo(path),
                  child: SiteText(
                    const {
                      '/hub': '中枢',
                      '/stage': '舞台',
                      '/plaza': '广场',
                      '/wiki': '百科',
                    }[path]!,
                  ),
                ),
            if (!compact)
              IconButton(
                onPressed: onTheme,
                icon: const Icon(CupertinoIcons.moon),
                tooltip: siteTranslate(
                  context,
                  Theme.of(context).brightness == Brightness.dark
                      ? '切换浅色主题'
                      : '切换深色主题',
                ),
              ),
            IconButton(
              onPressed: onLogin,
              icon: const Icon(CupertinoIcons.person_crop_circle),
              tooltip: username ?? '登录',
            ),
            if (username != null &&
                SiteChromeScope.maybeOf(context)?.authed == true)
              IconButton(
                onPressed: () => onGo('/notifications'),
                tooltip: siteTr(context, 'notifications'),
                icon: const SiteNotificationBadge(),
              ),
            SiteExploreMenu(
              currentPath: ModalRoute.of(context)?.settings.name ?? '',
              administrator:
                  username != null &&
                  (role == 'admin' || role == 'super_admin'),
              actions: {
                if (compact) 'search': '搜索月读空间',
                if (compact) 'music': '全站音乐',
                'theme': '切换主题',
                'language:zh': '中文',
                'language:ja': '日本語',
                'language:en': 'English',
              },
              onSelected: (path) {
                if (path == 'theme') {
                  onTheme?.call();
                } else if (path == 'search') {
                  final controller = SiteControllerScope.maybeOf(context);
                  if (controller != null) {
                    showSiteSearch(context, controller, onGo);
                  }
                } else if (path == 'music') {
                  final music = SiteMusicScope.maybeOf(context);
                  if (music != null) showRoomMusic(context, music);
                } else if (path.startsWith('language:')) {
                  SiteLocaleScope.maybeOf(context)
                      ?.setLanguage(path.substring(9));
                } else {
                  onGo(path);
                }
              },
            ),
            if (!compact)
              FilledButton.icon(
                onPressed: () => onGo('/room'),
                icon: const Icon(CupertinoIcons.moon),
                label: const SiteText('进入房间'),
              ),
          ],
        ),
      );
    },
  );
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
