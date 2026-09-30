import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/core/site_repository.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';

http.Response _success(dynamic data, {String? cookie}) => http.Response(
  jsonEncode({'success': true, 'data': data}),
  200,
  headers: {'set-cookie': ?cookie},
);

Matcher get _changedIdentity => throwsA(
  isA<ApiFailure>().having((failure) => failure.status, 'status', 409),
);

void main() {
  test('issue #1: old-site retry cannot send the new-site session', () async {
    final oldResponse = Completer<http.Response>();
    final seen = <(String, String?, String)>[];
    var origin = 'https://old.example';
    final api = SiteClient(
      client: MockClient((request) async {
        seen.add((
          request.url.origin,
          request.headers['cookie'],
          request.url.path,
        ));
        if (request.url.origin == 'https://old.example') {
          return oldResponse.future;
        }
        return _success({
          'user': {'id': 'alice', 'username': 'alice'},
        }, cookie: 'tsukuyomi_session=new-service; Path=/; HttpOnly');
      }),
    )..setSessionCookie(origin, 'tsukuyomi_session=old-service');
    addTearDown(api.dispose);
    final repository = SiteRepository(
      api: api,
      storage: MemoryStorage(),
      site: () => origin,
      accountId: () => 'alice',
    );
    final pending = repository.read('/api/user/profile', private: true);
    final stopped = expectLater(pending, _changedIdentity);
    await Future<void>.delayed(Duration.zero);
    origin = 'https://new.example';
    await api.login(origin, 'alice', 'password');
    oldResponse.completeError(http.ClientException('old request timed out'));
    await stopped;
    expect(seen.where((request) => request.$1 == 'https://old.example'), [
      (
        'https://old.example',
        'tsukuyomi_session=old-service',
        '/api/user/profile',
      ),
    ]);
    expect(api.cookie, 'tsukuyomi_session=new-service');
  });

  test(
    'issue #1: relogin of the same account invalidates old retries',
    () async {
      final oldResponse = Completer<http.Response>();
      var reads = 0;
      final api =
          SiteClient(
            client: MockClient((request) async {
              if (request.url.path == '/api/auth/login') {
                return _success({
                  'user': {'id': 'alice', 'username': 'alice'},
                }, cookie: 'tsukuyomi_session=new-session; Path=/; HttpOnly');
              }
              reads++;
              if (reads == 1) return oldResponse.future;
              return _success({'bio': 'new session profile'});
            }),
          )..setSessionCookie(
            'https://same.example',
            'tsukuyomi_session=old-session',
          );
      addTearDown(api.dispose);
      final repository = SiteRepository(
        api: api,
        storage: MemoryStorage(),
        site: () => 'https://same.example',
        accountId: () => 'alice',
      );
      final stopped = expectLater(
        repository.read('/api/user/profile', private: true),
        _changedIdentity,
      );
      await Future<void>.delayed(Duration.zero);
      await api.login('https://same.example', 'alice', 'password');
      // Same account and URL must not deduplicate onto the obsolete request.
      final current = await repository.read('/api/user/profile', private: true);
      expect(current.data['bio'], 'new session profile');
      oldResponse.completeError(http.ClientException('old request timed out'));
      await stopped;
      expect(reads, 2);
    },
  );

  test(
    'issue #1: bound sessions are rejected before contacting another origin',
    () async {
      final requests = <http.Request>[];
      final api =
          SiteClient(
            client: MockClient((request) async {
              requests.add(request);
              return _success({});
            }),
          )..setSessionCookie(
            'https://trusted.example',
            'tsukuyomi_session=private',
          );
      addTearDown(api.dispose);
      await expectLater(
        api.request('https://other.example', 'GET', '/api/settings'),
        _changedIdentity,
      );
      expect(requests, isEmpty);
      await api.request('https://trusted.example', 'GET', '/api/settings');
      expect(requests.single.headers['cookie'], 'tsukuyomi_session=private');
    },
  );

  for (final demo in [true, false]) {
    test(
      'issue #2: voice settings retain the new conversation boundary (demo=$demo)',
      () async {
        final storage = MemoryStorage()
          ..value = RoomSettings(demo: demo, model: 'test');
        final chat = FakeChat();
        final controller = RoomController(
          storage: storage,
          chat: chat,
          site: FakeSite(),
          voice: SilentVoice(),
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        if (!demo) await controller.login('alice', 'password');
        await controller.send('previous topic');
        final oldId = controller.turns.single.id;
        final oldMemories = jsonEncode(controller.workspace.localMemories);
        await controller.startConversation();
        await controller.configure(controller.settings.copyWith(voice: 'nova'));
        expect(controller.settings.voice, 'nova');
        expect(controller.visibleTurns, isEmpty);
        expect(controller.turns.single.id, oldId);
        expect(storage.histories[controller.scope]!.single.id, oldId);
        expect(jsonEncode(controller.workspace.localMemories), oldMemories);
        await controller.send('new topic');
        expect(chat.lastContext, isEmpty);
        expect(controller.visibleTurns.single.user, 'new topic');
        expect(controller.turns, hasLength(2));
      },
    );
  }

  test(
    'issue #2: switching the service still reloads its separate history',
    () async {
      final storage = MemoryStorage()
        ..value = const RoomSettings(demo: false, model: 'test');
      final controller = RoomController(
        storage: storage,
        chat: FakeChat(),
        site: FakeSite(),
        voice: SilentVoice(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.send('first service');
      await controller.startConversation();
      final other = ChatTurn(
        id: 'other-service-history',
        user: 'second service',
        assistant: 'second answer',
        createdAt: DateTime.utc(2026, 9, 30),
      );
      storage.histories['https://other.example:guest'] = [other];
      await controller.configure(
        controller.settings.copyWith(siteUrl: 'https://other.example'),
      );
      expect(controller.visibleTurns.single.id, other.id);
      expect(storage.histories['https://yachiyo.hk:guest'], hasLength(1));
    },
  );

  test(
    'issue #3: cancelled A cleanup cannot unlock B while B is committing',
    () async {
      final storage = _ControlledDraftStorage();
      final chat = FakeChat();
      final controller = RoomController(
        storage: storage,
        chat: chat,
        site: FakeSite(),
        voice: SilentVoice(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      storage.blockInitialDraft = true;
      final first = controller.send('A');
      await storage.initialDraftReached.future;
      controller.stop();
      storage.blockFinalDraft = true;
      final second = controller.send('B');
      await storage.finalDraftReached.future;
      expect(controller.generating, isTrue);
      expect(controller.sendingText, 'B');
      expect(controller.partial, chat.answer);
      storage.releaseInitialDraft.complete();
      await first;
      // A's finally must not release B's critical write. A stop attempted here
      // must leave B's displayed reply and generation state intact.
      controller.stop();
      expect(controller.generating, isTrue);
      expect(controller.canSend, isFalse);
      expect(controller.partial, chat.answer);
      expect(controller.sendingText, 'B');
      storage.releaseFinalDraft.complete();
      await second;
      expect(controller.generating, isFalse);
      expect(controller.canSend, isTrue);
      expect(controller.turns.single.user, 'B');
    },
  );

  test(
    'issue #3: a completed reply is saved atomically before another send',
    () async {
      final storage = _ControlledDraftStorage();
      final chat = FakeChat();
      final controller = RoomController(
        storage: storage,
        chat: chat,
        site: FakeSite(),
        voice: SilentVoice(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      storage.blockFinalDraft = true;
      final first = controller.send('A');
      await storage.finalDraftReached.future;
      controller.stop();
      await controller.send('B before saving finishes');
      expect(controller.generating, isTrue);
      expect(controller.sendingText, 'A');
      expect(controller.turns.single.user, 'A');
      storage.releaseFinalDraft.complete();
      await first;
      chat.controlled = true;
      final second = controller.send('B');
      await Future<void>.delayed(Duration.zero);
      chat.stream!.add('B partial');
      await Future<void>.delayed(Duration.zero);
      expect(controller.generating, isTrue);
      expect(controller.canSend, isFalse);
      expect(controller.sendingText, 'B');
      expect(controller.partial, 'B partial');
      await chat.stream!.close();
      await second;
      expect(controller.turns.map((turn) => turn.user), ['A', 'B']);
    },
  );
}

class _ControlledDraftStorage extends MemoryStorage {
  bool blockInitialDraft = false, blockFinalDraft = false;
  final initialDraftReached = Completer<void>();
  final releaseInitialDraft = Completer<void>();
  final finalDraftReached = Completer<void>();
  final releaseFinalDraft = Completer<void>();

  @override
  Future<void> saveDraft(String scope, String value) async {
    if (blockInitialDraft && scope == 'demo' && value == 'A') {
      blockInitialDraft = false;
      initialDraftReached.complete();
      await releaseInitialDraft.future;
    }
    if (blockFinalDraft && scope == 'demo' && value.isEmpty) {
      blockFinalDraft = false;
      finalDraftReached.complete();
      await releaseFinalDraft.future;
    }
    await super.saveDraft(scope, value);
  }
}
