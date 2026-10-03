import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/site_widgets.dart';
import 'package:tsukuyomi_space_app/main.dart';

import 'support/fakes.dart';
import 'support/site_capture_fonts.dart';

// Sanitized responses from the original Express/SQLite disposable fixture,
// rather than a catch-all success response that could conceal missing APIs.
class UiContractSite extends FakeSite implements SiteDataService {
  UiContractSite(this.snapshot);
  final Map<String, dynamic> snapshot;
  final missing = <String>[];
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final key = Uri.parse(path).path
        .replaceFirst(RegExp(r'^/api/live/\d+/'), '/api/')
        .replaceFirst(
          RegExp(r'^/api/user/articles/live/\d+$'),
          '/api/user/articles',
        );
    final value = snapshot[key];
    if (value == null) {
      missing.add('$method $path');
      throw StateError('UI contract missing: $method $path');
    }
    if ((value['status'] as num) >= 400) {
      throw ApiFailure('${value['result']['error']}', status: value['status']);
    }
    return Map<String, dynamic>.from(
      jsonDecode(jsonEncode(value['result'])) as Map,
    );
  }
}

void main() {
  final contracts = jsonDecode(
    File('test/fixtures/site_ui_contracts.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final articleId = contracts['_meta']['articleId'];
  final routes = [
    '/room',
    '/room/settings',
    '/live2d',
    '/hub',
    '/stage',
    '/plaza',
    '/growth',
    '/user',
    '/users/e2e-user',
    '/conversations',
    '/notifications',
    '/wiki',
    '/wiki/characters/yachiyo',
    '/wiki/terms/tsukuyomi',
    '/gallery',
    '/gallery/manage',
    '/pixel',
    '/friend-links',
    '/friend-links/apply',
    '/reality',
    '/editor',
    '/attachments',
    '/admin',
    '/terminal',
    '/game',
    '/login',
    '/register',
    '/articles/$articleId',
  ];
  for (final width in [360.0, 390.0, 768.0, 1280.0, 1920.0]) {
    for (final language in ['zh', 'ja', 'en']) {
      for (final theme in ['dark', 'light']) {
        testWidgets('all site surfaces at $width / $language / $theme', (
          tester,
        ) async {
          if (const bool.fromEnvironment('CAPTURE_UI_MATRIX')) {
            await tester.runAsync(loadSiteCaptureFonts);
          }
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = language == 'en'
              ? 2
              : 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          for (final path in routes) {
            final site = UiContractSite(contracts);
            final store = MemoryStorage()
              ..value = const RoomSettings(siteUrl: 'http://127.0.0.1:4184');
            store.drafts['app-theme'] = theme;
            store.drafts['site-language'] = language;
            final room = RoomController(
              storage: store,
              site: site,
              chat: FakeChat(),
              voice: SilentVoice(),
            );
            await room.initialize();
            if (path != '/login' && path != '/register') {
              room.account = Account(
                'e2e-user-001',
                'e2e-user',
                role: ['/admin', '/terminal'].contains(path) ? 'admin' : 'user',
              );
              site.userId = room.account!.id;
              site.cookie = 'tsukuyomi_session=ui.fixture';
            }
            try {
              await tester.pumpWidget(
                RepaintBoundary(
                  key: const Key('ui-matrix'),
                  child: TsukuyomiApp(
                    controller: room,
                    initialPath: path,
                    loadNative: false,
                  ),
                ),
              );
              if (const bool.fromEnvironment('CAPTURE_UI_MATRIX')) {
                await tester.runAsync(() async {
                  final context = tester.element(
                    find.byType(MaterialApp).first,
                  );
                  for (final asset in [
                    'assets/images/wiki_wiki-hero-original.webp',
                    'assets/images/tsukuyomi-bg.webp',
                  ]) {
                    await precacheImage(AssetImage(asset), context);
                  }
                });
              }
              if (path == '/game') {
                for (var frame = 0; frame < 8; frame++) {
                  await tester.pump(const Duration(milliseconds: 100));
                }
              } else {
                await tester.pumpAndSettle(
                  const Duration(milliseconds: 100),
                  EnginePhase.sendSemanticsUpdate,
                  const Duration(seconds: 20),
                );
              }
              expect(
                tester.takeException(),
                isNull,
                reason: '$path / $width / $language / $theme',
              );
              expect(
                site.missing,
                isEmpty,
                reason: '$path missing a real API contract',
              );
              if (!['/login', '/register', '/game', '/live2d'].contains(path)) {
                expect(
                  find.byType(SiteHeader),
                  findsOneWidget,
                  reason: '$path shared navigation',
                );
              }
              if (const bool.fromEnvironment('CAPTURE_UI_MATRIX') &&
                  language == 'zh' &&
                  ((width == 1280 && theme == 'dark') ||
                      (width == 390 && theme == 'light'))) {
                final boundary = tester.renderObject<RenderRepaintBoundary>(
                  find.byKey(const Key('ui-matrix')),
                );
                await tester.runAsync(() async {
                  final image = await boundary.toImage(pixelRatio: 1);
                  try {
                    final bytes = await image.toByteData(
                      format: ui.ImageByteFormat.png,
                    );
                    final output = File(
                      '${const String.fromEnvironment('UI_CAPTURE_DIR', defaultValue: 'artifacts/ui-parity-2026-10-03')}/matrix/${path.substring(1).replaceAll('/', '-')}-${width.toInt()}-$theme.png',
                    );
                    await output.parent.create(recursive: true);
                    await output.writeAsBytes(
                      bytes!.buffer.asUint8List(
                        bytes.offsetInBytes,
                        bytes.lengthInBytes,
                      ),
                    );
                  } finally {
                    image.dispose();
                  }
                });
              }
              // Scroll the body as well as checking its first screen. Toolbars,
              // bottom actions and long forms frequently overflow below the fold.
              final scrolls = find.byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              );
              if (scrolls.evaluate().isNotEmpty && path != '/game') {
                await tester.drag(scrolls.first, const Offset(0, -600));
                await tester.pumpAndSettle();
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '$path scrolled / $width / $language / $theme',
                );
              }
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              room.dispose();
            }
          }
        }, timeout: const Timeout(Duration(minutes: 3)));
      }
    }
  }
}
