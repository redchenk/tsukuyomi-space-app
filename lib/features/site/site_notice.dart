import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../room/room_style.dart';
import 'site_widgets.dart' show openSiteLink;

const noticeMaxLength = 20000;

String announcementContent(Map<String, dynamic> settings) {
  final announcement = '${settings['siteAnnouncement'] ?? ''}'.trim();
  final popup = '${settings['visitPopupContent'] ?? ''}'.trim();
  return announcement == '欢迎访问月读空间' && popup.isNotEmpty
      ? popup
      : announcement.isNotEmpty
      ? announcement
      : popup;
}

String noticeSummary(String content) {
  final source = content.substring(0, content.length.clamp(0, noticeMaxLength));
  final nodes = md.Document(extensionSet: md.ExtensionSet.gitHubWeb)
      .parseLines(source.split('\n'));
  if (nodes.isEmpty) return '';
  return String.fromCharCodes(
    nodes.first.textContent
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .runes
        .take(100),
  );
}

({Uri url, bool internal})? safeNoticeLink(String value, String site) {
  final href = value.trim();
  if (href.isEmpty ||
      href.startsWith('//') ||
      RegExp(r'[\\\u0000-\u001f\u007f]').hasMatch(href)) {
    return null;
  }
  final base = Uri.tryParse(site), raw = Uri.tryParse(href);
  if (base == null || raw == null || !base.hasAuthority) return null;
  final url = base.resolveUri(raw);
  if (!['https', 'http'].contains(url.scheme) ||
      !url.hasAuthority ||
      url.userInfo.isNotEmpty) {
    return null;
  }
  String canonical(String host) => host.replaceFirst(RegExp(r'^www\.'), '');
  final internal =
      url.origin == base.origin ||
      (canonical(url.host) == canonical(base.host) &&
          [
            'yachiyo.hk',
            'tsukuyomi-space.com',
          ].contains(canonical(base.host)) &&
          !url.hasPort &&
          !base.hasPort);
  return (url: url, internal: internal);
}

/// The site's text-only notice subset: links are checked at the interaction
/// boundary, images render their alt text and HTML never creates a web view.
class SiteNotice extends StatelessWidget {
  const SiteNotice({
    super.key,
    required this.content,
    required this.site,
    required this.onGo,
  });
  final String content, site;
  final ValueChanged<String> onGo;

  @override
  Widget build(BuildContext context) {
    final p = RoomStyle(context);
    return MarkdownBody(
      data: content.substring(0, content.length.clamp(0, noticeMaxLength)),
      selectable: true,
      softLineBreak: true,
      imageBuilder: (uri, title, alt) => Text(alt ?? ''),
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(color: p.ink, fontSize: 14, height: 1.9),
        a: TextStyle(color: p.accent, decoration: TextDecoration.underline),
        h1: TextStyle(fontSize: 21, fontWeight: FontWeight.w600, color: p.ink),
        h2: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: p.ink),
        h3: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: p.ink),
        blockquoteDecoration: BoxDecoration(color: p.soft),
        codeblockDecoration: BoxDecoration(color: p.soft),
      ),
      onTapLink: (_, href, _) {
        final link = safeNoticeLink(href ?? '', site);
        if (link == null) return;
        if (link.internal) {
          onGo(
            '${link.url.path}${link.url.hasQuery ? '?${link.url.query}' : ''}'
            '${link.url.hasFragment ? '#${link.url.fragment}' : ''}',
          );
        } else {
          openSiteLink(site, link.url.toString());
        }
      },
    );
  }
}
