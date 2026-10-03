import 'package:flutter/material.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/app_theme_controller.dart';
import 'package:tsukuyomi_space_app/core/locale_controller.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/main.dart';

import '../test/support/fakes.dart';

// Visual QA uses isolated memory storage, never the installed app's account.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const fixture = bool.fromEnvironment('PREVIEW_FIXTURE');
  const initialPath = String.fromEnvironment(
    'PREVIEW_PATH',
    defaultValue: '/room',
  );
  final storage = MemoryStorage();
  storage.drafts[AppThemeController.storageKey] = const String.fromEnvironment(
    'PREVIEW_THEME',
    defaultValue: 'dark',
  );
  storage.drafts[LocaleController.storageKey] = const String.fromEnvironment(
    'PREVIEW_LANGUAGE',
    defaultValue: 'zh',
  );
  if (fixture) {
    storage.value = const RoomSettings(
      siteUrl: String.fromEnvironment(
        'PREVIEW_SITE',
        defaultValue: 'http://127.0.0.1:4184',
      ),
    );
  }
  final controller = RoomController(
    storage: storage,
    chat: FakeChat(),
    site: SiteClient(),
    voice: SilentVoice(),
  );
  await controller.initialize();
  if (fixture) await controller.login('e2e-user', 'e2e-password');
  runApp(
    TsukuyomiApp(
      controller: controller,
      loadNative: !fixture,
      initialPath: initialPath,
    ),
  );
}
