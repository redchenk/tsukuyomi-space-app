import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
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
      Future<ui.Image> render(Map<String, dynamic> value) async {
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
        for (var i = 0; i < 50; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          final image = tester.widget<RawImage>(imageFinder).image;
          if (image != null) return image;
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
      final next = await render({...artwork});
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
      expect(find.text('与你相遇，在月光之下'), findsOneWidget);
      expect(find.text('月下故事'), findsOneWidget);
      expect(find.text('最新图库影像'), findsOneWidget);
      expect(find.text('月光像素'), findsOneWidget);
      expect(find.text('今晚的问候'), findsOneWidget);
      expect(find.text('第四条不出现在预览'), findsNothing);
      expect(find.text('1天1时'), findsOneWidget);
      expect(
        site.calls,
        containsAll(['GET /api/hub-preview', 'GET /api/settings']),
      );
      expect(site.calls.any((call) => call.contains('/articles?')), isFalse);
      await tester.tap(find.text('进入私人居所'));
      expect(destinations, ['/room']);
      for (final entry in {
        '月下故事': '/stage',
        '最新图库影像': '/gallery',
        '月光像素': '/pixel',
      }.entries) {
        await tester.ensureVisible(find.text(entry.key));
        await tester.tap(find.text(entry.key));
        expect(destinations.last, entry.value);
      }
      await tester.ensureVisible(find.text('九月公告'));
      await tester.tap(find.text('九月公告'));
      await tester.pumpAndSettle();
      expect(find.text('源站的公告正文'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'Hub failure can be retried and does not fetch article list as a fallback',
    (tester) async {
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
      await tester.ensureVisible(find.text('重试'));
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('月下故事'), findsOneWidget);
      expect(find.textContaining('预览读取失败'), findsNothing);
      expect(
        site.calls.where((call) => call == 'GET /api/hub-preview').length,
        2,
      );
    },
  );

  testWidgets(
    'quick greeting uses the source mutation once and preserves failures',
    (tester) async {
      var fail = true, greeting = '今晚的问候';
      final bodies = <Map<String, dynamic>>[];
      final site = HubSite((method, path, body) async {
        if (path == '/api/settings') return publicSettings;
        if (method == 'POST') {
          expect(path, '/api/messages');
          bodies.add(body!);
          if (fail) throw const ApiFailure('发布失败', status: 500);
          greeting = body['content'] as String;
          return {
            'success': true,
            'data': {'id': 15, 'author': 'Alice', 'content': greeting},
          };
        }
        return preview(message: greeting);
      });
      final c = await controller(site);
      await c.login('alice', 'test');
      addTearDown(c.dispose);
      await mount(tester, c);
      await tester.ensureVisible(find.byKey(const Key('hub-greeting')));
      await tester.enterText(
        find.byKey(const Key('hub-greeting')),
        '  从原生中枢问好  ',
      );
      await tester.ensureVisible(find.byKey(const Key('hub-send')));
      await tester.tap(find.byKey(const Key('hub-send')));
      await tester.pumpAndSettle();
      expect(bodies, [
        {'content': '从原生中枢问好'},
      ]);
      expect(find.textContaining('发布失败'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('hub-greeting')))
            .controller!
            .text,
        '  从原生中枢问好  ',
      );
      fail = false;
      await tester.tap(find.byKey(const Key('hub-send')));
      await tester.pumpAndSettle();
      expect(bodies.length, 2);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('hub-greeting')))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.text('从原生中枢问好'), findsOneWidget);
      expect(find.text('已发布'), findsOneWidget);
    },
  );

  testWidgets(
    'expired Hub session asks for login and preserves the unsent greeting',
    (tester) async {
      final site = HubSite(
        (method, path, body) async =>
            path == '/api/settings' ? publicSettings : preview(),
      );
      final c = await controller(site);
      await c.login('alice', 'test');
      c.expireSession();
      addTearDown(c.dispose);
      await mount(tester, c);
      await tester.ensureVisible(find.byKey(const Key('hub-greeting')));
      await tester.enterText(find.byKey(const Key('hub-greeting')), '尚未发送的问候');
      await tester.ensureVisible(find.byKey(const Key('hub-send')));
      await tester.tap(find.byKey(const Key('hub-send')));
      await tester.pumpAndSettle();
      expect(find.text('欢迎回来'), findsOneWidget);
      expect(
        site.calls.where((call) => call.startsWith('POST /api/messages')),
        isEmpty,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('hub-greeting')))
            .controller!
            .text,
        '尚未发送的问候',
      );
      await tester.pumpWidget(const SizedBox.shrink());
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

  testWidgets(
    'late Hub greeting does not clear the next account draft or feedback',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final site = HubSite((method, path, body) async {
        if (path == '/api/settings') return publicSettings;
        if (method == 'POST') return pending.future;
        return preview();
      });
      final storage = MemoryStorage();
      final c = await controller(site, storage: storage);
      await c.login('alice', 'test');
      addTearDown(c.dispose);
      storage.drafts['hub-greeting:https://yachiyo.hk:bob'] = 'Bob 的草稿';
      await mount(tester, c);
      await tester.ensureVisible(find.byKey(const Key('hub-greeting')));
      await tester.enterText(
        find.byKey(const Key('hub-greeting')),
        'Alice 的留言',
      );
      await tester.ensureVisible(find.byKey(const Key('hub-send')));
      await tester.tap(find.byKey(const Key('hub-send')));
      await tester.pump();
      await c.login('bob', 'test');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('hub-greeting')))
            .controller!
            .text,
        'Bob 的草稿',
      );
      pending.complete({
        'success': true,
        'data': {'id': 15, 'content': 'Alice 的留言'},
      });
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('hub-greeting')))
            .controller!
            .text,
        'Bob 的草稿',
      );
      expect(find.text('已发布'), findsNothing);
      expect(find.text('Alice 的留言'), findsNothing);
    },
  );

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
    for (final size in [const Size(1280, 900), const Size(390, 844)]) {
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
          'artifacts/hub-parity/native-hub-${size.width > 860 ? 'desktop' : 'mobile'}.png',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    }
  }, skip: !const bool.fromEnvironment('CAPTURE_UI'));
}
