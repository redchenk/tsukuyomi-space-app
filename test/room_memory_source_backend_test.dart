import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/room_memory_source.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';

const fixture = 'http://127.0.0.1:4184';
bool get enabled =>
    Platform.environment['RUN_SITE_FIXTURE'] == '1' ||
    const bool.fromEnvironment('RUN_SITE_FIXTURE');

Future<RoomController> fixtureRoom() async {
  final room = RoomController(
    storage: MemoryStorage()
      ..value = const RoomSettings(demo: false, siteUrl: fixture),
    site: SiteClient(),
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await room.initialize();
  addTearDown(room.dispose);
  return room;
}

Map<String, dynamic> fixtureMemory(String id, String prefix) => {
  'id': id,
  'type': 'preference',
  'summary': '$prefix $id',
  'content': '$prefix $id 我喜欢乌龙茶',
  'importance': .5,
  'confidence': .8,
  'tags': ['native-source-fixture'],
  'createdAt': roomMemoryTimestamp(
    DateTime.now().subtract(const Duration(seconds: 1)),
  ),
  'updatedAt': roomMemoryTimestamp(DateTime.now()),
};

Future<List<Map<String, dynamic>>> cloudRows(
  RoomController room,
  String query,
) async {
  final response = await room.workspace.request(
    'GET',
    '/api/room/memory?view=manage&limit=80&q=${Uri.encodeQueryComponent(query)}',
  );
  return ((response['data'] as Map)['items'] as List)
      .cast<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final overrides = HttpOverrides.current;
  setUp(() => HttpOverrides.global = null);
  tearDown(() => HttpOverrides.global = overrides);
  test(
    'latest original backend imports edited local copies, keeps zero scores and preserves cloud edits/deletions on retry',
    () async {
      final room = await fixtureRoom();
      final prefix = 'native-import-${DateTime.now().microsecondsSinceEpoch}';
      await room.workspace.saveMemory(fixtureMemory('one-$prefix', prefix));
      await room.workspace.saveMemory(fixtureMemory('two-$prefix', prefix));
      await room.login('reply-writer', 'mem0-test-password');
      try {
        await room.workspace.chooseMemorySource('local');
        final copy = room.workspace.localMemories.first;
        await room.workspace.saveMemory({
          ...copy,
          'content': '$prefix 本地编辑优先',
          'importance': 0,
          'confidence': 0,
        });
        await room.workspace.chooseMemorySource('merge');
        expect(room.workspace.memorySource, 'cloud');
        final rows = await cloudRows(room, prefix);
        expect(rows, hasLength(2));
        final edited = rows.singleWhere(
          (row) => row['summary'] == copy['summary'],
        );
        final detail = await room.workspace.memoryDetail(edited);
        expect(detail['content'], '$prefix 本地编辑优先');
        expect(detail['importance'], 0);
        expect(detail['confidence'], 0);
        await room.workspace.saveMemory({
          ...detail,
          'content': '$prefix 云端手工修改',
          'importance': 1,
          'confidence': 0,
        });
        final removed = rows.singleWhere((row) => row['id'] != edited['id']);
        await room.workspace.deleteMemory('${removed['id']}');
        await room.workspace.chooseMemorySource('merge');
        final retried = await cloudRows(room, prefix);
        expect(retried, hasLength(1));
        expect(
          (await room.workspace.memoryDetail(retried.single))['content'],
          '$prefix 云端手工修改',
        );
        await expectLater(
          room.workspace.request(
            'DELETE',
            '/api/room/memory?expectedUserId=another-account',
          ),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.status,
              'status',
              409,
            ),
          ),
        );
      } finally {
        for (final row in await cloudRows(room, prefix)) {
          await room.workspace.request(
            'DELETE',
            '/api/room/memory/${Uri.encodeComponent('${row['id']}')}',
          );
        }
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'logged-in local mode still syncs and edits chat while preserving existing cloud turn memories',
    () async {
      final room = await fixtureRoom();
      await room.login('reply-owner', 'mem0-test-password');
      final api = room.site as SiteClient;
      final prefix =
          'native-local-turn-${DateTime.now().microsecondsSinceEpoch}';
      final turn = ChatTurn(
        id: newTurnId(),
        user: '$prefix 我喜欢乌龙茶',
        assistant: '我会记住你喜欢乌龙茶。',
        createdAt: DateTime.now(),
      );
      try {
        await api.saveTurn(fixture, turn);
        await room.sync();
        final before = await cloudRows(room, prefix);
        expect(before, isNotEmpty);
        await room.workspace.chooseMemorySource('local');
        await room.send('$prefix 改为本地绿茶', replacement: room.turns.last);
        expect(room.error, isEmpty);
        expect((await api.history(fixture)).last.user, '$prefix 改为本地绿茶');
        expect(
          (await cloudRows(room, prefix)).map((row) => row['id']).toSet(),
          before.map((row) => row['id']).toSet(),
        );
        expect(
          room.workspace.localMemories.single['content'],
          contains('本地绿茶'),
        );
        await room.send('$prefix 新本地对话');
        expect(room.pendingCount, 0, reason: room.syncStatus);
        expect((await api.history(fixture)).last.user, '$prefix 新本地对话');
        expect(
          (await cloudRows(room, prefix)).map((row) => row['id']).toSet(),
          before.map((row) => row['id']).toSet(),
        );
      } finally {
        for (final row in await cloudRows(room, prefix)) {
          await room.workspace.request(
            'DELETE',
            '/api/room/memory/${Uri.encodeComponent('${row['id']}')}',
          );
        }
        // This fixture account's room data belongs only to this disposable test.
        await room.workspace.request('DELETE', '/api/room/chat');
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
