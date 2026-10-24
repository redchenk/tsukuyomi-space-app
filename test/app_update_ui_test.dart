import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsukuyomi_space_app/core/app_update_controller.dart';
import 'package:tsukuyomi_space_app/core/app_update_installer.dart';
import 'package:tsukuyomi_space_app/core/app_update_release.dart';
import 'package:tsukuyomi_space_app/core/app_update_service.dart';
import 'package:tsukuyomi_space_app/core/locale_controller.dart';
import 'package:tsukuyomi_space_app/core/site_theme.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/settings/settings_page.dart';
import 'package:tsukuyomi_space_app/features/site/site_chrome.dart';
import 'package:tsukuyomi_space_app/features/site/site_widgets.dart';
import 'package:tsukuyomi_space_app/features/updates/app_update_page.dart';
import 'package:tsukuyomi_space_app/main.dart';

import 'support/fakes.dart';

class _Transport implements UpdateTransport {
  final bytes = utf8.encode('update UI installer fixture');
  static const name = 'tsukuyomi-space-9.0.0-windows-x64-setup.exe';
  int calls = 0;
  @override
  Stream<List<int>> read(Uri url, UpdateCancellation token) async* {
    calls++;
    final hash = sha256.convert(bytes).toString();
    if (url == appReleasesApi) {
      yield utf8.encode(
        jsonEncode([
          {
            'tag_name': 'v9.0.0',
            'draft': false,
            'prerelease': false,
            'html_url': '$appRepository/releases/tag/v9.0.0',
            'body': '### 更自然的月读空间\n\n- Native update fixture\n- 保留聊天记录\n',
            'assets': [
              for (final asset in [name, 'SHA256SUMS.txt'])
                {
                  'name': asset,
                  'state': 'uploaded',
                  'size': asset == name ? bytes.length : 200,
                  'digest': asset == name ? 'sha256:$hash' : null,
                  'browser_download_url':
                      '$appDistributionOrigin/releases/v9.0.0/$asset',
                },
            ],
          },
        ]),
      );
    } else if (url.path.endsWith('SHA256SUMS.txt')) {
      yield utf8.encode('$hash  $name\n');
    } else {
      yield bytes;
    }
  }
}

class _Installer implements UpdateInstaller {
  int calls = 0;
  @override
  Future<UpdateInstallResult> install(
    File file,
    UpdatePlatform platform,
  ) async {
    calls++;
    return UpdateInstallResult.opened;
  }
}

void main() {
  Future<(RoomController, AppUpdateController, _Transport, _Installer)> setup({
    Directory? cache,
  }) async {
    SharedPreferences.setMockInitialValues({'app-update.automatic': false});
    final room = RoomController(
      storage: MemoryStorage(),
      chat: FakeChat(),
      site: FakeSite(),
      voice: SilentVoice(),
    );
    await room.initialize();
    addTearDown(room.dispose);
    final transport = _Transport(), installer = _Installer();
    final updates = AppUpdateController(
      preferences: await SharedPreferences.getInstance(),
      service: AppUpdateService(
        transport: transport,
        cacheDirectory: cache == null ? null : () async => cache,
      ),
      installer: installer,
      installedApp: () async => InstalledApp(
        AppVersion.parse('v0.6.11-beta.1')!,
        '17',
        UpdatePlatform.windows,
      ),
    );
    await updates.check();
    return (room, updates, transport, installer);
  }

  for (final width in [360, 390, 768, 1280, 1920]) {
    for (final language in ['zh', 'en', 'ja']) {
      for (final dark in [false, true]) {
        testWidgets(
          'update page $width $language dark=$dark with enlarged text',
          (tester) async {
            tester.view.physicalSize = Size(width.toDouble(), 1000);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final (room, updates, _, _) = await setup();
            addTearDown(updates.dispose);
            final locale = LocaleController(room.storage);
            await locale.setLanguage(language);
            addTearDown(locale.dispose);
            await tester.pumpWidget(
              SiteLocaleScope(
                controller: locale,
                child: AppUpdateScope(
                  controller: updates,
                  child: MaterialApp(
                    locale: Locale(language),
                    supportedLocales: const [
                      Locale('zh'),
                      Locale('en'),
                      Locale('ja'),
                    ],
                    localizationsDelegates: const [
                      GlobalMaterialLocalizations.delegate,
                      GlobalWidgetsLocalizations.delegate,
                      GlobalCupertinoLocalizations.delegate,
                    ],
                    theme: siteTheme(dark),
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: const TextScaler.linear(1.5)),
                      child: child!,
                    ),
                    home: AppUpdatePage(
                      updates: updates,
                      room: room,
                      onGo: (_) {},
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text('v9.0.0'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.scrollUntilVisible(
              find.byType(SwitchListTile).last,
              400,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
  testWidgets(
    'header opens native updates; installation occurs only after confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final cache = await tester.runAsync(
        () => Directory.systemTemp.createTemp('tsukuyomi-update-ui-'),
      );
      addTearDown(() => cache!.delete(recursive: true));
      final (room, updates, transport, installer) = await setup(cache: cache);
      await tester.pumpWidget(
        TsukuyomiApp(controller: room, updates: updates, loadNative: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('app-update-button')));
      await tester.pumpAndSettle();
      expect(find.byType(AppUpdatePage), findsOneWidget);
      expect(transport.calls, 1); // navigation never downloads
      await tester.ensureVisible(find.byKey(const Key('app-update-download')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('app-update-download')));
        while (updates.busy) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(updates.downloaded, isNotNull);
      expect(installer.calls, 0);
      await tester.tap(find.byKey(const Key('app-update-download')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(installer.calls, 0);
      await tester.tap(find.byKey(const Key('app-update-download')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续安装'));
      for (var attempt = 0; attempt < 100 && installer.calls == 0; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(installer.calls, 1);
      expect(updates.phase, AppUpdatePhase.opened);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('update navigation preserves settings save/discard guard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (room, updates, _, _) = await setup();
    await tester.pumpWidget(
      TsukuyomiApp(
        controller: room,
        updates: updates,
        loadNative: false,
        initialPath: '/room/settings',
      ),
    );
    await tester.pumpAndSettle();
    final model = find.byKey(const Key('setting-model'));
    await tester.ensureVisible(model);
    await tester.enterText(model, 'unsaved-update-guard');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('app-update-button')));
    await tester.tap(find.byKey(const Key('app-update-button')));
    await tester.pumpAndSettle();
    expect(find.text('设置尚未保存'), findsOneWidget);
    expect(find.byType(AppUpdatePage), findsNothing);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(RoomSettingsPage), findsOneWidget);
    expect(
      tester.widget<TextField>(model).controller!.text,
      'unsaved-update-guard',
    );
    await tester.ensureVisible(find.byKey(const Key('app-update-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('app-update-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃并离开'));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('automatic update notice cannot bypass an active editing guard', (
    tester,
  ) async {
    final (room, updates, _, _) = await setup();
    await tester.pumpWidget(
      TsukuyomiApp(
        controller: room,
        updates: updates,
        loadNative: false,
        initialPath: '/room/settings',
      ),
    );
    await tester.pumpAndSettle();
    await updates.preferences.setBool('app-update.automatic', true);
    await updates.check(automaticCheck: true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-update-prompt')), findsOneWidget);
    expect(find.textContaining('保存当前内容后，可从顶部更新图标查看。'), findsOneWidget);
    expect(find.text('查看更新'), findsNothing);
    expect(find.byType(AppUpdatePage), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'automatic popup offers details without downloading and only once',
    (tester) async {
      final (room, updates, transport, installer) = await setup();
      await tester.pumpWidget(
        TsukuyomiApp(controller: room, updates: updates, loadNative: false),
      );
      await tester.pumpAndSettle();
      await updates.preferences.setBool('app-update.automatic', true);
      await updates.check(automaticCheck: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-prompt')), findsOneWidget);
      expect(find.text('v9.0.0'), findsOneWidget);
      expect(installer.calls, 0);
      expect(transport.calls, 2);
      await tester.tap(find.text('查看更新'));
      await tester.pumpAndSettle();
      expect(find.byType(AppUpdatePage), findsOneWidget);
      expect(transport.calls, 2);
      await updates.check(automaticCheck: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-prompt')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'popup waits for other dialogs and foreground, later persists tag',
    (tester) async {
      final (room, updates, _, _) = await setup();
      await tester.pumpWidget(
        TsukuyomiApp(controller: room, updates: updates, loadNative: false),
      );
      await tester.pumpAndSettle();
      final pageContext = tester.element(find.byType(Scaffold).first);
      final dialog = showDialog<void>(
        context: pageContext,
        builder: (_) => const AlertDialog(title: Text('existing dialog')),
      );
      await tester.pumpAndSettle();
      await updates.preferences.setBool('app-update.automatic', true);
      await updates.check(automaticCheck: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-prompt')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      Navigator.of(tester.element(find.text('existing dialog'))).pop();
      await dialog;
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-prompt')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-prompt')), findsOneWidget);
      await tester.tap(find.text('此版本稍后提醒'));
      await tester.pumpAndSettle();
      expect(updates.preferences.getString('app-update.dismissed'), 'v9.0.0');
      await updates.check(automaticCheck: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-prompt')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [320, 360, 390, 768, 960, 1280, 1920]) {
    for (final language in ['zh', 'ja', 'en']) {
      testWidgets('logged in brand stays complete at $width in $language', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width.toDouble(), 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final (room, updates, _, _) = await setup();
        addTearDown(updates.dispose);
        await room.login('alice', 'test');
        final chrome = SiteChromeController(room);
        addTearDown(chrome.dispose);
        final locale = LocaleController(room.storage);
        await locale.setLanguage(language);
        addTearDown(locale.dispose);
        await tester.pumpWidget(
          SiteLocaleScope(
            controller: locale,
            child: AppUpdateScope(
              controller: updates,
              child: SiteChromeScope(
                controller: chrome,
                child: MaterialApp(
                  theme: siteTheme(false),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(
                        width == 360 && language == 'zh' ? 3 : 1.5,
                      ),
                    ),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: Align(
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        height: 60,
                        child: SiteHeader(
                          title: '私人居所',
                          username: 'alice',
                          onGo: (_) {},
                          onLogin: () {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byKey(const Key('site-brand-title')),
            matching: find.byType(RichText),
          ),
        );
        expect(paragraph.didExceedMaxLines, false);
        expect(paragraph.text.toPlainText().contains('…'), false);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('site-account-menu')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
