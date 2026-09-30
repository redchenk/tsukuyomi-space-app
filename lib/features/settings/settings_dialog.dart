import 'package:flutter/material.dart';

import '../room/room_controller.dart';
import 'settings_page.dart';

Future<void> showRoomSettings(
  BuildContext context,
  RoomController controller, {
  String section = 'llm',
  VoidCallback? onTheme,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => RoomSettingsPage(
      controller: controller,
      initialSection: section,
      onTheme: onTheme,
    ),
    settings: const RouteSettings(name: '/room/settings'),
  ),
);
