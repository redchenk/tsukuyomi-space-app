import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/site_chrome.dart';

import 'support/fakes.dart';

class _ChromeSite extends FakeSite implements SiteDataService {
  int count = 3;
  bool fail = false;
  int reads = 0, settingsReads = 0;
  final unreadRequests = <({String method, String path})>[];
  Completer<Map<String, dynamic>>? delayed;
  Map<String, dynamic> settings = {
    'visitPopupEnabled': true,
    'visitPopupTitle': ' Notice ',
    'visitPopupContent': ' Content ',
    'visitPopupButton': ' Continue ',
    'beianText': 'ICP 123',
    'beianUrl': 'https://beian.miit.gov.cn/',
    'mpsBeianText': 'MPS 456',
  };
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path == '/api/settings') {
      settingsReads++;
      return {'success': true, 'data': Map.of(settings)};
    }
    if (path == '/api/stats/view') {
      return {
        'success': true,
        'data': {'todayViews': 1},
      };
    }
    // Timer callbacks run inside tester.pump's guarded zone. Record the request
    // and assert it in the test body; Flutter's expect cannot nest those guards.
    unreadRequests.add((method: method, path: path));
    reads++;
    if (delayed != null) return delayed!.future;
    if (fail) throw const ApiFailure('offline', status: 503);
    return {
      'success': true,
      'data': {'count': count},
    };
  }
}

Future<RoomController> _room(_ChromeSite site, {bool loggedIn = true}) async {
  final room = RoomController(
    storage: MemoryStorage(),
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await room.initialize();
  if (loggedIn) await room.login('alice', 'password');
  return room;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('visit signature uses raw settings before trimming and the same URI encoding', () {
    expect(
      visitPopupSignature({
        'visitPopupTitle': ' A! ',
        'visitPopupContent': '雪',
        'visitPopupButton': 'OK',
      }),
      '%20A!%20%0A%E9%9B%AA%0AOK',
    );
    expect(visitPopupSignature({}), '%0A%0A');
  });
  test('direct Hub visit has no popup; access transition consumes pending once; close stores signature', () async {
    final site = _ChromeSite();
    final actual = await _room(site);
    final controller = SiteChromeController(actual);
    addTearDown(() {
      controller.dispose();
      actual.dispose();
    });
    await controller.routeChanged('/hub');
    expect(controller.popup, isNull);
    await controller.routeChanged('/');
    await controller.routeChanged('/hub');
    expect(controller.popup!.title, 'Notice');
    expect(controller.popup!.content, 'Content');
    expect(controller.popup!.button, 'Continue');
    expect(controller.pendingVisit, isFalse);
    await controller.closeVisitPopup();
    expect(
      await actual.storage.draft(
        'tsukuyomi_visit_popup_seen:${controller.origin}',
      ),
      visitPopupSignature(site.settings),
    );
    await controller.routeChanged('/');
    await controller.routeChanged('/hub');
    expect(controller.popup, isNull);
    site.settings['visitPopupContent'] = 'Changed';
    await controller.publicSettings(force: true);
    await controller.routeChanged('/access');
    await controller.routeChanged('/hub');
    expect(controller.popup!.content, 'Changed');
  });
  test('disabled or empty visit copy does not show; unchanged fields remain seen across restart', () async {
    final site = _ChromeSite();
    final actual = await _room(site);
    for (final settings in [
      {'visitPopupEnabled': false, 'visitPopupTitle': 'No'},
      {
        'visitPopupEnabled': true,
        'visitPopupTitle': ' ',
        'visitPopupContent': '',
      },
    ]) {
      site.settings = settings;
      final chrome = SiteChromeController(actual);
      await chrome.routeChanged('/');
      await chrome.routeChanged('/hub');
      expect(chrome.popup, isNull);
      expect(chrome.pendingVisit, isFalse);
      chrome.dispose();
    }
    actual.dispose();
  });
  test('public settings cache is shared across callers for 30 seconds and origin-independent from private counts', () async {
    final site = _ChromeSite();
    final actual = await _room(site);
    var now = DateTime(2026);
    final chrome = SiteChromeController(actual, now: () => now);
    addTearDown(() {
      chrome.dispose();
      actual.dispose();
    });
    await Future.wait([chrome.publicSettings(), chrome.publicSettings()]);
    expect(site.settingsReads, 1);
    await chrome.publicSettings();
    expect(site.settingsReads, 1);
    now = now.add(const Duration(seconds: 31));
    await chrome.publicSettings();
    expect(site.settingsReads, 2);
    await chrome.refreshUnread();
    expect(chrome.unread, 3);
    final keys = (actual.storage as MemoryStorage).drafts.keys;
    expect(keys.any((key) => key.contains('notifications')), isFalse);
  });
  test('notification mutation publishes immediately and an older poll cannot overwrite it', () async {
    final site = _ChromeSite();
    final room = await _room(site);
    final controller = SiteChromeController(room);
    addTearDown(() {
      controller.dispose();
      room.dispose();
    });
    await controller.refreshUnread();
    expect(controller.unread, 3);
    site.delayed = Completer();
    final request = controller.refreshUnread();
    controller.publishUnread(0, forOwner: controller.owner);
    expect(controller.unread, 0);
    site.delayed!.complete({
      'success': true,
      'data': {'count': 7},
    });
    await request;
    expect(controller.unread, 0);
    controller.publishUnread(5, forOwner: 'old-account');
    expect(controller.unread, 0);
  });
  test('account switching clears the old count immediately and rejects late old-account data', () async {
    final site = _ChromeSite();
    final room = await _room(site);
    final chrome = SiteChromeController(room);
    addTearDown(() {
      chrome.dispose();
      room.dispose();
    });
    await chrome.refreshUnread();
    expect(chrome.unread, 3);
    site.delayed = Completer();
    final request = chrome.refreshUnread();
    await room.logout();
    expect(chrome.unread, 0);
    site.delayed!.complete({
      'success': true,
      'data': {'count': 8},
    });
    await request;
    expect(chrome.unread, 0);
    await room.login('bob', 'password');
    site.delayed = null;
    site.count = 1;
    await chrome.refreshUnread();
    expect(chrome.unread, 1);
    site.fail = true;
    await chrome.refreshUnread();
    expect(chrome.unread, 1);
  });
  testWidgets(
    'unread polling runs every 60 seconds, pauses hidden and refreshes on resume',
    (tester) async {
      final site = _ChromeSite();
      final actual = await _room(site);
      final chrome = SiteChromeController(actual);
      try {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        chrome.start();
        await chrome.refreshUnread();
        await tester.pump();
        expect(chrome.visible, isTrue);
        expect(site.reads, 1);
        await tester.pump(const Duration(seconds: 59));
        expect(chrome.visible, isTrue);
        expect(site.reads, 1);
        await tester.pump(const Duration(seconds: 1));
        expect(site.reads, 2);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump(const Duration(minutes: 2));
        expect(site.reads, 2);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(site.reads, 3);
        expect(
          site.unreadRequests,
          List.filled(3, (
            method: 'GET',
            path: '/api/user/notifications/unread-count',
          )),
        );
      } finally {
        chrome.dispose();
        actual.dispose();
      }
    },
  );
  testWidgets(
    'public popup overlay blocks the page until explicit acknowledgement and updates seen signature',
    (tester) async {
      final site = _ChromeSite();
      final actual = await _room(site);
      final chrome = SiteChromeController(actual);
      addTearDown(() {
        chrome.dispose();
        actual.dispose();
      });
      await chrome.routeChanged('/');
      await chrome.routeChanged('/hub');
      await tester.pumpWidget(
        MaterialApp(
          home: SiteChromeScope(
            controller: chrome,
            child: const SiteVisitPopupOverlay(
              child: Scaffold(body: Text('Underlying')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Notice'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is ModalBarrier && widget.color == Colors.black54,
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Notice'), findsNothing);
      expect(chrome.popup, isNull);
    },
  );
  test('Beian supports legacy aliases and only writes public origin-scoped settings', () async {
    expect(
      SiteBeian.from({
        'beianText': '',
        'text': ' Legacy ICP ',
        'mpsBeianText': '',
        'publicSecurityBeianText': ' Legacy MPS ',
      }).text,
      'Legacy ICP',
    );
    expect(
      SiteBeian.from({
        'mpsBeianText': '',
        'publicSecurityBeianText': ' Legacy MPS ',
      }).mpsText,
      'Legacy MPS',
    );
    expect(
      SiteBeian.from({
        'publicSecurityBeianText': ' Alias ',
        'publicSecurityBeianUrl': 'https://example.com',
        'text': ' ICP ',
      }).toJson(),
      {
        'text': 'ICP',
        'url': '',
        'mpsText': 'Alias',
        'mpsUrl': 'https://example.com',
        'mpsIcon': '',
      },
    );
    final site = _ChromeSite();
    final actual = await _room(site);
    final chrome = SiteChromeController(actual);
    addTearDown(() {
      chrome.dispose();
      actual.dispose();
    });
    await chrome.loadBeian();
    expect(chrome.beian.text, 'ICP 123');
    expect(chrome.beian.mpsText, 'MPS 456');
    expect(
      (actual.storage as MemoryStorage).drafts.keys.where(
        (key) => key.startsWith('tsukuyomi_beian_'),
      ),
      ['tsukuyomi_beian_public_settings:${chrome.origin}'],
    );
  });
  test('Beian footer follows AppShell immersive and room exclusions', () {
    for (final path in [
      '/',
      '/access',
      '/login?redirect=%2Fstage',
      '/register',
      '/live2d',
      '/hub',
      '/room',
      '/room/settings',
      '/room-settings',
      '/room/shared/key',
    ]) {
      expect(siteShowsBeian(path), isFalse, reason: path);
    }
    for (final path in [
      '/stage',
      '/plaza',
      '/articles/42',
      '/gallery',
      '/pixel',
      '/game',
      '/user',
    ]) {
      expect(siteShowsBeian(path), isTrue, reason: path);
    }
  });
}
