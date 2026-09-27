import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/llm_client.dart';
import 'core/site_client.dart';
import 'core/storage.dart';
import 'core/voice_service.dart';
import 'features/room/room_controller.dart';
import 'features/room/room_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final controller = RoomController(
    storage: DeviceRoomStorage(preferences),
    chat: LlmClient(),
    site: SiteClient(),
    voice: AudioVoice(),
  );
  runApp(TsukuyomiApp(controller: controller));
  await controller.initialize();
}

class TsukuyomiApp extends StatelessWidget {
  const TsukuyomiApp({
    super.key,
    required this.controller,
    this.loadNative = true,
  });
  final RoomController controller;
  final bool loadNative;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '月读空间',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xffb6a3f5),
        brightness: Brightness.dark,
        surface: const Color(0xff151928),
        primary: const Color(0xffc7b5ff),
      ),
      scaffoldBackgroundColor: const Color(0xff0e1220),
      fontFamilyFallback: const [
        'PingFang SC',
        'Microsoft YaHei',
        'Noto Sans CJK SC',
      ],
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xff1d2233),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    ),
    home: RoomPage(controller: controller, loadNative: loadNative),
  );
}
