import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/room/shared_room_page.dart';
import 'package:tsukuyomi_space_app/features/site/login_dialog.dart';
import 'package:tsukuyomi_space_app/features/site/native_auth_page.dart';
import 'package:tsukuyomi_space_app/features/site/site_guide.dart';
import 'package:tsukuyomi_space_app/main.dart';

import 'support/fakes.dart';

class _LoadingStorage extends MemoryStorage {
  final gate = Completer<RoomSettings>();
  @override
  Future<RoomSettings> settings() => gate.future;
}

class _ShareSite extends FakeSite implements SiteDataService {
  int reads = 0;
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path.startsWith('/api/room/shares/')) {
      reads++;
      return {
        'success': true,
        'data': {
          'shareKey': 'public-1',
          'userMessage': '公开问题',
          'assistantMessage': '公开回答',
          'scene': {'city': '公开月城'},
        },
      };
    }
    return {'success': true, 'data': <String, dynamic>{}};
  }
}

void main() {
  testWidgets('protected actions use full native auth and resume after login', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final c = RoomController(
      storage: MemoryStorage(),
      chat: FakeChat(),
      voice: SilentVoice(),
      site: SiteClient(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'success': true,
              'data': request.url.path == '/api/auth/login'
                  ? {
                      'user': {
                        'id': 'alice',
                        'username': 'Alice',
                        'role': 'user',
                      },
                    }
                  : <String, dynamic>{},
            }),
            200,
            headers: {
              'content-type': 'application/json',
              if (request.url.path == '/api/auth/login')
                'set-cookie': 'tsukuyomi_session=auth.flow; HttpOnly; Path=/',
            },
          );
        }),
      ),
    );
    await c.initialize();
    addTearDown(c.dispose);
    var resumed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                await showSiteLogin(context, c);
                resumed = true;
              },
              child: const Text('开始登录'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始登录'));
    await tester.pumpAndSettle();
    expect(find.byType(NativeAuthPage), findsOneWidget);
    expect(find.byKey(const Key('auth-qq')), findsOneWidget);
    await tester.ensureVisible(find.text('还没有账号，去注册'));
    await tester.tap(find.text('还没有账号，去注册'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('auth-confirm')), findsOneWidget);
    await tester.ensureVisible(find.text('已有账号，去登录'));
    await tester.tap(find.text('已有账号，去登录'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('auth-name')));
    await tester.enterText(find.byKey(const Key('auth-name')), 'Alice');
    await tester.ensureVisible(find.byKey(const Key('auth-password')));
    await tester.enterText(
      find.byKey(const Key('auth-password')),
      'password123',
    );
    await tester.ensureVisible(find.byKey(const Key('auth-submit')));
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();
    expect(c.account?.id, 'alice');
    expect(resumed, isTrue);
    expect(find.byType(NativeAuthPage), findsNothing);
    expect(
      requests.where((r) => r.url.path == '/api/auth/login'),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'shared deep link waits for initialization and restores after account switch',
    (tester) async {
      final storage = _LoadingStorage(), site = _ShareSite();
      final c = RoomController(
        storage: storage,
        site: site,
        chat: FakeChat(),
        voice: SilentVoice(),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SharedRoomPage(
            controller: c,
            shareKey: 'public-1',
            onGo: (_) {},
            loadNative: false,
          ),
        ),
      );
      expect(site.reads, 0);
      final initialization = c.initialize();
      storage.gate.complete(const RoomSettings());
      await initialization;
      await tester.pumpAndSettle();
      expect(site.reads, 1);
      expect(c.sharedConversation?['shareKey'], 'public-1');
      expect(c.workspace.currentWorld['city'], '公开月城');
      expect(c.turns, isEmpty);
      await c.login('alice', 'password');
      await tester.pumpAndSettle();
      expect(site.reads, 2);
      expect(c.sharedConversation?['shareKey'], 'public-1');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(c.sharedConversation, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'global guide opens through Navigator overlay and stays hidden on private room',
    (tester) async {
      final c = RoomController(
        storage: MemoryStorage(),
        site: _ShareSite(),
        chat: FakeChat(),
        voice: SilentVoice(),
      );
      await c.initialize();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        TsukuyomiApp(controller: c, initialPath: '/hub', loadNative: false),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SiteGuideButton), findsOneWidget);
      await tester.tap(find.byType(SitePet));
      await tester.pumpAndSettle();
      expect(find.text('八千代向导'), findsWidgets);
      expect(tester.takeException(), isNull);
      final dialog = tester.element(find.byType(Dialog));
      Navigator.of(dialog).pop();
      await tester.pumpAndSettle();
      final petContext = tester.element(find.byType(SiteGuideButton));
      // The navigation uses the actual app navigator beneath the global overlay.
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      navigator.pushNamed('/room');
      await tester.pumpAndSettle();
      expect(find.byType(SiteGuideButton), findsNothing);
      expect(petContext.mounted, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
