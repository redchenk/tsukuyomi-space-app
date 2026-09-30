import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/locale_controller.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/native_gallery_details.dart';

import 'support/fakes.dart';

class _LevelSite extends FakeSite implements SiteDataService {
  final paths = <String>[];
  Completer<Map<String, dynamic>>? delayed;
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    expect(method, 'GET');
    paths.add(path);
    if (delayed != null) return delayed!.future;
    return {
      'success': true,
      'data': [
        {'userId': 'a', 'level': 7},
        {'userId': 'b', 'level': 99},
        {'userId': 'not-requested', 'level': 9},
      ],
    };
  }
}

Future<RoomController> _room(_LevelSite site) async {
  final room = RoomController(
    storage: MemoryStorage(),
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await room.initialize();
  return room;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('gallery tries preview then original once and limits cookies to its own origin', () {
    const site = 'https://example.com';
    expect(
      galleryImageUrls({
        'preview_url': '/preview',
        'access_url': '/original',
        'url': '/other',
      }, site),
      ['https://example.com/preview', 'https://example.com/original'],
    );
    expect(
      galleryImageUrls({'preview_url': '/same', 'access_url': '/same'}, site),
      ['https://example.com/same'],
    );
    expect(galleryImageUrls({'url': 'javascript:alert(1)'}, site), isEmpty);
    expect(galleryMediaHeaders('/image', site, 'session'), {
      'Cookie': 'session',
    });
    expect(
      galleryMediaHeaders('https://cdn.example.com/image', site, 'session'),
      isNull,
    );
  });
  test(
    'gallery uploader uses HTTPS avatar or a versioned public user route',
    () {
      const site = 'https://example.com';
      expect(
        galleryUploaderAvatar({
          'owner_avatar_url': 'https://cdn.example.com/avatar',
        }, site),
        'https://cdn.example.com/avatar',
      );
      expect(
        galleryUploaderAvatar({
          'owner_username': '雪 月',
          'owner_has_avatar': true,
          'owner_avatar_url': 'http://untrusted.example/avatar',
          'owner_avatar_updated_at': '2026-09-30 12:00',
        }, site),
        'https://example.com/api/user/public/%E9%9B%AA%20%E6%9C%88/avatar?v=2026-09-30%2012%3A00',
      );
      expect(galleryUploaderAvatar({'owner_username': 'alice'}, site), '');
      expect(galleryUploaderName({'owner_username': '  '}), '站点归档');
    },
  );
  test('public levels coalesce sorted IDs, reject invalid IDs, clamp values and expire after five minutes', () async {
    final site = _LevelSite(), room = await _room(site);
    addTearDown(room.dispose);
    var now = DateTime(2026);
    final levels = NativePublicUserLevels(room, now: () => now);
    await Future.wait([
      levels.hydrate(['b', 'a', 'a', 'bad?id', null]),
      levels.hydrate(['a', 'b']),
    ]);
    expect(site.paths, ['/api/growth/public?ids=a%2Cb']);
    expect(levels.level('a'), 7);
    expect(levels.level('b'), 9);
    expect(levels.level('not-requested'), 1);
    await levels.hydrate(['a']);
    expect(site.paths, hasLength(1));
    now = now.add(const Duration(minutes: 5, milliseconds: 1));
    await levels.hydrate(['a']);
    expect(site.paths, hasLength(2));
    room.settings = room.settings.copyWith(
      siteUrl: 'https://different.example',
    );
    await levels.hydrate([]);
    expect(levels.level('a'), 1);
  });
  test(
    'late public level response cannot populate another site cache',
    () async {
      final site = _LevelSite(), room = await _room(site);
      addTearDown(room.dispose);
      final levels = NativePublicUserLevels(room);
      site.delayed = Completer();
      final old = levels.hydrate(['a']);
      room.settings = room.settings.copyWith(
        siteUrl: 'https://different.example',
      );
      await levels.hydrate([]);
      site.delayed!.complete({
        'success': true,
        'data': [
          {'userId': 'a', 'level': 9},
        ],
      });
      await old;
      expect(levels.level('a'), 1);
    },
  );
  testWidgets('level badge keeps the original level titles in Japanese', (
    tester,
  ) async {
    final locale = LocaleController(MemoryStorage());
    addTearDown(locale.dispose);
    await locale.setLanguage('ja');
    await tester.pumpWidget(
      SiteLocaleScope(
        controller: locale,
        child: const MaterialApp(
          home: Scaffold(body: NativeUserLevelBadge(level: 7)),
        ),
      ),
    );
    expect(find.text('Lv.7'), findsOneWidget);
    expect(find.text('月の眷属'), findsOneWidget);
    expect(find.byTooltip('レベル 7、月の眷属'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
