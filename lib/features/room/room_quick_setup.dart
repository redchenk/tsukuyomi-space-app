import 'package:flutter/material.dart';

import '../../core/site_localization.dart';
import '../settings/settings_dialog.dart';
import 'room_controller.dart';

class RoomQuickSetup extends StatelessWidget {
  const RoomQuickSetup({
    super.key,
    required this.controller,
    this.onDiscover,
    this.onDismiss,
  });
  final RoomController controller;
  final VoidCallback? onDiscover, onDismiss;

  @override
  Widget build(BuildContext context) => Material(
    key: const Key('room-quick-setup'),
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(16),
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SiteText(
            '第一次来，先和八千代聊起来',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
          ),
          const SizedBox(height: 12),
          const SiteText(
            '① 选择聊天服务\n② 测试连接并保存\n③ 发一句话，收到完整回复',
            style: TextStyle(height: 1.9),
          ),
          const SizedBox(height: 8),
          const SiteText(
            '语音、记忆和外观可以稍后设置。站内直供需要账号与可用额度，也可以连接自己的云端或本机模型。',
            style: TextStyle(fontSize: 12, height: 1.7),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () =>
                showRoomSettings(context, controller, guidedSetup: true),
            child: const SiteText('开始分步配置'),
          ),
          if (onDiscover != null)
            TextButton(onPressed: onDiscover, child: const SiteText('先看看能做什么')),
          if (onDismiss != null)
            TextButton(onPressed: onDismiss, child: const SiteText('稍后设置')),
        ],
      ),
    ),
  );
}
