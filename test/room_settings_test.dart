import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/locale_controller.dart';
import 'package:tsukuyomi_space_app/core/site_localization.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/settings/settings_page.dart';

import 'support/fakes.dart';

void main() {
  for (final language in LocaleController.languages) {
    for (final width in [390.0, 1280.0]) {
      testWidgets(
        'MCP transport can be selected and saved in $language at $width',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final storage = MemoryStorage();
          final locale = LocaleController(storage);
          await locale.setLanguage(language);
          final c = RoomController(
            storage: storage,
            chat: FakeChat(),
            site: FakeSite(),
            voice: SilentVoice(),
          );
          await c.initialize();
          addTearDown(c.dispose);
          addTearDown(locale.dispose);
          await tester.pumpWidget(
            SiteLocaleScope(
              controller: locale,
              child: MaterialApp(
                home: RoomSettingsPage(controller: c, initialSection: 'mcp'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final selector = find.byKey(const ValueKey('mcpTransport:rest'));
          await tester.ensureVisible(selector);
          expect(
            find.text(siteMessage(language, 'nativeMcpTransport')),
            findsOneWidget,
          );
          await tester.tap(selector);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Streamable HTTP').last);
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(
              siteTranslate(
                tester.element(find.byType(RoomSettingsPage)),
                '保存修改',
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(storage.value.option('mcpTransport'), 'streamable-http');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final width in [320.0, 390.0, 861.0, 1280.0]) {
    for (final section in roomSections.keys) {
      testWidgets(
        'Room settings $section at $width has usable controls without overflow',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final c = RoomController(
            storage: MemoryStorage(),
            chat: FakeChat(),
            site: FakeSite(),
            voice: SilentVoice(),
          );
          await c.initialize();
          addTearDown(c.dispose);
          await tester.pumpWidget(
            MaterialApp(
              home: RoomSettingsPage(controller: c, initialSection: section),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.drag(
            find.byType(SingleChildScrollView).first,
            const Offset(0, -600),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('model edits save without exposing secrets in preferences', (
    tester,
  ) async {
    final storage = MemoryStorage();
    final c = RoomController(
      storage: storage,
      chat: FakeChat(),
      site: FakeSite(),
      voice: SilentVoice(),
    );
    await c.initialize();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RoomSettingsPage(controller: c, initialSection: 'model'),
      ),
    );
    await tester.pumpAndSettle();
    final slider = find.byType(Slider).first;
    await tester.ensureVisible(
      find.byKey(const ValueKey('live2dRenderQuality:auto')),
    );
    await tester.tap(find.byKey(const ValueKey('live2dRenderQuality:auto')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('省电 · 降低显卡负载').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('live2dFrameRate:0')));
    await tester.tap(find.byKey(const ValueKey('live2dFrameRate:0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 fps').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(slider);
    await tester.tap(slider);
    await tester.pump();
    expect(find.text('保存修改'), findsOneWidget);
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    expect(storage.value.options['modelScale'], isA<num>());
    expect(storage.value.options['live2dRenderQuality'], 'economy');
    expect(storage.value.number('live2dFrameRate'), 30);
    expect(storage.value.toJson().keys, isNot(contains('apiKey')));
  });
  Future<RoomController> openModelSettings(
    WidgetTester tester,
    MemoryStorage storage,
  ) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = RoomController(
      storage: storage,
      chat: FakeChat(),
      site: FakeSite(),
      voice: SilentVoice(),
    );
    await c.initialize();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RoomSettingsPage(controller: c, initialSection: 'llm'),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('Anthropic workspace ID shows only for Claude and is saved', (
    tester,
  ) async {
    final storage = MemoryStorage()
      ..value = const RoomSettings(
        demo: false,
        llmUrl: 'https://api.deepseek.com/chat/completions',
        model: 'deepseek-chat',
      );
    await openModelSettings(tester, storage);
    await tester.ensureVisible(find.text('高级连接设置'));
    await tester.tap(find.text('高级连接设置'));
    await tester.pumpAndSettle();
    final workspace = find.byKey(const Key('setting-anthropicWorkspaceId'));
    expect(workspace, findsNothing);
    expect(find.byKey(const Key('setting-aliyunWorkspaceId')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('setting-llmUrl')),
      'https://api.anthropic.com/v1/messages',
    );
    await tester.pumpAndSettle();
    expect(workspace, findsOneWidget);
    expect(find.byKey(const Key('setting-aliyunWorkspaceId')), findsNothing);
    final decoration = tester.widget<TextField>(workspace).decoration!;
    expect(decoration.labelText, 'Anthropic 工作区 ID（可选，密钥未绑定工作区时填写）');
    expect(decoration.hintText, 'wrkspc_…');
    await tester.enterText(workspace, ' wrkspc_fixture ');
    await tester.pump();
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    expect(storage.value.option('anthropicWorkspaceId'), 'wrkspc_fixture');
    expect(storage.value.llmUrl, 'https://api.anthropic.com/v1/messages');
  });
  for (final reason in ['max_tokens', 'refusal']) {
    testWidgets('Claude connection test rejects a $reason stop', (
      tester,
    ) async {
      final storage = MemoryStorage()
        ..value = const RoomSettings(
          demo: false,
          llmUrl: 'https://api.anthropic.com/v1/messages',
          model: 'claude-opus-5-5',
          apiKey: 'fixture-key',
        );
      await openModelSettings(tester, storage);
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response(
          jsonEncode({
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': '半截回复'},
            ],
            'stop_reason': reason,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      await tester.ensureVisible(find.text('测试连接'));
      // Response streams need real async, so run the test outside fake time.
      await tester.runAsync(
        () => http.runWithClient(() async {
          await tester.tap(find.text('测试连接'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }, () => client),
      );
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(find.text('连接测试失败'), findsOneWidget);
      expect(find.textContaining('半截回复'), findsNothing);
      expect(find.textContaining('模型回复：'), findsNothing);
    });
  }
  testWidgets('capture settings desktop and mobile using native fonts', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final ping =
          Directory('/System/Library/AssetsV2/com_apple_MobileAsset_Font8')
              .listSync(recursive: true)
              .whereType<File>()
              .firstWhere((f) => f.path.endsWith('/PingFang.ttc'));
      for (final family in ['Roboto', 'PingFang SC']) {
        await (FontLoader(family)..addFont(
              Future.value(ByteData.sublistView(await ping.readAsBytes())),
            ))
            .load();
      }
      await (FontLoader('Songti SC')..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  const String.fromEnvironment(
                    'QA_SERIF_FONT',
                    defaultValue:
                        '/System/Library/Fonts/Supplemental/Songti.ttc',
                  ),
                ).readAsBytes(),
              ),
            ),
          ))
          .load();
      await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
            rootBundle.load(
              'packages/cupertino_icons/assets/CupertinoIcons.ttf',
            ),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [const Size(1280, 900), const Size(390, 844)]) {
      tester.view.physicalSize = size;
      final c = RoomController(
        storage: MemoryStorage()
          ..value = const RoomSettings(
            demo: false,
            llmUrl: 'https://api.openai.com/v1/chat/completions',
            model: '',
          ),
        chat: FakeChat(),
        site: FakeSite(),
        voice: SilentVoice(),
      );
      await c.initialize();
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              fontFamily: 'PingFang SC',
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff60439f),
                surface: Colors.white,
              ),
              inputDecorationTheme: InputDecorationTheme(
                filled: true,
                fillColor: const Color(0xffefedf7),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            home: RoomSettingsPage(controller: c),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
        find.byKey(const Key('capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          'artifacts/room-parity/native-settings-${size.width > 860 ? 'desktop' : 'mobile'}.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    }
  }, skip: !const bool.fromEnvironment('CAPTURE_UI'));
}
