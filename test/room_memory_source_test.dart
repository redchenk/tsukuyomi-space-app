import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/room_memory_source.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/settings/room_memory_manager.dart';

import 'support/fakes.dart';

Map<String, dynamic> memory(String id, {String? content}) => {
  'id': id,
  'type': 'preference',
  'summary': '记忆 $id',
  'content': content ?? '我喜欢乌龙茶 $id',
  'importance': .5,
  'confidence': .8,
  'tags': ['测试'],
  'createdAt': '2026-01-01T00:00:00.000Z',
  'updatedAt': '2026-01-01T00:00:00.000Z',
};

class MemorySourceApi extends FakeSite implements SiteDataService {
  final calls = <(String, String, Map<String, dynamic>?)>[];
  final imports = <Map<String, dynamic>>[];
  final sentTurns = <ChatTurn>[];
  int? failImport;
  Completer<void>? importGate;
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    calls.add((method, path, body));
    if (path == '/api/room/memory/import') {
      imports.add(body!);
      if (importGate != null) await importGate!.future;
      if (imports.length == failImport) {
        throw const ApiFailure('offline', status: 503);
      }
      return {
        'data': {'imported': (body['records'] as List).length, 'skipped': 0},
      };
    }
    if (path == '/api/room/memory/status') {
      return {
        'data': {'count': 42, 'maxContentLength': 12000},
      };
    }
    return {
      'data': {'items': [], 'total': 0, 'hasMore': false},
    };
  }

  @override
  Future<void> saveTurn(String site, ChatTurn turn) async {
    sentTurns.add(turn);
    await super.saveTurn(site, turn);
  }
}

Future<(RoomController, MemorySourceApi, MemoryStorage)> room({
  bool demo = false,
  bool autoDispose = true,
}) async {
  final api = MemorySourceApi(),
      storage = MemoryStorage()..value = RoomSettings(demo: demo);
  final controller = RoomController(
    storage: storage,
    site: api,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await controller.initialize();
  if (autoDispose) addTearDown(controller.dispose);
  return (controller, api, storage);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('source fingerprint notices guest edits; batch validation keeps zero scores and byte/count caps', () {
    final row = memory('zero')..addAll({'importance': 0, 'confidence': 0});
    final original = guestRoomMemoryFingerprint([row]);
    expect(guestRoomMemoryFingerprint([row]), original);
    row['content'] = 'updated';
    expect(guestRoomMemoryFingerprint([row]), isNot(original));
    final batches = roomMemoryImportBatches([
      for (var i = 0; i < 201; i++) memory('$i'),
    ]);
    expect(batches.map((batch) => batch.length), [100, 100, 1]);
    final byteBatches = roomMemoryImportBatches([
      for (var i = 0; i < 30; i++) memory('$i', content: '月' * 12000),
    ]);
    expect(byteBatches.length, greaterThan(1));
    expect(
      byteBatches.every(
        (batch) => utf8.encode(jsonEncode(batch)).length < 700100,
      ),
      true,
    );
    expect(roomMemoryImportRecord(row)['importance'], 0);
    expect(roomMemoryImportRecord(row)['confidence'], 0);
    expect(
      () => roomMemoryImportBatches([
        row,
        memory('invalid')..['importance'] = '0.5',
      ]),
      throwsA(isA<ApiFailure>()),
    );
    expect(
      () =>
          roomMemoryImportRecord(memory('invalid')..['content'] = '月' * 12001),
      throwsA(isA<ApiFailure>()),
    );
  });

  test('explicit local choice copies guest records, retains edits, scopes demo accounts and re-prompts changed guests', () async {
    final (c, api, storage) = await room(demo: true);
    await c.workspace.saveMemory(memory('guest'));
    await c.login('alice', 'pw');
    await c.workspace.refreshMemoryChoice();
    expect(c.workspace.memoryChoiceVisible, true);
    expect(c.workspace.memorySource, 'cloud');
    expect(api.imports, isEmpty);
    await c.workspace.chooseMemorySource('local');
    expect(c.workspace.localMemoryKey, contains('user-local:alice'));
    final copy = c.workspace.localMemories.single;
    expect(copy['id'], 'user-local:alice:import:guest');
    await c.workspace.saveMemory({
      ...copy,
      'content': '我喜欢绿茶',
      'importance': 0,
      'confidence': 0,
    });
    await c.workspace.chooseMemorySource('local');
    expect(c.workspace.localMemories.single['content'], '我喜欢绿茶');
    await c.login('bob', 'pw');
    expect(c.workspace.localMemories, isEmpty);
    expect(c.workspace.memorySource, 'cloud');
    await c.workspace.chooseMemorySource('local');
    expect(c.workspace.localMemories.single['content'], contains('乌龙茶'));
    await c.login('alice', 'pw');
    expect(c.workspace.localMemories.single['content'], '我喜欢绿茶');
    expect(c.workspace.memorySource, 'local');
    await c.logout();
    expect(c.workspace.localMemories.single['content'], contains('乌龙茶'));
    await c.workspace.saveMemory({
      ...c.workspace.localMemories.single,
      'content': '访客记录新增细节',
    });
    await c.login('alice', 'pw');
    await c.workspace.refreshMemoryChoice();
    expect(c.workspace.memoryChoiceVisible, true);
    expect(
      storage.drafts.keys.where((key) => key.endsWith('.room-memories')).length,
      3,
    );
  });

  test('partial merge keeps local mode and originals; retries all bounded batches with edited copies taking precedence', () async {
    final (c, api, _) = await room();
    c.workspace.localMemories = [
      for (var i = 0; i < 101; i++) memory('guest-$i'),
    ];
    await c.workspace.persist();
    await c.login('alice', 'pw');
    await c.workspace.chooseMemorySource('local');
    final row = c.workspace.localMemories.first;
    await c.workspace.saveMemory({
      ...row,
      'content': '经过本地编辑的内容',
      'importance': 0,
    });
    api.failImport = 2;
    await expectLater(
      c.workspace.chooseMemorySource('merge'),
      throwsA(isA<ApiFailure>()),
    );
    expect(c.workspace.memorySource, 'local');
    expect(c.workspace.localMemories, hasLength(101));
    expect(api.imports.map((batch) => (batch['records'] as List).length), [
      100,
      1,
    ]);
    final submitted = api.imports
        .expand((batch) => (batch['records'] as List).cast<Map>())
        .toList();
    expect(submitted.any((row) => row['id'] == 'guest-0'), false);
    final edited = submitted.singleWhere(
      (row) => row['id'] == 'user-local:alice:import:guest-0',
    );
    expect(edited['content'], '经过本地编辑的内容');
    expect(edited['importance'], 0);
    api.failImport = null;
    await c.workspace.chooseMemorySource('merge');
    expect(c.workspace.memorySource, 'cloud');
    expect(api.imports, hasLength(4));
    expect(
      api.imports.every((batch) => batch['expectedUserId'] == 'alice'),
      true,
    );
    await c.logout();
    expect(c.workspace.localMemories, hasLength(101));
    expect(c.workspace.localMemories.first['content'], contains('乌龙茶'));
  });

  test('account change during import prevents an old choice changing the new account', () async {
    final (c, api, storage) = await room();
    await c.workspace.saveMemory(memory('guest'));
    await c.login('alice', 'pw');
    await c.workspace.chooseMemorySource('local');
    api.importGate = Completer<void>();
    final merging = c.workspace.chooseMemorySource('merge');
    final rejected = expectLater(merging, throwsA(isA<ApiFailure>()));
    for (var i = 0; i < 10 && api.imports.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(api.imports, hasLength(1));
    await c.login('bob', 'pw');
    api.importGate!.complete();
    await rejected;
    expect(c.workspace.memorySource, 'cloud');
    expect(c.workspace.localMemories, isEmpty);
    final aliceChoice = storage.drafts.entries.singleWhere(
      (entry) => entry.key.endsWith('roomMemorySource:alice'),
    );
    expect(jsonDecode(aliceChoice.value)['mode'], 'local');
  });

  test('local chat syncs text, remains local on retry after cloud selection and retrieves account-local context', () async {
    final (c, api, _) = await room();
    await c.workspace.saveMemory(memory('tea'));
    await c.login('alice', 'pw');
    await c.workspace.chooseMemorySource('local');
    final pack = await c.workspace.context('我喜欢喝什么？');
    expect(pack.text, contains('乌龙茶'));
    expect(
      api.calls.any(
        (call) => call.$2.startsWith('/api/room/memory?purpose=chat'),
      ),
      false,
    );
    api.offline = true;
    await c.send('我的茶叶选择');
    final pending = c.turns.single;
    expect(pending.pending, true);
    expect(pending.memorySource, 'local');
    expect(pending.localMemoryKey, c.workspace.localMemoryKey);
    await c.workspace.chooseMemorySource('cloud');
    api.offline = false;
    await c.sync();
    expect(c.turns.single.pending, false);
    expect(api.sentTurns.last.memorySource, 'local');
    expect(
      c.workspace.localMemories.any((row) => row['sourceTurnId'] == pending.id),
      true,
    );
  });

  test(
    'a queued cloud turn follows a newly chosen local source before upload',
    () async {
      final (c, api, _) = await room();
      await c.login('alice', 'pw');
      api.offline = true;
      await c.send('等待网络恢复的对话');
      expect(c.turns.single.memorySource, 'cloud');
      await c.workspace.chooseMemorySource('local');
      api.offline = false;
      await c.sync();
      expect(api.sentTurns.last.memorySource, 'local');
      expect(c.workspace.localMemories.single['content'], contains('等待网络恢复'));
    },
  );

  test('SiteClient local turn payload disables cloud capture without exporting the local partition key', () async {
    Map? payload;
    final api = SiteClient(
      client: MockClient((request) async {
        payload = jsonDecode(request.body) as Map;
        return http.Response('{"success":true,"data":{}}', 200);
      }),
    );
    addTearDown(api.dispose);
    final turn = ChatTurn(
      id: 'local',
      user: '用户',
      assistant: '八千代',
      createdAt: DateTime(2026),
      memorySource: 'local',
      localMemoryKey: 'account-local-secret-scope',
    );
    expect(
      ChatTurn.fromJson(turn.toJson()).synced().localMemoryKey,
      turn.localMemoryKey,
    );
    await api.saveTurn('http://localhost:4184', turn);
    expect(payload!['memoryEnabled'], false);
    expect(payload!['memorySource'], 'local');
    expect(payload!.containsKey('localMemoryKey'), false);
  });

  testWidgets(
    'memory scores support numeric zero, .01 sliders and reject invalid input',
    (tester) async {
      Map<String, dynamic>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showRoomRecordEditor(
                  tester.element(find.byType(TextButton)),
                  title: '编辑记忆',
                  value: memory('zero'),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final importance = find.byKey(const ValueKey('memory-importance-number'));
      final confidence = find.byKey(const ValueKey('memory-confidence-number'));
      expect(
        tester
            .widget<Slider>(
              find.byKey(const ValueKey('memory-importance-slider')),
            )
            .divisions,
        100,
      );
      await tester.ensureVisible(importance);
      await tester.enterText(importance, '-0.1');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('重要度和置信度请填写 0 到 1 的数值'), findsOneWidget);
      await tester.enterText(importance, '0');
      await tester.ensureVisible(confidence);
      await tester.enterText(confidence, '0');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result!['importance'], 0);
      expect(result!['confidence'], 0);
    },
  );

  testWidgets(
    'source chooser presents all three original choices and retains failed draft guard',
    (tester) async {
      final (c, _, _) = await room(autoDispose: false);
      await c.workspace.saveMemory(memory('guest'));
      await c.login('alice', 'pw');
      await c.workspace.refreshMemoryChoice();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RoomMemorySourcePanel(controller: c),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('使用本地数据'), findsOneWidget);
      expect(find.text('合并本地与云端数据'), findsOneWidget);
      expect(find.text('使用云端数据'), findsOneWidget);
      c.workspace.memoryDraftPending = true;
      await tester.tap(find.text('使用本地数据'));
      await tester.pumpAndSettle();
      expect(c.workspace.memorySource, 'cloud');
      expect(find.textContaining('请先保存或取消正在编辑的记忆'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
}
