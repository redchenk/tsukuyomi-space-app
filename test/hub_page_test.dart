import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_theme.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/hub_page.dart';
import 'package:tsukuyomi_space_app/features/site/hub_pixel_preview.dart';

import 'support/fakes.dart';

typedef HubRequest = Future<Map<String, dynamic>> Function(
  String method,
  String path,
  Map<String, dynamic>? body,
);

class HubSite extends FakeSite implements SiteDataService {
  HubSite(this.handle);
  final HubRequest handle;
  final calls = <String>[];

  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) {
    calls.add('$method $path');
    return handle(method, path, body);
  }
}

Map<String, dynamic> preview({
  String title = '月下故事',
  String message = '今晚的问候',
}) => {
  'success': true,
  'data': {
    'article': {
      'id': 42,
      'title': title,
      'excerpt': '来自源站的最新文章',
      'category': '传说',
    },
    'gallery': {'id': 7, 'created_at': '2026-09-30T00:00:00Z'},
    'pixel': {
      'id': 8,
      'title': '月光像素',
      'author': 'Alice',
      'width': 2,
      'height': 2,
      'palette': ['#fff', '#aef2ff'],
      'pixels_base64': base64Encode([1, 2, 0, 1]),
    },
    'messages': [
      {'id': 9, 'author': 'Alice', 'content': message},
      {'id': 10, 'author': 'Bob', 'content': '明天见'},
      {'id': 11, 'author': 'Carol', 'content': '你好'},
      {'id': 12, 'author': 'Dave', 'content': '第四条不出现在预览'},
    ],
    'stats': {
      'todayViews': 31,
      'totalViews': 1234,
      'users': 17,
      'articles': 2,
      'messages': 4,
      'uptime': 90000,
    },
  },
};

const publicSettings = <String, dynamic>{
  'success': true,
  'data': {'visitPopupTitle': '九月公告', 'visitPopupContent': '源站的公告正文'},
};

Future<RoomController> controller(
  HubSite site, {
  MemoryStorage? storage,
}) async {
  final c = RoomController(
    storage: storage ?? MemoryStorage(),
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await c.initialize();
  return c;
}

Future<void> mount(
  WidgetTester tester,
  RoomController c, [
  ValueChanged<String>? onGo,
]) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HubPage(controller: c, onGo: onGo ?? (_) {}),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Room workspace notifications keep Hub preview widgets stable', (
    tester,
  ) async {
    final site = HubSite(
      (method, path, body) async =>
          path == '/api/settings' ? publicSettings : preview(),
    );
    final c = await controller(site);
    addTearDown(c.dispose);
    await mount(tester, c);
    final before = tester.widget<HubPixelPreview>(find.byType(HubPixelPreview));
    final calls = List.of(site.calls);
    for (var i = 0; i < 30; i++) {
      c.workspace.changed();
      await tester.pump();
    }
    expect(
      tester.widget<HubPixelPreview>(find.byType(HubPixelPreview)),
      same(before),
    );
    expect(site.calls, calls);
    // The same page must still react to real account changes.
    await c.login('bob', 'test');
    await tester.pumpAndSettle();
    expect(
      site.calls.where((call) => call == 'GET /api/hub-preview').length,
      2,
    );
  });

  testWidgets(
    'pixel texture retains transparency and refreshes changed artwork',
    (tester) async {
      final pixels = [0, 1, -1, 0];
      final artwork = <String, dynamic>{
        'id': 9,
        'width': 2,
        'height': 2,
        'background_color': '#112233',
        'palette': ['#fff', '#aef2ff'],
        'pixels': pixels,
      };
      Future<ui.Image> render(
        Map<String, dynamic> value, {
        ui.Image? replacing,
      }) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 20,
              height: 20,
              child: HubPixelPreview(artwork: value),
            ),
          ),
        );
        final imageFinder = find.descendant(
          of: find.byType(HubPixelPreview),
          matching: find.byType(RawImage),
        );
        for (var i = 0; i < 200; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          final image = tester.widget<RawImage>(imageFinder).image;
          // The preview retains its previous texture while decoding. Wait for
          // the new image rather than treating a cached image as completion.
          if (image != null && !identical(image, replacing)) return image;
        }
        throw StateError('Pixel texture did not decode');
      }

      final first = await render(artwork);
      final bytes = await tester.runAsync(
        () => first.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      expect(bytes!.buffer.asUint8List(), [
        255,
        255,
        255,
        255,
        174,
        242,
        255,
        255,
        0,
        0,
        0,
        0,
        255,
        255,
        255,
        255,
      ]);
      final unchanged = await render({...artwork, 'title': '只改变标题'});
      expect(unchanged, same(first));
      pixels[0] = 1;
      final next = await render({...artwork}, replacing: first);
      expect(next, isNot(same(first)));
      final changed = await tester.runAsync(
        () => next.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      expect(changed!.buffer.asUint8List().take(4), [174, 242, 255, 255]);
      expect(
        tester
            .widget<ColoredBox>(
              find.descendant(
                of: find.byType(HubPixelPreview),
                matching: find.byType(ColoredBox),
              ),
            )
            .color,
        const Color(0xff112233),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(tester.takeException(), isNull);
    },
  );

  test('pixel preview decodes the website byte plus one format', () {
    final data = HubPixelData.fromMap({
      'width': 2,
      'height': 2,
      'palette': ['#fff', '#aef2ff'],
      'pixels_base64': base64Encode([1, 2, 0, 1]),
    });
    expect(data.pixels, [0, 1, -1, 0]);
    expect(data.palette.first, Colors.white);
    expect(HubPixelData.fromMap({'pixels_base64': '!invalid'}).pixels, isEmpty);
    final bounded = HubPixelData.fromMap({
      'width': 999999,
      'height': -5,
      'pixels': [1, 2],
    });
    expect(bounded.width, 512);
    expect(bounded.height, 54);
  });

  Future<void> reveal(WidgetTester tester, Finder control) async {
    await Scrollable.ensureVisible(tester.element(control), alignment: .45);
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('native Hub uses website sections without overflow at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final site = HubSite(
        (method, path, body) async =>
            path == '/api/settings' ? publicSettings : preview(),
      );
      final c = await controller(site);
      addTearDown(c.dispose);
      final destinations = <String>[];
      await mount(tester, c, destinations.add);
      expect(find.text('给日常\n留一点月光。'), findsOneWidget);
      expect(find.text('月下故事'), findsOneWidget);
      expect(find.text('光影收藏 ↗'), findsOneWidget);
      expect(find.text('像素里的宇宙 ↗'), findsOneWidget);
      expect(find.text('今晚的问候'), findsOneWidget);
      expect(find.text('第四条不出现在预览'), findsNothing);
      expect(find.byKey(const Key('hub-letter')), findsOneWidget);
      expect(
        site.calls,
        containsAll(['GET /api/hub-preview', 'GET /api/settings']),
      );
      expect(site.calls.any((call) => call.contains('/articles?')), isTrue);
      await reveal(tester, find.byTooltip('带着这句话进入房间'));
      await tester.tap(find.byTooltip('带着这句话进入房间'));
      expect(destinations, ['/room']);
      for (final entry in {
        '月下故事': '/articles/42',
        '光影收藏 ↗': '/gallery',
        '像素里的宇宙 ↗': '/pixel',
      }.entries) {
        await reveal(tester, find.text(entry.key));
        await tester.tap(find.text(entry.key));
        expect(destinations.last, entry.value);
      }
      await reveal(tester, find.text('九月公告'));
      await tester.tap(find.text('九月公告'));
      await tester.pumpAndSettle();
      expect(find.text('源站的公告正文'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Hub retries its preview after a failure', (tester) async {
    var failed = true;
    final site = HubSite((method, path, body) async {
      if (path == '/api/settings') return publicSettings;
      if (failed) throw const ApiFailure('预览读取失败', status: 404);
      return preview();
    });
    final c = await controller(site);
    addTearDown(c.dispose);
    await mount(tester, c);
    expect(find.textContaining('预览读取失败'), findsOneWidget);
    failed = false;
    await reveal(tester, find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('月下故事'), findsOneWidget);
    expect(find.textContaining('预览读取失败'), findsNothing);
    expect(
      site.calls.where((call) => call == 'GET /api/hub-preview').length,
      2,
    );
  });

  testWidgets(
    'Hub carries a private room draft without posting a plaza message',
    (tester) async {
      final site = HubSite(
        (method, path, body) async =>
            path == '/api/settings' ? publicSettings : preview(),
      );
      final c = await controller(site);
      addTearDown(c.dispose);
      final routes = <String>[];
      await mount(tester, c, routes.add);
      final input = find.byKey(const Key('hub-room-draft'));
      await reveal(tester, input);
      await tester.enterText(input, '带进房间的一句话');
      final action = find.byTooltip('带着这句话进入房间');
      await reveal(tester, action);
      await tester.tap(action);
      await tester.pump();
      expect(c.draft, '带进房间的一句话');
      expect(await c.storage.draft(c.scope), c.draft);
      expect(routes, ['/room']);
      expect(site.calls.any((s) => s.startsWith('POST')), isFalse);
    },
  );

  testWidgets('late Hub preview cannot replace the next account response', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    var previews = 0;
    final site = HubSite((method, path, body) async {
      if (path == '/api/settings') return publicSettings;
      if (++previews == 1) return pending.future;
      return preview(title: 'Bob 当前看到的文章');
    });
    final c = await controller(site);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: HubPage(controller: c, onGo: (_) {}),
      ),
    );
    await tester.pump();
    await c.login('bob', 'test');
    await tester.pumpAndSettle();
    expect(find.text('Bob 当前看到的文章'), findsOneWidget);
    pending.complete(preview(title: '迟到的旧文章'));
    await tester.pumpAndSettle();
    expect(find.text('Bob 当前看到的文章'), findsOneWidget);
    expect(find.text('迟到的旧文章'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching identity clears the text entered on Hub', (
    tester,
  ) async {
    final c = await controller(
      HubSite(
        (method, path, body) async =>
            path == '/api/settings' ? publicSettings : preview(),
      ),
    );
    addTearDown(c.dispose);
    await mount(tester, c);
    final field = find.byKey(const Key('hub-room-draft'));
    await reveal(tester, field);
    await tester.enterText(field, 'private draft');
    await c.login('bob', 'test');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
  });

  testWidgets('capture native Hub with system fonts', (tester) async {
    await tester.runAsync(() async {
      final ping =
          Directory('/System/Library/AssetsV2/com_apple_MobileAsset_Font8')
              .listSync(recursive: true)
              .whereType<File>()
              .firstWhere((file) => file.path.endsWith('/PingFang.ttc'));
      final bytes = ByteData.sublistView(await ping.readAsBytes());
      for (final family in ['Roboto', 'PingFang SC']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
      await (FontLoader('Songti SC')..addFont(
            Future.value(
              ByteData.sublistView(
                await File('/System/Library/Fonts/Supplemental/Songti.ttc')
                    .readAsBytes(),
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
    for (final size in [
      const Size(360, 844),
      const Size(390, 844),
      const Size(768, 900),
      const Size(1280, 900),
      const Size(1920, 1080),
    ]) {
      for (final dark in [false, true]) {
        tester.view.physicalSize = size;
        final site = HubSite(
          (method, path, body) async =>
              path == '/api/settings' ? publicSettings : preview(),
        );
        final c = await controller(site);
        await tester.pumpWidget(
          RepaintBoundary(
            key: const Key('hub-capture'),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: siteTheme(dark),
              home: HubPage(controller: c, onGo: (_) {}),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('hub-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File(
            'artifacts/site-v0610/native-hub-${size.width.toInt()}-${dark ? 'dark' : 'light'}.png',
          );
          await output.parent.create(recursive: true);
          await output.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await reveal(tester, find.byKey(const Key('hub-letter')));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'artifacts/site-v0610/native-hub-footer-${size.width.toInt()}-${dark ? 'dark' : 'light'}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
      }
    }
  }, skip: !const bool.fromEnvironment('CAPTURE_UI'));
}
