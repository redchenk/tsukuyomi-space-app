import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/parser.dart' as html;
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../room/room_style.dart';

const siteDestinations = <String, String>{
  '/room': '私人居所',
  '/stage': '主舞台',
  '/plaza': '月读广场',
  '/conversations': '会话与记忆',
  '/growth': '月契成长',
  '/user': '个人中心',
};
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
  });
  final String title;
  final String? username;
  final ValueChanged<String> onGo;
  final VoidCallback onLogin;
  final VoidCallback? onTheme;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final compact = box.maxWidth < 1050;
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
            InkWell(
              onTap: () => onGo('/room'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '月读空间',
                    style: TextStyle(
                      fontFamily: RoomStyle.serif,
                      fontSize: 21,
                      letterSpacing: 2,
                    ),
                  ),
                  Text(title, style: const TextStyle(fontSize: 10)),
                ],
              ),
            ),
            const Spacer(),
            if (!compact)
              for (final path in [
                '/stage',
                '/plaza',
                '/conversations',
                '/growth',
              ])
                TextButton(
                  onPressed: () => onGo(path),
                  child: Text(siteDestinations[path]!),
                ),
            if (!compact)
              IconButton(
                onPressed: onTheme,
                icon: const Icon(CupertinoIcons.moon),
                tooltip: '切换主题',
              ),
            IconButton(
              onPressed: onLogin,
              icon: const Icon(CupertinoIcons.person_crop_circle),
              tooltip: username ?? '登录',
            ),
            PopupMenuButton<String>(
              tooltip: '探索',
              onSelected: onGo,
              icon: const Icon(Icons.menu),
              itemBuilder: (_) => [
                for (final item in siteDestinations.entries)
                  PopupMenuItem(value: item.key, child: Text(item.value)),
              ],
            ),
            if (!compact)
              FilledButton.icon(
                onPressed: () => onGo('/room'),
                icon: const Icon(CupertinoIcons.moon),
                label: const Text('进入房间'),
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
  });
  final String content, format, site;
  @override
  Widget build(BuildContext context) {
    if (format == 'html') {
      // Remote documents never get access to local file/asset image providers.
      final document = html.parseFragment(content);
      for (final element in document.querySelectorAll('img,source')) {
        final src = element.attributes['src'] ?? '';
        final uri = Uri.tryParse(src);
        if (uri == null ||
            (uri.hasScheme &&
                !['https', 'http', 'data'].contains(uri.scheme))) {
          element.remove();
        }
      }
      for (final element in document.querySelectorAll(
        'script,iframe,object,embed,input,form',
      )) {
        element.remove();
      }
      return SelectionArea(
        child: HtmlWidget(
          document.outerHtml,
          baseUrl: endpointUri(site),
          textStyle: const TextStyle(fontSize: 17, height: 1.85),
          onTapUrl: (url) => openSiteLink(site, url),
        ),
      );
    }
    return MarkdownBody(
      data: content,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(fontSize: 17, height: 1.85),
      ),
      onTapLink: (_, href, _) {
        if (href != null) openSiteLink(site, href);
      },
      imageBuilder: (uri, title, alt) {
        final target = endpointUri(site).resolveUri(uri);
        if (!['https', 'http'].contains(target.scheme)) return Text(alt ?? '');
        return Image.network(
          '$target',
          errorBuilder: (_, _, _) => Text(alt ?? '图片暂不可用'),
        );
      },
    );
  }
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
