import 'support/site_fixture.dart';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/site_chrome.dart';

import 'support/fakes.dart';

const _origin = siteFixtureOrigin;
bool get _enabled =>
    Platform.environment['RUN_SITE_FIXTURE'] == '1' ||
    const bool.fromEnvironment('RUN_SITE_FIXTURE');

class _FixtureClient extends http.BaseClient {
  _FixtureClient(this.userAgent);
  final String userAgent;
  final inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.origin != _origin) {
      throw StateError('Only the disposable fixture is allowed');
    }
    request.headers['User-Agent'] = userAgent;
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

RoomController _room(MemoryStorage storage, String agent) => RoomController(
  storage: storage,
  site: SiteClient(client: _FixtureClient(agent)),
  chat: FakeChat(),
  voice: SilentVoice(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousOverrides = HttpOverrides.current;
  setUp(() => HttpOverrides.global = null);
  tearDown(() => HttpOverrides.global = previousOverrides);
  test('real backend visitor Cookie, restart, lost marker and login/logout stay one unique daily visit', () async {
    final storage = MemoryStorage()
      ..value = const RoomSettings(siteUrl: _origin);
    final agent =
        'native-visit-fixture-${DateTime.now().microsecondsSinceEpoch}';
    final firstRoom = _room(storage, agent);
    await firstRoom.initialize();
    final firstChrome = SiteChromeController(firstRoom, initialPath: '/hub');
    firstChrome.setVisible(true);
    String visitor;
    int today;
    try {
      final first = await firstChrome.recordDailyView();
      expect(first, isNotNull);
      expect(first!['recorded'], isTrue);
      today = (first['data'] as Map)['todayViews'] as int;
      visitor = (firstRoom.site as SiteClient).visitorCookies[_origin]!;
      expect(
        visitor,
        matches(RegExp(r'^tsukuyomi_visitor=[A-Za-z0-9_-]{20,128}$')),
      );
      await Future<void>.delayed(Duration.zero);
      expect(storage.secrets['visitor.$_origin'], visitor);
    } finally {
      firstChrome.dispose();
      firstRoom.dispose();
    }
    final secondRoom = _room(storage, agent);
    await secondRoom.initialize();
    final secondChrome = SiteChromeController(
      secondRoom,
      initialPath: '/stage',
    );
    secondChrome.setVisible(true);
    try {
      expect((secondRoom.site as SiteClient).visitorCookies[_origin], visitor);
      expect(await secondChrome.recordDailyView(), isNull);
      final stats = await (secondRoom.site as SiteDataService).request(
        _origin,
        'GET',
        '/api/stats',
      );
      expect((stats['data'] as Map)['todayViews'], today);
    } finally {
      secondChrome.dispose();
    }
    await storage.saveDraft(SiteChromeController.viewStorageKey(_origin), '');
    final restartedChrome = SiteChromeController(
      secondRoom,
      initialPath: '/plaza',
    );
    restartedChrome.setVisible(true);
    try {
      final repeated = await restartedChrome.recordDailyView();
      expect(repeated!['deduped'], isTrue);
      expect((repeated['data'] as Map)['todayViews'], today);
      await secondRoom.login('e2e-user', 'e2e-password');
      final signedIn = await restartedChrome.recordDailyView();
      expect(signedIn!['deduped'], isTrue);
      expect((signedIn['data'] as Map)['todayViews'], today);
      expect(
        await storage.draft(SiteChromeController.viewStorageKey(_origin)),
        endsWith(':user:${secondRoom.account!.id}'),
      );
      await secondRoom.logout();
      final signedOut = await restartedChrome.recordDailyView();
      expect(signedOut!['deduped'], isTrue);
      expect((signedOut['data'] as Map)['todayViews'], today);
      expect((secondRoom.site as SiteClient).visitorCookies[_origin], visitor);
    } finally {
      restartedChrome.dispose();
      secondRoom.dispose();
    }
  }, skip: !_enabled);
}
