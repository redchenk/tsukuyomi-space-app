import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/core/site_repository.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/site_notification.dart';
import 'package:tsukuyomi_space_app/features/site/site_page.dart';
import 'package:tsukuyomi_space_app/features/site/site_share_actions.dart';

import 'support/fakes.dart';

class _Site extends FakeSite implements SiteDataService {
  final calls = <({String method, String path, Map<String, dynamic>? body})>[];
  Future<Map<String, dynamic>> Function(String, String, Map<String, dynamic>?)?
  handler;

  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    calls.add((method: method, path: path, body: body));
    if (handler != null) return handler!(method, path, body);
    return {'success': true, 'data': []};
  }
}

Map<String, dynamic> _inbox(String owner) => {
  'success': true,
  'data': [
    {
      'id': 1,
      'title': '$owner 已读通知',
      'content': '之前已经读过',
      'unread': false,
      'read_at': '2026-09-30 01:00:00',
      'link': '/articles/9',
    },
    {
      'id': 2,
      'title': '$owner 新回复',
      'content': '来自原站的回复',
      'unread': true,
      'read_at': null,
      'link': '',
    },
  ],
  'unread': 8,
  'pagination': {'page': 1, 'limit': 12, 'total': 14, 'totalPages': 2},
};

Future<RoomController> _controller(_Site site, {bool loggedIn = true}) async {
  final controller = RoomController(
    storage: MemoryStorage(),
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await controller.initialize();
  if (loggedIn) await controller.login('alice', 'test');
  return controller;
}

Future<void> _show(
  WidgetTester tester,
  RoomController controller,
  String path, {
  void Function(String)? onNavigate,
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: SitePage(controller: controller, path: path),
      onGenerateRoute: (settings) {
        onNavigate?.call(settings.name!);
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => Scaffold(body: Text('目标：${settings.name}')),
        );
      },
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('notification unread follows the actual website contract', () {
    expect(SiteNotification({'unread': false, 'is_read': 0}).unread, isFalse);
    expect(SiteNotification({'unread': true, 'is_read': 1}).unread, isTrue);
    expect(SiteNotification({'read_at': '2026-09-30'}).unread, isFalse);
    expect(SiteNotification({'read_at': null}).unread, isTrue);
    expect(SiteNotification({'is_read': 1}).unread, isFalse);
    expect(SiteNotification({'is_read': 0}).unread, isTrue);
    expect(SiteNotification({}).unread, isFalse);
    expect(
      notificationUnreadCount(8, [
        SiteNotification({'unread': true}),
      ]),
      8,
    );
    expect(notificationUnreadCount(-1, []), 0);
  });

  test('copy records growth once after clipboard succeeds', () async {
    final site = _Site(), storage = MemoryStorage();
    final repo = SiteRepository(
      api: site,
      storage: storage,
      site: () => 'https://yachiyo.hk',
      accountId: () => 'alice',
    );
    final events = <String>[];
    site.handler = (method, path, body) async {
      events.add('growth');
      return {'success': true};
    };
    final actions = SiteShareActions(
      repository: repo,
      canRecordGrowth: () => true,
      copy: (value) async => events.add('copy:$value'),
    );
    final result = await actions.copyLink(
      'https://yachiyo.hk/articles/1',
      onCopied: () => events.add('copied'),
    );
    expect(events, ['copy:https://yachiyo.hk/articles/1', 'copied', 'growth']);
    expect(result.growthRecorded, isTrue);
    expect(site.calls.single.method, 'POST');
    expect(site.calls.single.path, '/api/growth/actions/share');
    expect(site.calls.single.body, {'platform': 'copy'});
  });

  test('clipboard failure does not record or announce a share', () async {
    final site = _Site();
    final repo = SiteRepository(
      api: site,
      storage: MemoryStorage(),
      site: () => 'https://yachiyo.hk',
      accountId: () => 'alice',
    );
    var announced = false;
    final actions = SiteShareActions(
      repository: repo,
      canRecordGrowth: () => true,
      copy: (_) async => throw StateError('clipboard denied'),
    );
    await expectLater(
      actions.copyLink('link', onCopied: () => announced = true),
      throwsStateError,
    );
    expect(announced, isFalse);
    expect(site.calls, isEmpty);
  });

  test(
    'growth failure preserves copying and is never blindly retried',
    () async {
      final site = _Site();
      site.handler = (_, path, body) async => throw const ApiFailure('offline');
      final actions = SiteShareActions(
        repository: SiteRepository(
          api: site,
          storage: MemoryStorage(),
          site: () => 'https://yachiyo.hk',
          accountId: () => 'alice',
        ),
        canRecordGrowth: () => true,
        copy: (_) async {},
      );
      var copied = false;
      final result = await actions.copyLink(
        'link',
        onCopied: () => copied = true,
      );
      expect(copied, isTrue);
      expect(result.growthRecorded, isFalse);
      expect(site.calls, hasLength(1));
    },
  );

  test('anonymous and expired copies do not need authentication', () async {
    final site = _Site();
    for (final owner in [null, 'expired-alice']) {
      final actions = SiteShareActions(
        repository: SiteRepository(
          api: site,
          storage: MemoryStorage(),
          site: () => 'https://yachiyo.hk',
          accountId: () => owner,
        ),
        canRecordGrowth: () => false,
        copy: (_) async {},
      );
      await actions.copyLink('link');
    }
    expect(site.calls, isEmpty);
  });

  test(
    'account switching during copying cannot award the next account',
    () async {
      final site = _Site();
      final clipboard = Completer<void>();
      var owner = 'alice';
      final actions = SiteShareActions(
        repository: SiteRepository(
          api: site,
          storage: MemoryStorage(),
          site: () => 'https://yachiyo.hk',
          accountId: () => owner,
        ),
        canRecordGrowth: () => true,
        copy: (_) => clipboard.future,
      );
      var announced = false;
      final pending = actions.copyLink(
        'link',
        onCopied: () => announced = true,
      );
      owner = 'bob';
      clipboard.complete();
      expect((await pending).growthRecorded, isFalse);
      expect(announced, isFalse);
      expect(site.calls, isEmpty);
    },
  );

  testWidgets(
    'only unread notifications show a dot; single read updates count',
    (tester) async {
      final site = _Site();
      site.handler = (method, path, body) async {
        if (method == 'GET') return _inbox(site.userId);
        return {
          'success': true,
          'data': {'id': 2, 'unread': false, 'read_at': '2026-09-30'},
          'unread': 7,
        };
      };
      final c = await _controller(site);
      addTearDown(c.dispose);
      await _show(tester, c, '/notifications');
      expect(site.calls.first.path, '/api/user/notifications?limit=12&page=1');
      expect(find.byKey(const ValueKey('notification-unread-1')), findsNothing);
      expect(
        find.byKey(const ValueKey('notification-unread-2')),
        findsOneWidget,
      );
      expect(find.text('未读 8'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('notification-mark-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('notification-unread-2')), findsNothing);
      expect(find.text('未读 7'), findsOneWidget);
      expect(site.calls.where((call) => call.method == 'POST'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all-read updates visited cache pages for offline refresh', (
    tester,
  ) async {
    final site = _Site();
    site.handler = (method, path, body) async {
      if (method == 'GET') return _inbox(site.userId);
      return {
        'success': true,
        'data': {'changed': 8, 'count': 0},
      };
    };
    final c = await _controller(site);
    addTearDown(c.dispose);
    final storage = c.storage as MemoryStorage;
    const page2Key =
        'site-cache:https://yachiyo.hk:alice:/api/user/notifications?limit=12&page=2';
    storage.drafts[page2Key] = jsonEncode(_inbox('alice'));
    await _show(tester, c, '/notifications');
    await tester.tap(find.text('全部已读'));
    await tester.pumpAndSettle();
    expect(find.text('未读 0'), findsOneWidget);
    expect(find.byKey(const ValueKey('notification-unread-2')), findsNothing);
    final saved = jsonDecode(storage.drafts[page2Key]!) as Map;
    expect(saved['unread'], 0);
    expect(
      (saved['data'] as List).every((item) => item['unread'] == false),
      isTrue,
    );
    site.handler = (_, path, body) async => throw const ApiFailure('offline');
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('未读 0'), findsOneWidget);
    expect(find.byKey(const ValueKey('notification-unread-2')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed read keeps unread status and can be retried', (
    tester,
  ) async {
    final site = _Site();
    var fail = true;
    site.handler = (method, path, body) async {
      if (method == 'GET') return _inbox(site.userId);
      if (fail) throw const ApiFailure('保存失败');
      return {
        'success': true,
        'data': {'id': 2},
        'unread': 7,
      };
    };
    final c = await _controller(site);
    addTearDown(c.dispose);
    await _show(tester, c, '/notifications');
    await tester.tap(find.byKey(const ValueKey('notification-mark-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notification-unread-2')), findsOneWidget);
    expect(find.text('未读 8'), findsOneWidget);
    fail = false;
    await tester.tap(find.byKey(const ValueKey('notification-mark-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notification-unread-2')), findsNothing);
    expect(find.text('未读 7'), findsOneWidget);
  });

  testWidgets(
    'opening an already read notification navigates without a write',
    (tester) async {
      final site = _Site();
      site.handler = (_, path, body) async => _inbox(site.userId);
      final c = await _controller(site);
      addTearDown(c.dispose);
      String? destination;
      await _show(
        tester,
        c,
        '/notifications',
        onNavigate: (path) => destination = path,
      );
      await tester.tap(find.byKey(const ValueKey('notification-1')));
      await tester.pumpAndSettle();
      expect(destination, '/articles/9');
      expect(site.calls.where((call) => call.method == 'POST'), isEmpty);
      expect(find.text('目标：/articles/9'), findsOneWidget);
    },
  );

  testWidgets('a late read response cannot change the next account inbox', (
    tester,
  ) async {
    final site = _Site();
    final write = Completer<Map<String, dynamic>>();
    site.handler = (method, path, body) async {
      if (method == 'GET') return _inbox(site.userId);
      return write.future;
    };
    final c = await _controller(site);
    addTearDown(c.dispose);
    await _show(tester, c, '/notifications');
    await tester.tap(find.byKey(const ValueKey('notification-mark-2')));
    await tester.pump();
    await c.logout();
    await c.login('bob', 'test');
    await tester.pumpAndSettle();
    expect(find.text('bob 新回复'), findsOneWidget);
    write.complete({
      'success': true,
      'data': {'id': 2},
      'unread': 0,
    });
    await tester.pumpAndSettle();
    expect(find.text('未读 8'), findsOneWidget);
    expect(find.byKey(const ValueKey('notification-unread-2')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a read completed after leaving cannot navigate the current page', (
    tester,
  ) async {
    final site = _Site();
    final write = Completer<Map<String, dynamic>>();
    site.handler = (method, path, body) async {
      if (method == 'GET') {
        final inbox = _inbox(site.userId);
        (inbox['data'] as List)[1]['link'] = '/articles/9';
        return inbox;
      }
      return write.future;
    };
    final c = await _controller(site);
    addTearDown(c.dispose);
    final destinations = <String>[];
    await _show(tester, c, '/notifications', onNavigate: destinations.add);
    await tester.tap(find.byKey(const ValueKey('notification-2')));
    await tester.pump();
    unawaited(
      Navigator.of(tester.element(find.byType(SitePage)))
          .pushNamed<void>('/stage'),
    );
    await tester.pumpAndSettle();
    write.complete({
      'success': true,
      'data': {'id': 2},
      'unread': 7,
    });
    await tester.pumpAndSettle();
    expect(destinations, ['/stage']);
    expect(find.text('目标：/stage'), findsOneWidget);
    const key =
        'site-cache:https://yachiyo.hk:alice:/api/user/notifications?limit=12&page=1';
    final saved = jsonDecode((c.storage as MemoryStorage).drafts[key]!) as Map;
    expect(saved['unread'], 7);
    expect((saved['data'] as List)[1]['unread'], isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets('notification actions fit width $width', (tester) async {
      final site = _Site();
      site.handler = (_, path, body) async => _inbox(site.userId);
      final c = await _controller(site);
      addTearDown(c.dispose);
      await _show(tester, c, '/notifications', width: width);
      expect(find.text('未读 8'), findsOneWidget);
      expect(find.text('全部已读'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('guest article copying does not open login or record growth', (
    tester,
  ) async {
    final site = _Site();
    site.handler = (_, path, body) async => {
      'success': true,
      'data': path.endsWith('/articles/1')
          ? {'id': 1, 'title': '文章', 'content': '正文'}
          : [],
    };
    final c = await _controller(site, loggedIn: false);
    addTearDown(c.dispose);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _show(tester, c, '/articles/1');
    await tester.ensureVisible(find.text('复制链接'));
    await tester.tap(find.text('复制链接'));
    await tester.pumpAndSettle();
    expect(find.text('文章链接已复制'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(site.calls.where((call) => call.method == 'POST'), isEmpty);
  });

  testWidgets(
    'invite copy records once and immediately announces clipboard success',
    (tester) async {
      final site = _Site();
      final growth = Completer<Map<String, dynamic>>();
      site.handler = (method, path, body) async {
        if (method == 'POST') return growth.future;
        return {
          'success': true,
          'data': {
            'referral': {'inviteCode': 'moon-1'},
            'today': {'tasks': []},
          },
        };
      };
      final c = await _controller(site);
      addTearDown(c.dispose);
      var clipboardWrites = 0;
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardWrites++;
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _show(tester, c, '/growth');
      await tester.ensureVisible(find.text('复制邀请链接'));
      await tester.tap(find.text('复制邀请链接'));
      await tester.pump();
      expect(find.text('邀请链接已复制'), findsOneWidget);
      await tester.tap(find.text('复制邀请链接'));
      await tester.pump();
      expect(clipboardWrites, 1);
      expect(
        copied,
        'https://yachiyo.hk/register?invite=moon-1&redirect=%2Fgrowth',
      );
      expect(
        site.calls.where((call) => call.path == '/api/growth/actions/share'),
        hasLength(1),
      );
      growth.complete({'success': true, 'data': {}});
      await tester.pumpAndSettle();
      expect(site.calls.where((call) => call.method == 'GET'), hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  for (final failClipboard in [false, true]) {
    testWidgets(
      'article copy integrates clipboard and growth ($failClipboard)',
      (tester) async {
        final site = _Site();
        site.handler = (_, path, body) async {
          if (path.endsWith('/articles/1')) {
            return {
              'success': true,
              'data': {'id': 1, 'title': '文章', 'content': '正文'},
            };
          }
          return {'success': true, 'data': []};
        };
        final c = await _controller(site);
        addTearDown(c.dispose);
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              if (failClipboard) {
                throw PlatformException(code: 'clipboard-denied');
              }
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await _show(tester, c, '/articles/1');
        await tester.ensureVisible(find.text('复制链接'));
        await tester.tap(find.text('复制链接'));
        await tester.pumpAndSettle();
        final shares = site.calls.where(
          (call) => call.path == '/api/growth/actions/share',
        );
        if (failClipboard) {
          expect(copied, isNull);
          expect(shares, isEmpty);
          expect(find.text('复制失败，请重试'), findsOneWidget);
          expect(find.text('文章链接已复制'), findsNothing);
        } else {
          expect(copied, 'https://yachiyo.hk/articles/1');
          expect(shares, hasLength(1));
          expect(shares.single.body, {'platform': 'copy'});
          expect(find.text('文章链接已复制'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
