import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/room_events.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';

class RealtimeSite extends FakeSite implements SiteRoomEventService {
  final streams = <StreamController<RoomServerEvent>>[];
  @override
  Stream<RoomServerEvent> roomEvents(String site) {
    final stream = StreamController<RoomServerEvent>();
    streams.add(stream);
    return stream.stream;
  }
}

void main() {
  test('named events preserve Unicode and multiline data across byte chunks', () async {
    const raw =
        ': heartbeat\r\nevent: memory\r\nid: revision-1\r\ndata: {"action":"updated",\r\ndata: "summary":"月光🌙"}\r\n\r\nevent: chat\ndata: {"action":"cleared"}\n\nevent: memory\ndata: {"truncated":true}';
    final events = await decodeRoomEvents(
      Stream.fromIterable(utf8.encode(raw).map((byte) => [byte])),
    ).toList();
    expect(events.length, 2);
    expect(events.first.type, 'memory');
    expect(events.first.id, 'revision-1');
    expect(events.first.data['summary'], '月光🌙');
    expect(events.last.type, 'chat');
  });
  test('malformed events cannot hide following valid events', () async {
    final events = await decodeRoomEvents(
      Stream.value(
        utf8.encode(
          'event: memory\ndata: not-json\n\nevent: chat\ndata: {"action":"updated"}\n\n',
        ),
      ),
    ).toList();
    expect(events.single.type, 'chat');
  });
  test('public shared turn participates in context without entering private history', () async {
    final storage = MemoryStorage(), chat = FakeChat(), site = FakeSite();
    final c = RoomController(
      storage: storage,
      chat: chat,
      site: site,
      voice: SilentVoice(),
    );
    await c.initialize();
    addTearDown(c.dispose);
    await c.send('我的私人问题');
    final old = c.turns.single;
    c.workspace.world = {'city': '私人环境'};
    c.showSharedConversation({
      'shareKey': 'public-1',
      'title': '公开片段',
      'userMessage': '公开问题',
      'assistantMessage': '公开回答',
      'scene': {'city': '分享城市'},
    });
    expect(c.visibleTurns.single.user, '公开问题');
    expect(c.turns.single.id, old.id);
    expect(c.workspace.currentWorld['city'], '分享城市');
    await c.send('继续这个公开话题');
    expect(chat.lastContext.single.user, '公开问题');
    expect(c.turns.any((turn) => turn.id.startsWith('shared-')), isFalse);
    expect(
      storage.histories[c.scope]!.any((turn) => turn.id.startsWith('shared-')),
      isFalse,
    );
    c.leaveSharedConversation(shareKey: 'public-1');
    expect(c.visibleTurns.length, 2);
    expect(c.workspace.currentWorld['city'], '私人环境');
  });
  test(
    'realtime chat updates synchronize server edits and clear events',
    () async {
      final site = RealtimeSite();
      final storage = MemoryStorage()..value = const RoomSettings(demo: false);
      final room = RoomController(
        storage: storage,
        chat: FakeChat(),
        site: site,
        voice: SilentVoice(),
      );
      await room.initialize();
      await room.login('alice', 'password');
      addTearDown(room.dispose);
      final stream = site.streams.last;
      site.data['remote'] = ChatTurn(
        id: 'remote',
        user: '另一设备问题',
        assistant: '另一设备回答',
        createdAt: DateTime.now(),
      );
      stream.add(const RoomServerEvent('chat', {'action': 'turn-saved'}));
      await Future<void>.delayed(const Duration(milliseconds: 230));
      expect(room.turns.single.id, 'remote');
      site.data.clear();
      stream.add(const RoomServerEvent('chat', {'action': 'cleared'}));
      await Future<void>.delayed(const Duration(milliseconds: 230));
      expect(room.turns, isEmpty);
      final revision = room.memoryRevision;
      stream.add(const RoomServerEvent('memory', {'action': 'updated'}));
      await Future<void>.delayed(const Duration(milliseconds: 230));
      expect(room.memoryRevision, revision + 1);
      await room.logout();
      stream.add(const RoomServerEvent('memory', {'action': 'updated'}));
      await Future<void>.delayed(const Duration(milliseconds: 230));
      expect(room.memoryRevision, revision + 1);
      for (final controller in site.streams) {
        await controller.close();
      }
    },
  );
  test('OAuth session adoption verifies origin and identity before replacing account', () async {
    final site = FakeSite();
    final room = RoomController(
      storage: MemoryStorage(),
      chat: FakeChat(),
      site: site,
      voice: SilentVoice(),
    );
    await room.initialize();
    addTearDown(room.dispose);
    await room.login('alice', 'password');
    site.userId = 'bob';
    await expectLater(
      room.acceptSiteSession('https://example.org', 'tsukuyomi_session=jwt'),
      throwsA(isA<ApiFailure>()),
    );
    expect(room.account!.id, 'alice');
    await room.acceptSiteSession(
      room.settings.siteUrl,
      'tsukuyomi_session=valid.jwt',
    );
    expect(room.account!.id, 'bob');
    expect(
      (room.storage as MemoryStorage).secrets.values,
      contains('tsukuyomi_session=valid.jwt'),
    );
  });
}
