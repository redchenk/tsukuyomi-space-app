import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/management_page.dart';
import 'package:tsukuyomi_space_app/features/site/management_service.dart';
import 'package:tsukuyomi_space_app/features/site/site_widgets.dart';

import 'support/fakes.dart';

class SlowCredentialStorage extends MemoryStorage {
  final started = Completer<void>(), release = Completer<void>();
  int writes = 0;
  @override
  Future<void> writeSecret(String key, String? value) async {
    if (writes++ == 0) {
      started.complete();
      await release.future;
    }
    await super.writeSecret(key, value);
  }
}

class ManagementFake extends FakeSite implements SiteDataService {
  final calls = <(String, String, Map<String, dynamic>?)>[];
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    calls.add((method, path, body));
    final uri = Uri.parse(path);
    dynamic data = {};
    if (uri.path.endsWith('/me')) {
      data = {'id': 'staff', 'username': 'staff', 'role': 'admin'};
    }
    if (uri.path.endsWith('/articles')) {
      data = {
        'items': [
          {'id': 1, 'title': '原生审核文章', 'status': 'draft'},
        ],
        'pagination': {'total': 1, 'totalPages': 1},
      };
    }
    if (uri.path.endsWith('/messages')) {
      data = {
        'items': [
          {
            'id': 7,
            'username': 'alice',
            'content': '请核对我的留言',
            'status': 'pending',
            'moderation': {
              'reviewDigest': 'digest-7',
              'blocked': false,
              'externalHosts': [],
            },
          },
        ],
        'pagination': {'total': 1, 'totalPages': 1},
      };
    }
    if (uri.path.endsWith('/article-categories')) {
      data = [
        {'id': 1, 'name': '其他', 'protected': 1},
      ];
    }
    return {'success': true, 'data': data};
  }
}

class AccountManagementFake extends ManagementFake {
  final articleOwners = <String>[];
  Completer<Map<String, dynamic>>? pendingAlice;

  @override
  Future<Account> login(String site, String username, String password) async {
    await super.login(site, username, password);
    return Account(username, username, role: 'admin');
  }

  static Map<String, dynamic> articles(String owner) => {
    'success': true,
    'data': {
      'items': [
        {'id': 1, 'title': '$owner 私有审核文章', 'status': 'draft'},
      ],
      'pagination': {'total': 1, 'totalPages': 1},
    },
  };

  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = Uri.parse(path);
    if (uri.path == '/api/moderation/me') {
      return {
        'success': true,
        'data': {'id': userId, 'username': userId, 'role': 'admin'},
      };
    }
    if (uri.path == '/api/moderation/articles') {
      final owner = userId;
      articleOwners.add(owner);
      if (owner == 'alice' && pendingAlice != null) return pendingAlice!.future;
      return articles(owner);
    }
    return super.request(site, method, path, body);
  }
}

void main() {
  test(
    'incorrect terminal credentials preserve the current site administrator',
    () async {
      final storage = MemoryStorage();
      const cookie = 'tsukuyomi_session=site.jwt';
      final site = SiteClient(
        client: MockClient(
          (_) async => http.Response(
            '{"success":false,"message":"invalid credentials"}',
            401,
          ),
        ),
      );
      final c = RoomController(
        storage: storage,
        chat: FakeChat(),
        site: site,
        voice: SilentVoice(),
      );
      await c.initialize();
      addTearDown(c.dispose);
      c.account = const Account('staff', 'staff', role: 'admin');
      site.cookie = cookie;
      await storage.writeSecret('session.https://yachiyo.hk', cookie);
      await expectLater(
        c.login(
          '',
          '',
          credentials: {'username': 'admin', 'password': 'wrong'},
          authPath: '/api/admin/login',
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(site.cookie, cookie);
      expect(c.account!.role, 'admin');
      expect(c.sessionExpired, isFalse);
      expect(storage.secrets['session.https://yachiyo.hk'], cookie);
    },
  );
  test(
    'a delayed keychain rotation cannot restore a logged-out session',
    () async {
      final storage = SlowCredentialStorage();
      final client = SiteClient(
        client: MockClient(
          (request) async => http.Response(
            '{"success":true,"data":{}}',
            200,
            headers: {
              'set-cookie': request.url.path.endsWith('/logout')
                  ? 'tsukuyomi_session=; Max-Age=0; Path=/'
                  : 'tsukuyomi_session=old.jwt; Path=/',
            },
          ),
        ),
      );
      final c = RoomController(
        storage: storage,
        chat: FakeChat(),
        site: client,
        voice: SilentVoice(),
      );
      await c.initialize();
      addTearDown(c.dispose);
      c.account = const Account('alice', 'alice');
      await client.request(c.settings.siteUrl, 'POST', '/api/auth/rotate');
      await storage.started.future;
      final logout = c.logout();
      await Future<void>.delayed(Duration.zero);
      expect(storage.writes, 1);
      storage.release.complete();
      await logout;
      expect(client.cookie, isNull);
      expect(storage.secrets, isEmpty);
      expect(c.account, isNull);
    },
  );
  test(
    'moderator delete uses source POST while terminal uses DELETE',
    () async {
      final fake = ManagementFake();
      await ManagementService(
        fake,
        'https://yachiyo.hk',
        terminalSession: false,
      ).request('DELETE', '/messages/7');
      expect(fake.calls.single.$1, 'POST');
      expect(fake.calls.single.$2, '/api/moderation/messages/7/delete');
      fake.calls.clear();
      await ManagementService(
        fake,
        'https://yachiyo.hk',
        terminalSession: true,
      ).request('DELETE', '/articles/1');
      expect(fake.calls.single.$1, 'DELETE');
      expect(fake.calls.single.$2, '/api/admin/articles/1');
    },
  );
  test(
    'review requires current digest and explicit external-domain confirmation',
    () {
      final message = {
        'moderation': {
          'reviewDigest': 'current',
          'externalHosts': ['example.org'],
        },
      };
      expect(
        () =>
            ManagementService.approval(message, confirmedExternalLinks: false),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        ManagementService.approval(message, confirmedExternalLinks: true),
        {'reviewDigest': 'current', 'confirmExternalLink': true},
      );
      expect(
        () => ManagementService.approval({
          'moderation': {'blocked': true, 'reviewDigest': 'digest'},
        }, confirmedExternalLinks: true),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        () => ManagementService.approval({}, confirmedExternalLinks: true),
        throwsA(isA<ApiFailure>()),
      );
    },
  );
  test(
    'terminal cookies survive restart and logout preserves site session',
    () async {
      var phase = 0, expires = 0;
      final client =
          SiteClient(
              client: MockClient((request) async {
                if (phase++ == 0) {
                  return http.Response(
                    jsonEncode({
                      'success': true,
                      'data': {
                        'user': {
                          'id': 'root',
                          'username': 'admin',
                          'role': 'super_admin',
                        },
                      },
                    }),
                    200,
                    headers: {
                      'set-cookie': 'tsukuyomi_session=site.jwt; HttpOnly; Path=/, tsukuyomi_admin_session=terminal.jwt; HttpOnly; Path=/; SameSite=Strict',
                    },
                  );
                }
                expect(
                  request.headers['Cookie'],
                  contains('tsukuyomi_session=site.jwt'),
                );
                if (request.url.path.endsWith('/logout')) {
                  return http.Response(
                    '{"success":true}',
                    200,
                    headers: {
                      'set-cookie':
                          'tsukuyomi_admin_session=; Max-Age=0; Path=/',
                    },
                  );
                }
                return http.Response(
                  '{"success":false,"message":"expired"}',
                  401,
                );
              }),
            )
            ..onUnauthorized = () {
              expires++;
            };
      final account = await client.authenticate('https://yachiyo.hk', {
        'username': 'admin',
        'password': 'password',
      }, path: '/api/admin/login');
      expect(account.isAdministrator, isTrue);
      expect(account.role, 'super_admin');
      expect(client.cookie, contains('tsukuyomi_admin_session=terminal.jwt'));
      await client.request('https://yachiyo.hk', 'POST', '/api/admin/logout');
      expect(client.cookie, 'tsukuyomi_session=site.jwt');
      await expectLater(
        client.request('https://yachiyo.hk', 'GET', '/api/admin/me'),
        throwsA(isA<ApiFailure>()),
      );
      expect(expires, 0);
      client.dispose();
    },
  );
  for (final role in [null, 'user', 'banned', 'admin', 'super_admin']) {
    testWidgets(
      'navigation hides backend unless authenticated administrator ($role)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SiteHeader(
                title: '测试',
                username: role == null ? null : 'alice',
                role: role,
                onGo: (_) {},
                onLogin: () {},
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('探索'));
        await tester.pumpAndSettle();
        final permitted = role == 'admin' || role == 'super_admin';
        expect(find.text('内容管理'), permitted ? findsOneWidget : findsNothing);
        expect(find.text('管理终端'), permitted ? findsOneWidget : findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  Future<(RoomController, ManagementFake)> mount(
    WidgetTester tester,
    String? role,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = ManagementFake();
    final c = RoomController(
      storage: MemoryStorage(),
      chat: FakeChat(),
      site: fake,
      voice: SilentVoice(),
    );
    await c.initialize();
    if (role != null) c.account = Account('staff', 'staff', role: role);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ManagementPage(controller: c, path: '/admin', onGo: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
    return (c, fake);
  }

  testWidgets(
    'direct backend route never loads private data for normal users',
    (tester) async {
      final (_, fake) = await mount(tester, 'user');
      expect(find.text('需要管理员权限'), findsOneWidget);
      expect(fake.calls, isEmpty);
      expect(find.text('原生审核文章'), findsNothing);
    },
  );
  testWidgets(
    'administrator reads original categories and approves source digest',
    (tester) async {
      final (_, fake) = await mount(tester, 'admin');
      expect(find.text('原生审核文章'), findsOneWidget);
      final category = find.widgetWithText(InputChip, '其他');
      expect(tester.widget<InputChip>(category).onDeleted, isNull);
      await tester.tap(find.widgetWithText(ChoiceChip, '留言审核'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('通过审核'));
      await tester.tap(find.text('通过审核'));
      await tester.pumpAndSettle();
      final action = fake.calls.singleWhere(
        (call) => call.$2.endsWith('/messages/7/approve'),
      );
      expect(action.$3, {
        'reviewDigest': 'digest-7',
        'confirmExternalLink': false,
      });
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'demo mode isolates equal-role administrators and ignores a late private response',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final site = AccountManagementFake();
      final room = RoomController(
        storage: MemoryStorage(),
        chat: FakeChat(),
        site: site,
        voice: SilentVoice(),
      );
      addTearDown(room.dispose);
      await room.initialize();
      await room.login('alice', 'test-password');
      expect(room.settings.demo, isTrue);
      expect(room.scope, 'demo');
      await tester.pumpWidget(
        MaterialApp(
          home: ManagementPage(controller: room, path: '/admin', onGo: (_) {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('alice 私有审核文章'), findsOneWidget);

      final delayed = Completer<Map<String, dynamic>>();
      site.pendingAlice = delayed;
      final refreshing = tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pump();
      expect(site.articleOwners, ['alice', 'alice']);

      await room.login('bob', 'test-password');
      await tester.pumpAndSettle();
      expect(room.account!.id, 'bob');
      expect(room.account!.role, 'admin');
      expect(room.scope, 'demo');
      expect(find.text('alice 私有审核文章'), findsNothing);
      expect(find.text('bob 私有审核文章'), findsOneWidget);
      expect(site.articleOwners, ['alice', 'alice', 'bob']);

      delayed.complete(AccountManagementFake.articles('alice'));
      await refreshing;
      await tester.pumpAndSettle();
      expect(find.text('alice 私有审核文章'), findsNothing);
      expect(find.text('bob 私有审核文章'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
