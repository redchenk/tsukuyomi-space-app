import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/site_chrome.dart';

import 'support/fakes.dart';

class _ViewSite extends FakeSite implements SiteDataService {
  final views = <({String site, String method, Map<String, dynamic>? body})>[];
  bool fail = false;
  Completer<Map<String, dynamic>>? delayed;
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path == '/api/stats/view') {
      views.add((site: site, method: method, body: body));
      if (fail) throw const ApiFailure('offline', status: 503);
      if (delayed != null) return delayed!.future;
      return {
        'success': true,
        'data': {'todayViews': 12},
      };
    }
    return {
      'success': true,
      'data': path == '/api/settings' ? {} : {'count': 0},
    };
  }
}

Future<RoomController> _room(_ViewSite site, {MemoryStorage? storage}) async {
  final room = RoomController(
    storage: storage ?? MemoryStorage(),
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await room.initialize();
  return room;
}

http.Response _response({String? setCookie, Map<String, dynamic>? data}) =>
    http.Response(
      jsonEncode({'success': true, 'data': data ?? {}}),
      200,
      headers: {'content-type': 'application/json', 'set-cookie': ?setCookie},
    );

const _visitor = 'tsukuyomi_visitor=7e141183-3081-4b57-94c3-b9b9d4043e58';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('daily visit uses Hong Kong midnight and account scope, independently of admin role', () async {
    final room = await _room(_ViewSite());
    var now = DateTime.utc(2026, 9, 29, 15, 59, 59);
    final chrome = SiteChromeController(room, now: () => now);
    addTearDown(() {
      chrome.dispose();
      room.dispose();
    });
    expect(chrome.dailyViewMarker, '2026-09-29:visitor');
    now = DateTime.utc(2026, 9, 29, 16);
    expect(chrome.dailyViewMarker, '2026-09-30:visitor');
    room.account = const Account('alice', 'alice', role: 'super_admin');
    expect(chrome.dailyViewMarker, '2026-09-30:user:alice');
    room.account = const Account(
      'admin-1',
      'staff',
      scope: 'admin',
      role: 'admin',
    );
    expect(chrome.dailyViewMarker, '2026-09-30:admin:admin-1');
    room.sessionExpired = true;
    expect(chrome.dailyViewMarker, '2026-09-30:visitor');
  });
  test('concurrent visit records coalesce and a persisted same-day marker survives restart', () async {
    final site = _ViewSite(), storage = MemoryStorage();
    final room = await _room(site, storage: storage);
    final chrome = SiteChromeController(
      room,
      initialPath: '/plaza?topic=moon#message-42',
      now: () => DateTime.utc(2026, 9, 30),
    );
    chrome.setVisible(true);
    addTearDown(() {
      chrome.dispose();
      room.dispose();
    });
    site.delayed = Completer();
    final first = chrome.recordDailyView(), second = chrome.recordDailyView();
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(site.views, hasLength(1));
    expect(site.views.single.method, 'POST');
    expect(site.views.single.body, {'path': '/plaza?topic=moon#message-42'});
    site.delayed!.complete({
      'success': true,
      'data': {'todayViews': 12},
    });
    await first;
    expect(chrome.publicStats, {'todayViews': 12});
    expect(
      await storage.draft(SiteChromeController.viewStorageKey(chrome.origin)),
      '2026-09-30:visitor',
    );
    expect(await chrome.recordDailyView(), isNull);
    final restarted = SiteChromeController(
      room,
      now: () => DateTime.utc(2026, 9, 30),
    );
    restarted.setVisible(true);
    addTearDown(restarted.dispose);
    expect(await restarted.recordDailyView(), isNull);
    expect(site.views, hasLength(1));
  });
  test('failed visit leaves no marker, retries on the next event and records a later Hong Kong day', () async {
    final site = _ViewSite(), room = await _room(site);
    var now = DateTime.utc(2026, 9, 30, 15, 59);
    final chrome = SiteChromeController(room, now: () => now);
    chrome.setVisible(true);
    addTearDown(() {
      chrome.dispose();
      room.dispose();
    });
    site.fail = true;
    expect(await chrome.recordDailyView(), isNull);
    expect(
      await room.storage.draft(
        SiteChromeController.viewStorageKey(chrome.origin),
      ),
      '',
    );
    site.fail = false;
    expect(await chrome.recordDailyView(), isNotNull);
    expect(site.views, hasLength(2));
    now = DateTime.utc(2026, 9, 30, 16);
    expect(await chrome.recordDailyView(), isNotNull);
    expect(site.views, hasLength(3));
    expect(
      await room.storage.draft(
        SiteChromeController.viewStorageKey(chrome.origin),
      ),
      '2026-10-01:visitor',
    );
    chrome.setVisible(false);
    room.account = const Account('a', 'a');
    expect(await chrome.recordDailyView(), isNull);
    expect(site.views, hasLength(3));
  });
  test(
    'identity and origin changes cannot persist an older late visit marker',
    () async {
      final site = _ViewSite(), room = await _room(site);
      final chrome = SiteChromeController(
        room,
        now: () => DateTime.utc(2026, 9, 30),
      );
      chrome.setVisible(true);
      addTearDown(() {
        chrome.dispose();
        room.dispose();
      });
      site.delayed = Completer();
      final oldOrigin = chrome.origin;
      final pending = chrome.recordDailyView();
      await Future<void>.delayed(Duration.zero);
      room.settings = room.settings.copyWith(
        siteUrl: 'https://different.example',
      );
      site.delayed!.complete({
        'success': true,
        'data': {'todayViews': 99},
      });
      await pending;
      expect(
        await room.storage.draft(
          SiteChromeController.viewStorageKey(oldOrigin),
        ),
        '',
      );
      expect(chrome.publicStats, isEmpty);
      site.delayed = null;
      room.account = const Account('b', 'b');
      await chrome.recordDailyView();
      expect(
        await room.storage.draft(
          SiteChromeController.viewStorageKey(chrome.origin),
        ),
        '2026-09-30:user:b',
      );
      expect(site.views.last.site, 'https://different.example');
    },
  );
  test('start waits for initialized cookies and identity, then account and route events retry failures', () async {
    final site = _ViewSite(),
        room = RoomController(
          storage: MemoryStorage(),
          site: site,
          chat: FakeChat(),
          voice: SilentVoice(),
        );
    final chrome = SiteChromeController(room, initialPath: '/hub');
    chrome.setVisible(true);
    addTearDown(() {
      chrome.dispose();
      room.dispose();
    });
    chrome.start();
    await chrome.recordDailyView();
    expect(site.views, isEmpty);
    await room.initialize();
    await chrome.recordDailyView();
    expect(site.views, hasLength(1));
    expect(site.views.single.body, {'path': '/hub'});
    site.fail = true;
    await room.login('alice', 'password');
    await chrome.recordDailyView();
    final failed = site.views.length;
    site.fail = false;
    await chrome.routeChanged('/stage?search=Moon');
    await chrome.recordDailyView();
    expect(site.views.length, failed + 1);
    expect(site.views.last.body, {'path': '/stage?search=Moon'});
    await room.logout();
    await chrome.recordDailyView();
    expect(site.views.last.body, {'path': '/stage?search=Moon'});
  });
  test('visitor Cookie restores securely, is scoped to the origin and survives logout', () async {
    const origin = 'https://example.com';
    final storage = MemoryStorage()
      ..value = const RoomSettings(siteUrl: origin)
      ..secrets['visitor.$origin'] = _visitor;
    final headers = <String?>[];
    final site = SiteClient(
      client: MockClient((request) async {
        headers.add(request.headers['cookie']);
        return _response(setCookie: _visitor);
      }),
    );
    final room = RoomController(
      storage: storage,
      site: site,
      chat: FakeChat(),
      voice: SilentVoice(),
    );
    addTearDown(room.dispose);
    await room.initialize();
    await site.request(origin, 'POST', '/api/stats/view', {'path': '/'});
    expect(headers.last, _visitor);
    expect(site.cookie, isNull);
    await site.logout(origin);
    expect(site.visitorCookies[origin], _visitor);
    await site.request('https://other.example', 'POST', '/api/stats/view', {
      'path': '/',
    });
    expect(headers.last, isNull);
    await Future<void>.delayed(Duration.zero);
    expect(storage.secrets['visitor.https://other.example'], _visitor);
  });
  test(
    'visitor-only Set-Cookie never grants an authenticated session',
    () async {
      final site = SiteClient(
        client: MockClient(
          (_) async => _response(
            setCookie: _visitor,
            data: {
              'user': {'id': 'a', 'username': 'a'},
            },
          ),
        ),
      );
      addTearDown(site.dispose);
      await expectLater(
        site.authenticate('https://example.com', {
          'username': 'a',
          'password': 'p',
        }),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.message,
            'message',
            contains('未返回会话'),
          ),
        ),
      );
      expect(site.cookie, isNull);
      expect(site.visitorCookies['https://example.com'], _visitor);
    },
  );
  test('a late account response keeps only the public visitor Cookie and rejects stale session data', () async {
    final pending = Completer<http.Response>();
    final site = SiteClient(client: MockClient((_) => pending.future));
    addTearDown(site.dispose);
    final request = site.request(
      'https://example.com',
      'POST',
      '/api/stats/view',
      {'path': '/'},
    );
    site.cookie = 'tsukuyomi_session=new';
    pending.complete(
      _response(
        setCookie:
            '$_visitor; Expires=Wed, 04 Nov 2027 10:00:00 GMT; Path=/, tsukuyomi_session=old; Path=/',
      ),
    );
    await expectLater(
      request,
      throwsA(isA<ApiFailure>().having((e) => e.status, 'HTTP', 409)),
    );
    expect(site.cookie, 'tsukuyomi_session=new');
    expect(site.visitorCookies['https://example.com'], _visitor);
  });
}
