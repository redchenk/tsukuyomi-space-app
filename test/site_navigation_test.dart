import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/room/room_page.dart';
import 'package:tsukuyomi_space_app/features/settings/settings_page.dart';
import 'package:tsukuyomi_space_app/features/site/hub_page.dart';
import 'package:tsukuyomi_space_app/features/site/site_navigation.dart';
import 'package:tsukuyomi_space_app/features/site/site_page.dart';
import 'package:tsukuyomi_space_app/features/site/user_center_page.dart';
import 'package:tsukuyomi_space_app/main.dart';

import 'support/fakes.dart';

class NavigationSite extends FakeSite implements SiteDataService {
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    calls.add('$method $path');
    if (path.endsWith('/articles/42')) {
      return {
        'success': true,
        'data': {
          'id': 42,
          'title': '路由回归文章',
          'content_format': 'markdown',
          'content': '[个人中心](https://yachiyo.hk/user-center)',
        },
      };
    }
    return {'success': true, 'data': <String, dynamic>{}};
  }
}

void main() {
  Future<(RoomController, NavigationSite)> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final site = NavigationSite();
    final c = RoomController(
      storage: MemoryStorage(),
      chat: FakeChat(),
      site: site,
      voice: SilentVoice(),
    );
    await c.initialize();
    addTearDown(c.dispose);
    await tester.pumpWidget(TsukuyomiApp(controller: c, loadNative: false));
    await tester.pumpAndSettle();
    return (c, site);
  }

  testWidgets('Room 中枢 opens native Hub and Room button stays in the app', (
    tester,
  ) async {
    final (_, site) = await mount(tester);
    var launches = 0;
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      launches++;
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.tap(find.text('进入房间'));
    await tester.pumpAndSettle();
    expect(find.byType(RoomPage), findsOneWidget);
    expect(launches, 0);
    await tester.tap(find.text('中枢'));
    await tester.pumpAndSettle();
    expect(find.byType(HubPage), findsOneWidget);
    expect(find.byType(SitePage), findsNothing);
    expect(site.calls.any((call) => call.contains('/api/hub-preview')), isTrue);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('进入房间'));
    await tester.pumpAndSettle();
    expect(find.byType(RoomPage), findsOneWidget);
    expect(find.byType(HubPage), findsNothing);
    expect(launches, 0);
  });

  testWidgets(
    'settings alias opens the requested section and Hub returns to the same settings',
    (tester) async {
      await mount(tester);
      final room = tester.element(find.byType(RoomPage));
      Navigator.of(room).pushNamed('/room-settings?section=memory');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<RoomSettingsPage>(find.byType(RoomSettingsPage))
            .initialSection,
        'memory',
      );
      final state = tester.state(find.byType(RoomSettingsPage));
      await tester.tap(find.text('中枢'));
      await tester.pumpAndSettle();
      expect(find.byType(HubPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(HubPage))).pop();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(RoomSettingsPage)), same(state));
      await tester.tap(find.text('进入房间'));
      await tester.pumpAndSettle();
      expect(find.byType(RoomPage), findsOneWidget);
      expect(find.byType(RoomSettingsPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'article alias loads the actual ID and same-origin body links stay native',
    (tester) async {
      final (c, site) = await mount(tester);
      await c.login('alice', 'test');
      final room = tester.element(find.byType(RoomPage));
      Navigator.of(room).pushNamed('/article?id=42&from=%2Fstage');
      await tester.pumpAndSettle();
      expect(find.text('路由回归文章'), findsOneWidget);
      expect(
        tester.widget<SitePage>(find.byType(SitePage)).path,
        '/articles/42?from=%2Fstage',
      );
      expect(site.calls.any((call) => call.endsWith('/articles/42')), isTrue);
      final link = find.text('个人中心', findRichText: true).last;
      await tester.ensureVisible(link);
      // Rich-text paragraphs occupy the full article width; hit the linked
      // glyphs rather than the empty center of the paragraph's layout box.
      final paragraph = tester.renderObject<RenderParagraph>(link);
      final box = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 4),
          )
          .first;
      await tester.tapAt(paragraph.localToGlobal(box.toRect().center));
      await tester.pumpAndSettle();
      expect(find.byType(UserCenterPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unknown named routes cannot silently request or show articles', (
    tester,
  ) async {
    final (_, site) = await mount(tester);
    final room = tester.element(find.byType(RoomPage));
    Navigator.of(room).pushNamed('/not-implemented');
    await tester.pumpAndSettle();
    expect(find.byType(SiteRouteFallback), findsOneWidget);
    expect(find.text('此页面暂未提供原生版本'), findsOneWidget);
    expect(find.byType(SitePage), findsNothing);
    expect(site.calls.where((call) => call.contains('/api/articles')), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native navigation protects unsaved settings before leaving', (
    tester,
  ) async {
    await mount(tester);
    Navigator.of(tester.element(find.byType(RoomPage)))
        .pushNamed('/room/settings');
    await tester.pumpAndSettle();
    final model = find.widgetWithText(TextField, '模型 Model');
    await tester.ensureVisible(model);
    await tester.enterText(model, 'unsaved-model');
    await tester.pump();
    await tester.ensureVisible(find.text('中枢'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('中枢'));
    await tester.pumpAndSettle();
    expect(find.text('设置尚未保存'), findsOneWidget);
    expect(find.byType(HubPage), findsNothing);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(model).controller!.text, 'unsaved-model');
    await tester.ensureVisible(find.text('中枢'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('中枢'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃并离开'));
    await tester.pumpAndSettle();
    expect(find.byType(HubPage), findsOneWidget);
    await tester.tap(find.text('进入房间'));
    await tester.pumpAndSettle();
    expect(find.byType(RoomPage), findsOneWidget);
    expect(find.byType(RoomSettingsPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('theme toggles are shared and survive recreating the app', (
    tester,
  ) async {
    final (c, _) = await mount(tester);
    expect(
      Theme.of(tester.element(find.byType(RoomPage))).brightness,
      Brightness.dark,
    );
    await tester.tap(find.byTooltip('切换浅色主题'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(RoomPage))).brightness,
      Brightness.light,
    );
    expect((c.storage as MemoryStorage).drafts['app-theme'], 'light');
    await tester.tap(find.text('中枢'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(HubPage))).brightness,
      Brightness.light,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(TsukuyomiApp(controller: c, loadNative: false));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(RoomPage))).brightness,
      Brightness.light,
    );
    expect(tester.takeException(), isNull);
  });

  for (final save in [false, true]) {
    testWidgets(
      'settings Room action returns through multiple routes (save=$save)',
      (tester) async {
        final (c, _) = await mount(tester);
        Navigator.of(tester.element(find.byType(RoomPage))).pushNamed('/stage');
        await tester.pumpAndSettle();
        Navigator.of(tester.element(find.byType(SitePage)))
            .pushNamed('/room/settings');
        await tester.pumpAndSettle();
        if (save) {
          final model = find.widgetWithText(TextField, '模型 Model');
          await tester.ensureVisible(model);
          await tester.enterText(model, 'saved-model');
          await tester.pump();
          await tester.tap(find.text('保存并进入房间'));
        } else {
          await tester.tap(find.text('返回房间').first);
        }
        await tester.pumpAndSettle();
        expect(find.byType(RoomPage), findsOneWidget);
        expect(find.byType(SitePage), findsNothing);
        expect(find.byType(RoomSettingsPage), findsNothing);
        if (save) expect(c.settings.model, 'saved-model');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
