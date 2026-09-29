import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'room_style.dart';

/// Shared website navigation for Room and its settings route.
class RoomNavigation extends StatelessWidget {
  const RoomNavigation({
    super.key,
    required this.mobile,
    required this.width,
    required this.onGo,
    required this.onSearch,
    required this.onAccount,
    required this.onSettings,
    this.onTheme,
    this.accountLabel = '登录',
    this.title = '私人居所',
  });
  final bool mobile;
  final double width;
  final String title, accountLabel;
  final ValueChanged<String> onGo;
  final VoidCallback onSearch, onSettings;
  final VoidCallback? onAccount, onTheme;
  @override
  Widget build(BuildContext context) {
    final p = RoomStyle(context);
    return Container(
      key: const Key('site-header'),
      padding: EdgeInsets.symmetric(horizontal: mobile ? 14 : 20, vertical: 10),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .035),
            blurRadius: 20,
          ),
        ],
      ),
      child: Row(
        children: [
          if (!mobile) ...[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: p.soft, shape: BoxShape.circle),
              child: Icon(CupertinoIcons.moon_stars, color: p.accent, size: 23),
            ),
            const SizedBox(width: 12),
          ],
          Semantics(
            header: true,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '月读空间',
                  style: TextStyle(
                    fontFamily: RoomStyle.serif,
                    fontSize: mobile ? 20 : 23,
                    height: 1.15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: mobile ? 0 : 2,
                    color: p.ink,
                  ),
                ),
                Text(
                  title,
                  style: TextStyle(fontSize: 9, height: 1.15, color: p.muted),
                ),
              ],
            ),
          ),
          const Spacer(),
          if (!mobile && width >= 1180)
            for (final entry in const {
              '中枢': '/hub',
              '舞台': '/stage',
              '广场': '/plaza',
              '百科': '/wiki',
            }.entries)
              TextButton(
                onPressed: () => onGo(entry.value),
                style: TextButton.styleFrom(
                  foregroundColor: p.muted,
                  minimumSize: const Size(50, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: Text(entry.key, style: const TextStyle(fontSize: 12)),
              ),
          if (!mobile) _explore(mobile: false),
          if (!mobile) const SizedBox(width: 16),
          if (!mobile && width >= 1080)
            InkWell(
              onTap: onSearch,
              borderRadius: BorderRadius.circular(30),
              child: Container(
                width: width >= 1300 ? 166 : 132,
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: p.soft,
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.search, size: 16, color: p.muted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '搜索月读空间',
                        style: TextStyle(fontSize: 11, color: p.muted),
                      ),
                    ),
                    if (width >= 1300)
                      Text(
                        '⌘ K',
                        style: TextStyle(
                          fontSize: 9,
                          height: 1.15,
                          color: p.muted,
                        ),
                      ),
                  ],
                ),
              ),
            )
          else
            _headerIcon('搜索月读空间', CupertinoIcons.search, onSearch),
          if (!mobile)
            _headerIcon(
              p.dark ? '切换浅色主题' : '切换深色主题',
              p.dark ? CupertinoIcons.sun_max : CupertinoIcons.moon,
              onTheme,
            ),
          _headerIcon('账号菜单', CupertinoIcons.person_crop_circle, onAccount),
          if (!mobile) ...[
            TextButton(
              onPressed: onAccount,
              child: Text(
                accountLabel,
                style: TextStyle(fontSize: 11, color: p.muted),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => onGo('/room'),
              style: OutlinedButton.styleFrom(
                backgroundColor: p.selected,
                foregroundColor: p.accent,
                side: BorderSide(color: p.accent.withValues(alpha: .35)),
                minimumSize: const Size(0, 40),
              ),
              icon: const Icon(CupertinoIcons.moon, size: 16),
              label: const Text('进入房间', style: TextStyle(fontSize: 11)),
            ),
          ] else
            _explore(mobile: true),
        ],
      ),
    );
  }

  Widget _headerIcon(String label, IconData icon, VoidCallback? tap) =>
      IconButton(
        tooltip: label,
        onPressed: tap,
        icon: Icon(icon, size: 19),
        style: IconButton.styleFrom(
          minimumSize: const Size(40, 40),
          padding: const EdgeInsets.all(8),
        ),
      );
  Widget _explore({required bool mobile}) => PopupMenuButton<String>(
    tooltip: '探索',
    onSelected: (v) {
      if (v == 'theme') {
        onTheme?.call();
      } else if (v == 'settings') {
        onSettings();
      } else {
        onGo(v);
      }
    },
    itemBuilder: (_) => [
      for (final e in const {
        '中枢': '/hub',
        '主舞台': '/stage',
        '月读广场': '/plaza',
        '百科': '/wiki',
        '成长': '/growth',
        '记忆': '/conversations',
      }.entries)
        PopupMenuItem(value: e.value, child: Text(e.key)),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'theme', child: Text('切换浅色 / 深色')),
      const PopupMenuItem(value: 'settings', child: Text('房间设置')),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9),
      child: mobile
          ? const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.line_horizontal_3, size: 21),
                Text('探索', style: TextStyle(fontSize: 9)),
              ],
            )
          : const Row(
              children: [
                Text('探索', style: TextStyle(fontSize: 12)),
                SizedBox(width: 4),
                Icon(CupertinoIcons.chevron_down, size: 10),
              ],
            ),
    ),
  );
}
