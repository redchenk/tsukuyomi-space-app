import 'package:flutter/material.dart';

import '../../core/site_localization.dart';
import '../chatroom/chatroom_copy.dart';

const primarySiteLinks = [
  ('/chatroom', '月读聊天室', 'Moon Chat', '月読チャット'),
  ('/stage', '阅读', 'Read', '記事'),
  ('/gallery', '图库', 'Gallery', 'ギャラリー'),
  ('/plaza', '广场', 'Plaza', '広場'),
  ('/wiki', '百科', 'Wiki', '百科'),
  ('/game', '游戏', 'Play', 'ゲーム'),
  ('/download', '下载', 'Download', 'ダウンロード'),
];

String primarySiteLabel(
  BuildContext context,
  (String, String, String, String) item,
) => switch (SiteLocaleScope.maybeOf(context)?.language) {
  'en' => item.$3,
  'ja' => item.$4,
  _ => item.$2,
};

String channelTitle(BuildContext context) =>
    (chatroomCopy[SiteLocaleScope.maybeOf(context)?.language] ??
    chatroomCopy['zh']!)['title']!;

class SiteDesktopNavigation extends StatelessWidget {
  const SiteDesktopNavigation({
    super.key,
    required this.onGo,
    required this.path,
    this.color,
  });
  final ValueChanged<String> onGo;
  final String path;
  final Color? color;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final item in primarySiteLinks)
        Semantics(
          selected: path == item.$1,
          child: TextButton(
            key: ValueKey('site-navigation-link-${item.$1}'),
            onPressed: () => onGo(item.$1),
            style: TextButton.styleFrom(
              foregroundColor: color,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 40),
              backgroundColor: item.$1 == '/chatroom'
                  ? (color ?? Theme.of(context).colorScheme.primary).withValues(
                      alpha: .12,
                    )
                  : Colors.transparent,
              side: item.$1 == '/chatroom'
                  ? BorderSide(
                      color: (color ?? Theme.of(context).dividerColor)
                          .withValues(alpha: .5),
                    )
                  : BorderSide.none,
              shape: const StadiumBorder(),
            ),
            child: Text(
              primarySiteLabel(context, item),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ),
    ],
  );
}
