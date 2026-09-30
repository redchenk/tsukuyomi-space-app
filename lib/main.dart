import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

import 'core/llm_client.dart';
import 'core/site_client.dart';
import 'core/storage.dart';
import 'core/voice_service.dart';
import 'features/room/room_controller.dart';
import 'features/room/room_page.dart';
import 'features/room/room_style.dart';
import 'features/site/site_page.dart';
import 'features/settings/settings_page.dart';

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

class TsukuyomiApp extends StatefulWidget {
  const TsukuyomiApp({
    super.key,
    required this.controller,
    this.loadNative = true,
    this.modelLoader,
  });
  final RoomController controller;
  final bool loadNative;
  final Future<Live2DModel> Function()? modelLoader;
  @override
  State<TsukuyomiApp> createState() => _TsukuyomiAppState();
}

class _TsukuyomiAppState extends State<TsukuyomiApp> {
  bool _dark = false;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '月读空间',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: _dark ? Brightness.dark : Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff60439f),
        brightness: _dark ? Brightness.dark : Brightness.light,
        surface: _dark ? const Color(0xff25212f) : Colors.white,
        primary: _dark ? const Color(0xffc5adee) : const Color(0xff60439f),
      ),
      scaffoldBackgroundColor: _dark
          ? const Color(0xff17151e)
          : const Color(0xfff5f4fa),
      fontFamilyFallback: const [
        'PingFang SC',
        'Microsoft YaHei',
        'Noto Sans CJK SC',
      ],
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _dark ? const Color(0xff312b3e) : const Color(0xffefedf7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    ),
    onGenerateRoute: (settings) => MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => settings.name == '/room/settings'
          ? RoomSettingsPage(
              controller: widget.controller,
              onTheme: () => setState(() => _dark = !_dark),
            )
          : SitePage(
              controller: widget.controller,
              path: settings.name ?? '/stage',
              onTheme: () => setState(() => _dark = !_dark),
            ),
    ),
    home: Builder(
      builder: (context) => DefaultTextStyle.merge(
        style: TextStyle(color: RoomStyle(context).ink),
        child: RoomPage(
          controller: widget.controller,
          onNavigate: (path) => Navigator.of(context).pushNamed(path),
          loadNative: widget.loadNative,
          modelLoader: widget.modelLoader,
          onToggleTheme: () => setState(() => _dark = !_dark),
        ),
      ),
    ),
  );
}
