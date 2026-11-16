import '../../core/site_localization.dart';

import 'package:flutter/material.dart';

import '../room/room_controller.dart';
import '../site/native_site_shell.dart';
import '../site/site_widgets.dart';

class GameCenterPage extends StatelessWidget {
  const GameCenterPage({
    super.key,
    required this.controller,
    required this.onGo,
    this.onTheme,
  });
  final RoomController controller;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  @override
  Widget build(BuildContext context) => NativeSiteShell(
    controller: controller,
    title: '游戏中心',
    onGo: onGo,
    onTheme: onTheme,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SiteText('和八千代一起，轻松玩一局', style: TextStyle(fontSize: 28)),
        const SizedBox(height: 24),
        for (final game in [
          ('/game/gomoku', '月下五子棋', '先后手、难度选择、悔棋、提示与本地续局。', Icons.grid_on),
          (
            '/game/kaguya-run',
            '辉夜快跑',
            '跟着节拍奔跑，挑战关卡与成绩。',
            Icons.sports_esports_outlined,
          ),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: SiteCard(
              child: ListTile(
                leading: Icon(game.$4, size: 36),
                title: SiteText(game.$2),
                subtitle: SiteText(game.$3),
                trailing: const Icon(Icons.arrow_forward),
                onTap: () => onGo(game.$1),
              ),
            ),
          ),
      ],
    ),
  );
}
