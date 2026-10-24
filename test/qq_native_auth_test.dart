import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/native_qq_sdk.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/qq_auth.dart';

import 'support/fakes.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final state = 'a' * 48, token = 'f' * 32, openId = 'B' * 32;
  final target = QQOAuthTarget(
    Uri.parse('https://yachiyo.hk/api/auth/oauth/qq/native/start'),
    Uri.parse('https://yachiyo.hk'),
  );
  var sdkCalls = 0;
  setUp(() {
    sdkCalls = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NativeQQSdk.channel,
      (call) async {
        sdkCalls++;
        expect(call.method, 'login');
        expect(call.arguments, {'consent': true});
        return {
          'clientId': NativeQQSdk.appId,
          'accessToken': token,
          'openId': openId,
        };
      },
    );
  });
  tearDown(
    () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NativeQQSdk.channel,
      null,
    ),
  );

  QQOAuthHttp transport(
    List<http.Request> requests, {
    bool pending = false,
    String? appId,
    String? flowState,
  }) => QQOAuthHttp(
    target.origin,
    client: MockClient((request) async {
      requests.add(request);
      expect(request.url.origin, target.origin);
      expect(request.followRedirects, false);
      expect(request.headers['Origin'], target.origin);
      if (request.url.path.endsWith('/start')) {
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {
              'appId': appId ?? NativeQQSdk.appId,
              'state': flowState ?? state,
            },
          }),
          200,
          headers: {
            'set-cookie':
                '__Host-tsukuyomi_qq_oauth=${'c' * 64}; Path=/; Secure; HttpOnly',
          },
        );
      }
      expect(request.url.path, '/api/auth/oauth/qq/native/complete');
      expect(request.headers['Cookie'], contains('__Host-tsukuyomi_qq_oauth='));
      expect(jsonDecode(request.body), {
        'state': state,
        'clientId': NativeQQSdk.appId,
        'accessToken': token,
        'openId': openId,
      });
      return http.Response(
        jsonEncode({
          'success': true,
          'data': {'redirect': '/user-center', if (pending) 'ticket': 'd' * 48},
        }),
        200,
        headers: pending
            ? {}
            : {
                'set-cookie': 'tsukuyomi_session=verified-session; Secure; HttpOnly, __Host-tsukuyomi_qq_oauth=; Max-Age=0',
              },
      );
    }),
  );

  test('SDK credentials use bound native exchange and return only verified site session', () async {
    final requests = <http.Request>[];
    final httpTransport = transport(requests);
    httpTransport.importCookies([
      const MapEntry('tsukuyomi_session', 'existing-session'),
    ]);
    final grant = await authorizeNativeQQ(
      target,
      httpTransport,
      NativeQQSdk(),
      isCurrent: () => true,
      bind: true,
    );
    expect(sdkCalls, 1);
    expect(requests, hasLength(2));
    expect(
      requests.first.headers['Cookie'],
      'tsukuyomi_session=existing-session',
    );
    expect(jsonDecode(requests.first.body)['action'], 'bind');
    expect(grant!.ticket, '');
    expect(grant.redirect, '/user-center');
    expect(grant.transport.sessionCookie, 'tsukuyomi_session=verified-session');
    expect(grant.transport.hasBinding, false);
    grant.transport.dispose();
  });
  test('new mobile identity retains its cookie-bound ticket for native email/account form', () async {
    final grant = await authorizeNativeQQ(
      target,
      transport([], pending: true),
      NativeQQSdk(),
      isCurrent: () => true,
    );
    expect(grant!.ticket, 'd' * 48);
    expect(grant.transport.hasBinding, true);
    expect(grant.transport.sessionCookie, null);
    grant.transport.dispose();
  });
  test(
    'wrong AppID or invalid state never launches QQ or sends its credentials',
    () async {
      for (final invalid in [
        transport([], appId: '1904951941'),
        transport([], flowState: 'invalid'),
      ]) {
        await expectLater(
          authorizeNativeQQ(
            target,
            invalid,
            NativeQQSdk(),
            isCurrent: () => true,
          ),
          throwsA(isA<ApiFailure>()),
        );
      }
      expect(sdkCalls, 0);
    },
  );
  test('changing account while QQ is open does not complete or replace the site session', () async {
    var current = true;
    final requests = <http.Request>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NativeQQSdk.channel,
      (_) async {
        current = false;
        return {
          'clientId': NativeQQSdk.appId,
          'accessToken': token,
          'openId': openId,
        };
      },
    );
    await expectLater(
      authorizeNativeQQ(
        target,
        transport(requests),
        NativeQQSdk(),
        isCurrent: () => current,
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(requests, hasLength(1));
  });
  test(
    'SDK cancel stops exchange and raw SDK errors cannot leak token details',
    () async {
      final requests = <http.Request>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        NativeQQSdk.channel,
        (_) async => throw PlatformException(code: 'cancelled'),
      );
      expect(
        await authorizeNativeQQ(
          target,
          transport(requests),
          NativeQQSdk(),
          isCurrent: () => true,
        ),
        null,
      );
      expect(requests, hasLength(1));
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        NativeQQSdk.channel,
        (_) async => throw PlatformException(code: 'provider', message: token),
      );
      await expectLater(
        NativeQQSdk().login(),
        throwsA(
          isA<ApiFailure>().having(
            (e) => '$e',
            'redacted',
            isNot(contains(token)),
          ),
        ),
      );
    },
  );
  testWidgets(
    'Android asks for QQ SDK consent before initialization and cancelling keeps password login available',
    (tester) async {
      final controller = RoomController(
        storage: MemoryStorage(),
        chat: FakeChat(),
        voice: SilentVoice(),
        site: SiteClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'success': true,
                'data': {'qqNativeAppId': NativeQQSdk.appId},
              }),
              200,
            ),
          ),
        ),
      );
      await controller.initialize();
      QQAuthGrant? grant;
      var completed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                grant = await showQQAuthorization(context, controller);
                completed = true;
              },
              child: const Text('QQ 登录'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('QQ 登录'));
      await tester.pumpAndSettle();
      expect(find.text('同意并打开 QQ'), findsOneWidget);
      expect(sdkCalls, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(completed, true);
      expect(grant, null);
      expect(sdkCalls, 0);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
