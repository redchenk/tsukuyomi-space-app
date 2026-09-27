import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/core/site_repository.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';

void main() {
  test('website recall enters LLM context, and expiry cannot reuse previous memory', () async {
    final requests = <Map<String, dynamic>>[];
    final chat = LlmClient(
      clientFactory: () => MockClient((request) async {
        requests.add(
          Map<String, dynamic>.from(jsonDecode(request.body) as Map),
        );
        expect(request.headers.keys, isNot(contains('cookie')));
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'reply'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final site = RecallSite();
    final controller = RoomController(
      storage: MemoryStorage()
        ..value = const RoomSettings(demo: false, model: 'test'),
      site: site,
      chat: chat,
      voice: SilentVoice(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.login('alice', 'test');
    await controller.send('hello');
    expect('${requests.last['messages']}', contains('remember-alice'));
    expect(site.recalls, 1);
    controller.expireSession();
    await controller.send('offline');
    expect('${requests.last['messages']}', isNot(contains('remember-alice')));
    expect(site.recalls, 1);
    expect(controller.pendingCount, 1);
  });

  test('offline restart restores account-scoped turns and draft, expired login resumes sync', () async {
    final storage = MemoryStorage()
      ..value = const RoomSettings(demo: false, model: 'test');
    final site = FakeSite();
    final c = RoomController(
      storage: storage,
      site: site,
      chat: FakeChat(),
      voice: SilentVoice(),
    );
    await c.initialize();
    await c.login('alice', 'pass');
    site.offline = true;
    await c.send('待同步');
    await c.saveComposerDraft('未发送的草稿');
    c.expireSession();
    await Future<void>.delayed(Duration.zero);
    c.dispose();
    final restored = RoomController(
      storage: storage,
      site: site,
      chat: FakeChat(),
      voice: SilentVoice(),
    );
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.account?.id, 'alice');
    expect(restored.sessionExpired, isTrue);
    expect(restored.draft, '未发送的草稿');
    expect(restored.pendingCount, 1);
    site.offline = false;
    await restored.login('alice', 'pass');
    expect(restored.pendingCount, 0);
    expect(site.data.length, 1);
    expect(restored.draft, '未发送的草稿');
    await restored.logout();
    expect(restored.turns, isEmpty);
    expect(restored.draft, isEmpty);
  });
  test('private disk cache does not cross accounts or origins; writes are not retried', () async {
    var offline = false, posts = 0;
    final api = SiteClient(
      client: MockClient((r) async {
        if (r.method == 'POST') posts++;
        if (offline) throw http.ClientException('offline');
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {'bio': 'alice-private'},
          }),
          200,
        );
      }),
    );
    addTearDown(api.dispose);
    String? owner = 'alice';
    var origin = 'https://example.com';
    final repo = SiteRepository(
      api: api,
      storage: MemoryStorage(),
      site: () => origin,
      accountId: () => owner,
    );
    expect(
      (await repo.read('/api/user/profile', private: true)).cached,
      isFalse,
    );
    expect(
      (await repo.cached('/api/user/profile', private: true))?.data['bio'],
      'alice-private',
    );
    offline = true;
    expect(
      (await repo.read('/api/user/profile', private: true)).cached,
      isTrue,
    );
    owner = 'bob';
    expect(await repo.cached('/api/user/profile', private: true), isNull);
    await expectLater(
      repo.read('/api/user/profile', private: true),
      throwsA(isA<ApiFailure>()),
    );
    owner = 'alice';
    origin = 'https://different.example';
    await expectLater(
      repo.read('/api/user/profile', private: true),
      throwsA(isA<ApiFailure>()),
    );
    await expectLater(
      repo.write('POST', '/api/messages', {'content': 'once'}),
      throwsA(isA<ApiFailure>()),
    );
    expect(posts, 1);
  });
  test(
    'late old-account response cannot change cookie or expire new account',
    () async {
      final reply = Completer<http.Response>();
      final api = SiteClient(client: MockClient((_) => reply.future));
      addTearDown(api.dispose);
      api.cookie = 'tsukuyomi_session=alice';
      var expired = 0;
      api.onUnauthorized = () => expired++;
      final request = api.request(
        'https://example.com',
        'GET',
        '/api/user/profile',
      );
      api.cookie = 'tsukuyomi_session=bob';
      reply.complete(
        http.Response(
          '{"success":false}',
          401,
          headers: {'set-cookie': 'tsukuyomi_session=old'},
        ),
      );
      await expectLater(
        request,
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 409)),
      );
      expect(api.cookie, 'tsukuyomi_session=bob');
      expect(expired, 0);
    },
  );
  test('timeout covers stalled response headers, and cookie never goes to another origin', () async {
    final api = SiteClient(
      client: MockClient((_) => Completer<http.Response>().future),
      timeout: const Duration(milliseconds: 10),
    );
    addTearDown(api.dispose);
    await expectLater(
      api.request('https://example.com', 'GET', '/api/user/profile'),
      throwsA(isA<ApiFailure>()),
    );
    await expectLater(
      api.request(
        'https://example.com',
        'GET',
        'https://other.example/api/user/profile',
      ),
      throwsA(isA<ApiFailure>()),
    );
  });
}

class RecallSite extends FakeSite implements SiteDataService {
  int recalls = 0;
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    recalls++;
    return {
      'success': true,
      'data': [
        {'context': 'remember-$userId'},
      ],
    };
  }
}
