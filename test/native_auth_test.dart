import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/native_auth_page.dart';
import 'package:tsukuyomi_space_app/features/site/qq_auth.dart';
import 'package:tsukuyomi_space_app/features/site/site_widgets.dart';

import 'support/fakes.dart';

http.Response authReply(dynamic data, {String? cookie, int status = 200}) =>
    http.Response(
      jsonEncode({
        'success': status < 300,
        'data': data,
        'message': status < 300 ? '成功' : '请求失败',
      }),
      status,
      headers: {'content-type': 'application/json', 'set-cookie': ?cookie},
    );

Future<RoomController> authController(
  http.Client httpClient, {
  MemoryStorage? storage,
}) async {
  final c = RoomController(
    storage: storage ?? MemoryStorage(),
    site: SiteClient(client: httpClient),
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await c.initialize();
  return c;
}

Future<void> authField(WidgetTester tester, String name, String text) async {
  final finder = find.byKey(Key('auth-$name'));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, text);
}

Future<void> authMount(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(320, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

void main() {
  test('auth redirect preserves internal query/hash and rejects external or auth loops', () {
    expect(
      sanitizeAuthRedirect('/articles/42/故事?view=full#notes'),
      '/articles/42/%E6%95%85%E4%BA%8B?view=full#notes',
    );
    for (final value in [
      '',
      '/',
      '//evil.test/x',
      '/access/',
      '/login?redirect=/x',
      '/register',
      'https://evil.test',
      '/\\evil.test',
      '/path\nnext',
    ]) {
      expect(sanitizeAuthRedirect(value), '/hub', reason: value);
    }
  });

  test('OAuth entry trust follows the original server setting and navigation host boundary', () {
    final target = QQOAuthTarget.fromSettings('https://yachiyo.hk', {
      'qqOAuthStartUrl': 'https://auth.yachiyo.hk/api/auth/oauth/qq/start',
    }, '/users/Alice');
    expect(target.origin, 'https://auth.yachiyo.hk');
    expect(target.start.queryParameters['redirect'], '/users/Alice');
    expect(
      target.permits(Uri.parse('https://graph.qq.com/oauth2.0/authorize')),
      isTrue,
    );
    expect(target.permits(Uri.parse('https://qq.com.evil.test/auth')), isFalse);
    expect(target.permits(Uri.parse('javascript:alert(1)')), isFalse);
    expect(
      () => QQOAuthTarget.fromSettings('https://yachiyo.hk', {
        'qqOAuthStartUrl': 'http://evil.test/api/auth/oauth/qq/start',
      }, '/hub'),
      throwsA(isA<ApiFailure>()),
    );
    expect(
      () => QQOAuthTarget.fromSettings('https://yachiyo.hk', {
        'qqOAuthStartUrl': 'https://u:p@evil.test/api/auth/oauth/qq/start',
      }, '/hub'),
      throwsA(isA<ApiFailure>()),
    );
  });

  test('OAuth requests preserve binding and accept session without polluting normal cookies', () async {
    final requests = <http.Request>[];
    final transport = QQOAuthHttp(
      'https://auth.yachiyo.hk',
      client: MockClient((request) async {
        requests.add(request);
        return authReply(
          {'redirect': '/hub'},
          cookie: 'tsukuyomi_session=signed.session; HttpOnly; Secure; Path=/, __Host-tsukuyomi_qq_oauth=; Max-Age=0; Path=/',
        );
      }),
    );
    addTearDown(transport.dispose);
    transport.importCookies([
      const MapEntry('__Host-tsukuyomi_qq_oauth', 'abcdef'),
      const MapEntry('irrelevant', 'ignored'),
    ]);
    expect(transport.hasBinding, isTrue);
    await transport.request('POST', '/api/auth/oauth/qq/email', {
      'ticket': 'abc',
      'email': 'a@example.com',
    });
    expect(
      requests.single.headers['Cookie'],
      '__Host-tsukuyomi_qq_oauth=abcdef',
    );
    expect(requests.single.headers['Origin'], 'https://auth.yachiyo.hk');
    expect(transport.sessionCookie, 'tsukuyomi_session=signed.session');
    expect(transport.hasBinding, isFalse);
    await expectLater(
      transport.request('POST', 'https://evil.test/api/auth/oauth/qq/email'),
      throwsA(isA<ApiFailure>()),
    );
    expect(requests, hasLength(1));
  });

  testWidgets(
    'register confirms password, sends backend body, claims invite and preserves redirect',
    (tester) async {
      final requests = <http.Request>[];
      final storage = MemoryStorage();
      final c = await authController(
        MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/api/auth/register') {
            return authReply(
              {
                'user': {'id': 'alice', 'username': 'Alice', 'role': 'user'},
              },
              cookie: 'tsukuyomi_session=registered.session; HttpOnly; Path=/',
            );
          }
          return authReply([]);
        }),
        storage: storage,
      );
      addTearDown(c.dispose);
      final destinations = <String>[];
      await authMount(
        tester,
        NativeAuthPage(
          controller: c,
          path: '/register?redirect=%2Farticles%2F42%3Fview%3Dfull%23notes&invite=abcdef0123',
          onGo: destinations.add,
        ),
      );
      await authField(tester, 'name', 'Alice');
      await authField(tester, 'email', 'alice@example.com');
      await authField(tester, 'code', '123456');
      await authField(tester, 'password', 'newpassword');
      await authField(tester, 'confirm', 'different');
      await tester.ensureVisible(find.byKey(const Key('auth-submit')));
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();
      expect(find.text('两次输入的密码不一致'), findsOneWidget);
      expect(
        requests.where((r) => r.url.path == '/api/auth/register'),
        isEmpty,
      );
      await authField(tester, 'confirm', 'newpassword');
      await tester.ensureVisible(find.byKey(const Key('auth-submit')));
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();
      final body = jsonDecode(
        requests.singleWhere((r) => r.url.path == '/api/auth/register').body,
      );
      expect(body, {
        'username': 'Alice',
        'email': 'alice@example.com',
        'emailCode': '123456',
        'password': 'newpassword',
      });
      expect(destinations, ['/articles/42?view=full#notes']);
      expect(
        jsonDecode(
          requests
              .singleWhere((r) => r.url.path == '/api/growth/referrals/claim')
              .body,
        ),
        {'code': 'ABCDEF0123'},
      );
      expect(storage.drafts['pending-referral:https://yachiyo.hk'], '');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'email code login has purpose cooldown and reset uses distinct backend contract',
    (tester) async {
      final requests = <http.Request>[];
      final c = await authController(
        MockClient((request) async {
          requests.add(request);
          return authReply({});
        }),
      );
      addTearDown(c.dispose);
      await authMount(tester, NativeAuthPage(controller: c, onGo: (_) {}));
      await tester.ensureVisible(find.text('验证码登录'));
      await tester.tap(find.text('验证码登录'));
      await tester.pumpAndSettle();
      await authField(tester, 'name', 'alice@example.com');
      await tester.ensureVisible(find.byKey(const Key('auth-send-code')));
      await tester.tap(find.byKey(const Key('auth-send-code')));
      await tester.pumpAndSettle();
      expect(jsonDecode(requests.single.body), {
        'email': 'alice@example.com',
        'purpose': 'login',
      });
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('auth-send-code')))
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text('忘记密码'));
      await tester.tap(find.text('忘记密码'));
      await tester.pumpAndSettle();
      await authField(tester, 'email', 'alice@example.com');
      await tester.ensureVisible(find.byKey(const Key('auth-send-code')));
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('auth-send-code')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('auth-send-code')));
      await tester.pumpAndSettle();
      expect(jsonDecode(requests.last.body), {
        'email': 'alice@example.com',
        'purpose': 'password_reset',
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'original forgot query opens native reset and posts the original contract without site chrome',
    (tester) async {
      final requests = <http.Request>[];
      final c = await authController(
        MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/api/auth/password/reset') {
            return authReply({
              'user': {'id': 'reset-user', 'username': 'Alice', 'role': 'user'},
              'redirect': '/growth',
            }, cookie: 'tsukuyomi_session=reset.session; HttpOnly; Path=/');
          }
          return authReply([]);
        }),
      );
      addTearDown(c.dispose);
      final destinations = <String>[];
      await authMount(
        tester,
        NativeAuthPage(
          controller: c,
          path: '/login?forgot=1&redirect=%2Fgrowth',
          onGo: destinations.add,
        ),
      );
      expect(find.byType(SiteHeader), findsNothing);
      expect(find.byKey(const Key('auth-email')), findsOneWidget);
      expect(find.byKey(const Key('auth-name')), findsNothing);
      await authField(tester, 'email', 'alice@example.com');
      await authField(tester, 'code', '123456');
      await authField(tester, 'password', 'reset-password');
      await authField(tester, 'confirm', 'reset-password');
      await tester.ensureVisible(find.byKey(const Key('auth-submit')));
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();
      expect(
        jsonDecode(
          requests
              .singleWhere((r) => r.url.path == '/api/auth/password/reset')
              .body,
        ),
        {
          'email': 'alice@example.com',
          'emailCode': '123456',
          'newPassword': 'reset-password',
          'redirect': '/growth',
        },
      );
      expect(c.account?.id, 'reset-user');
      expect(destinations, ['/growth']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a QQ grant arriving after account changes cannot replace the new account',
    (tester) async {
      final requests = <http.Request>[];
      final c = await authController(
        MockClient((request) async {
          requests.add(request);
          return authReply([]);
        }),
      );
      addTearDown(c.dispose);
      final authorization = Completer<QQAuthGrant?>();
      final target = QQOAuthTarget.fromSettings(c.settings.siteUrl, {
        'qqOAuthStartUrl': 'https://yachiyo.hk/api/auth/oauth/qq/start',
      }, '/hub');
      final transport =
          QQOAuthHttp(
            target.origin,
            client: MockClient(
              (_) async => throw StateError('stale grant must not be queried'),
            ),
          )..importCookies([
            const MapEntry('__Host-tsukuyomi_qq_oauth', 'binding123'),
          ]);
      final destinations = <String>[];
      await authMount(
        tester,
        NativeAuthPage(
          controller: c,
          onGo: destinations.add,
          authorize: (
            context,
            controller, {
            String redirect = '/hub',
            bool bindCurrentAccount = false,
          }) => authorization.future,
        ),
      );
      await tester.ensureVisible(find.byKey(const Key('auth-qq')));
      await tester.tap(find.byKey(const Key('auth-qq')));
      await tester.pump();
      c.account = const Account('bob', 'Bob');
      c.site.cookie = 'tsukuyomi_session=bob.session';
      c.notifyListeners();
      authorization.complete(
        QQAuthGrant(target: target, transport: transport, ticket: 'a' * 48),
      );
      await tester.pumpAndSettle();
      expect(c.account?.id, 'bob');
      expect(c.site.cookie, 'tsukuyomi_session=bob.session');
      expect(transport.hasBinding, isFalse);
      expect(requests, isEmpty);
      expect(destinations, isEmpty);
      expect(find.text('账号已切换，请重新授权'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'QQ pending email completion stays native and imports verified session',
    (tester) async {
      final ordinary = <http.Request>[], oauth = <http.Request>[];
      final c = await authController(
        MockClient((request) async {
          ordinary.add(request);
          if (request.url.path == '/api/auth/me') {
            return authReply({
              'id': 'qq-user',
              'username': 'QQ创作者',
              'role': 'user',
            });
          }
          return authReply([]);
        }),
      );
      addTearDown(c.dispose);
      final target = QQOAuthTarget.fromSettings(c.settings.siteUrl, {
        'qqOAuthStartUrl': 'https://yachiyo.hk/api/auth/oauth/qq/start',
      }, '/hub');
      final transport =
          QQOAuthHttp(
            target.origin,
            client: MockClient((request) async {
              oauth.add(request);
              if (request.url.path.endsWith('/pending')) {
                return authReply({
                  'requiresEmailBinding': true,
                  'nickname': 'QQ创作者',
                  'suggestedUsername': 'qq_writer',
                });
              }
              return authReply({
                'redirect': '/hub',
              }, cookie: 'tsukuyomi_session=qq.session; HttpOnly; Path=/');
            }),
          )..importCookies([
            const MapEntry('__Host-tsukuyomi_qq_oauth', 'binding123'),
          ]);
      final destinations = <String>[];
      await authMount(
        tester,
        NativeAuthPage(
          controller: c,
          onGo: destinations.add,
          authorize:
              (
                context,
                controller, {
                String redirect = '/hub',
                bool bindCurrentAccount = false,
              }) async => QQAuthGrant(
                target: target,
                transport: transport,
                ticket: 'a' * 48,
                redirect: redirect,
              ),
        ),
      );
      await tester.ensureVisible(find.byKey(const Key('auth-qq')));
      await tester.tap(find.byKey(const Key('auth-qq')));
      await tester.pumpAndSettle();
      expect(find.text('绑定邮箱'), findsWidgets);
      await authField(tester, 'email', 'qq@example.com');
      await authField(tester, 'code', '123456');
      await authField(tester, 'password', 'newpassword');
      await authField(tester, 'confirm', 'newpassword');
      await tester.ensureVisible(find.byKey(const Key('auth-submit')));
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();
      final complete = oauth.singleWhere((r) => r.url.path.endsWith('/email'));
      expect(
        complete.headers['Cookie'],
        '__Host-tsukuyomi_qq_oauth=binding123',
      );
      expect(jsonDecode(complete.body), {
        'ticket': 'a' * 48,
        'email': 'qq@example.com',
        'emailCode': '123456',
        'username': 'qq_writer',
        'newPassword': 'newpassword',
      });
      expect(
        ordinary
            .singleWhere((r) => r.url.path == '/api/auth/me')
            .headers['Cookie'],
        'tsukuyomi_session=qq.session',
      );
      expect(
        ordinary.any((r) => (r.headers['Cookie'] ?? '').contains('qq_oauth')),
        isFalse,
      );
      expect(c.account?.username, 'QQ创作者');
      expect(destinations, ['/hub']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
