import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/locale_controller.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/asset_library_page.dart';

import 'support/fakes.dart';

Map<String, dynamic> _asset(String id) => {
  'id': id,
  'mime_type': 'image/png',
  'owner_username': 'alice',
  'owner_nickname': '月下的创作者',
  'created_at': '2026-10-02T00:00:00Z',
  'metadata': {
    'title': 'Moon $id.png',
    'tags': ['月读', '星空'],
    'width': 1920,
    'height': 1080,
  },
};

Map<String, dynamic> _list(List<Map<String, dynamic>> assets) => {
  'success': true,
  'data': {
    'assets': assets,
    'pagination': {'page': 1, 'totalPages': 2, 'total': 24},
  },
};

class _GallerySite extends FakeSite implements SiteDataService {
  final requests = <Uri>[];
  Completer<Map<String, dynamic>>? delayedWallpapers;
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = Uri.parse(path);
    requests.add(uri);
    if (uri.path == '/api/user/profile') {
      return {
        'success': true,
        'data': {'role': 'user'},
      };
    }
    if (uri.path == '/api/assets/gallery/public') {
      return _list([_asset('random')]);
    }
    if (uri.path != '/api/assets/gallery') {
      throw StateError('Unexpected API $path');
    }
    if (uri.queryParameters['category'] == 'wallpaper' &&
        delayedWallpapers != null) {
      return delayedWallpapers!.future;
    }
    return _list([for (var i = 1; i <= 4; i++) _asset('$i')]);
  }
}

Future<({_GallerySite site, RoomController room})> _mount(
  WidgetTester tester, {
  double width = 1280,
  String language = 'zh',
  double scale = 1,
  bool manage = false,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final site = _GallerySite();
  final room = RoomController(
    storage: MemoryStorage(),
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await room.initialize();
  if (manage) await room.login('alice', 'password');
  final locale = LocaleController(MemoryStorage());
  await locale.setLanguage(language);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    room.dispose();
    locale.dispose();
  });
  await tester.pumpWidget(
    SiteLocaleScope(
      controller: locale,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: AssetLibraryPage(
          controller: room,
          path: manage ? '/gallery/manage' : '/gallery',
          gallery: true,
          onGo: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (site: site, room: room);
}

Future<void> _tap(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'gallery filters, tags, search and sort use source API and reset page',
    (tester) async {
      final (:site, :room) = await _mount(tester);
      expect(site.requests, hasLength(1));
      expect(site.requests.single.queryParameters, {
        'page': '1',
        'limit': '12',
        'search': '',
        'category': '',
        'sort': 'latest',
      });
      await _tap(tester, const Key('gallery-filter-wallpaper'));
      expect(site.requests.last.queryParameters['category'], 'wallpaper');
      expect(site.requests.last.queryParameters['search'], '');
      await tester.enterText(find.byKey(const Key('gallery-search')), 'moon');
      await _tap(tester, const Key('gallery-search-submit'));
      expect(site.requests.last.queryParameters['search'], 'moon');
      expect(site.requests.last.queryParameters['category'], 'wallpaper');
      await _tap(tester, const Key('gallery-sort'));
      await tester.tap(find.text('最早上传').last);
      await tester.pumpAndSettle();
      expect(site.requests.last.queryParameters['sort'], 'oldest');
      await _tap(tester, const Key('gallery-tags'));
      await tester.tap(find.text('八千代').last);
      await tester.pumpAndSettle();
      expect(site.requests.last.queryParameters['search'], '八千代');
      expect(site.requests.last.queryParameters['category'], '');
      expect(site.requests.last.queryParameters['page'], '1');
      expect(room.account, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'random browsing happens only on demand and does not masquerade as list position',
    (tester) async {
      final (:site, :room) = await _mount(tester);
      final requests = site.requests.length;
      await tester.pump(const Duration(minutes: 2));
      expect(site.requests, hasLength(requests));
      await _tap(tester, const Key('gallery-random'));
      expect(site.requests.last.path, '/api/assets/gallery/public');
      expect(site.requests.last.queryParameters['random'], '1');
      expect(find.byKey(const Key('gallery-viewer')), findsOneWidget);
      expect(find.byKey(const Key('gallery-viewer-next')), findsNothing);
      expect(find.text('Moon random'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gallery-viewer')), findsNothing);
      expect(room.account, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late gallery filter response cannot replace a newer selection', (
    tester,
  ) async {
    final (:site, :room) = await _mount(tester);
    site.delayedWallpapers = Completer();
    await tester.tap(find.byKey(const Key('gallery-filter-wallpaper')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('gallery-filter-screenshot')));
    await tester.pumpAndSettle();
    site.delayedWallpapers!.complete(_list([_asset('stale')]));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('gallery-card-stale')), findsNothing);
    expect(find.byKey(const Key('gallery-card-1')), findsOneWidget);
    expect(room.account, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'gallery preview wraps with arrows and keyboard, closes with Escape and restores focus',
    (tester) async {
      await _mount(tester);
      final trigger = find.byKey(const Key('gallery-preview-1'));
      await tester.ensureVisible(trigger);
      final focus = Focus.of(
        tester.element(
          find
              .descendant(of: trigger, matching: find.byType(AspectRatio))
              .first,
        ),
      );
      focus.requestFocus();
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      expect(find.text('1920 × 1080'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '下载'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('gallery-viewer-title'))).data,
        'Moon 4',
      );
      await _tap(tester, const Key('gallery-viewer-next'));
      expect(
        tester.widget<Text>(find.byKey(const Key('gallery-viewer-title'))).data,
        'Moon 1',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('gallery-viewer-title'))).data,
        'Moon 2',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gallery-viewer')), findsNothing);
      expect(focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account logout dismisses private gallery preview and clears its image cards',
    (tester) async {
      final (:site, :room) = await _mount(tester, manage: true);
      expect(site.requests.last.queryParameters['scope'], 'mine');
      await _tap(tester, const Key('gallery-preview-1'));
      await room.logout();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gallery-viewer')), findsNothing);
      expect(find.byKey(const Key('gallery-card-1')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'gallery column controls switch four and three column layouts locally',
    (tester) async {
      final (:site, :room) = await _mount(tester, width: 1440);
      expect(find.byKey(const Key('gallery-grid-4')), findsOneWidget);
      final requests = site.requests.length;
      await _tap(tester, const Key('gallery-columns-3'));
      expect(find.byKey(const Key('gallery-grid-3')), findsOneWidget);
      await _tap(tester, const Key('gallery-columns-4'));
      expect(find.byKey(const Key('gallery-grid-4')), findsOneWidget);
      expect(site.requests, hasLength(requests));
      expect(room.account, isNull);
    },
  );

  for (final config in [
    (320.0, 'zh', 1.0),
    (390.0, 'en', 2.0),
    (768.0, 'ja', 2.0),
    (1280.0, 'en', 1.0),
    (1920.0, 'ja', 1.0),
  ]) {
    testWidgets(
      'gallery and preview fit ${config.$1} ${config.$2} font ${config.$3}',
      (tester) async {
        await _mount(
          tester,
          width: config.$1,
          language: config.$2,
          scale: config.$3,
        );
        expect(tester.takeException(), isNull);
        await _tap(tester, const Key('gallery-preview-1'));
        expect(tester.takeException(), isNull);
        await _tap(tester, const Key('gallery-viewer-next'));
        expect(tester.takeException(), isNull);
        await _tap(tester, const Key('gallery-viewer-close'));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
