import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';

void main() {
  test('Room actual website backend: images, optimistic edits, share revoke, diary sync and auth recovery', () async {
    const origin = 'http://127.0.0.1:4184';
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6eioAAAAASUVORK5CYII=';
    final site = SiteClient();
    final store = MemoryStorage()
      ..value = const RoomSettings(
        demo: false,
        siteUrl: origin,
        model: 'fixture',
      );
    final chat = FakeChat();
    final c = RoomController(
      storage: store,
      chat: chat,
      site: site,
      voice: SilentVoice(),
      diaryClientFactory: () =>
          FakeChat()..answer = '今天与来访者聊了月色。我们交换了当天的心情，我把这些轻轻的笑声记在这一页，等待下次重逢。',
    );
    await c.initialize();
    await c.login('e2e-user', 'e2e-password');
    addTearDown(c.dispose);
    await c.startConversation(clearHistory: true);
    await c.attach({
      'name': 'native-test.png',
      'type': 'image/png',
      'dataUrl': png,
    });
    await c.send('图片测试');
    expect(c.error, isEmpty);
    expect(c.pendingCount, 0, reason: c.syncStatus);
    expect(c.turns.single.image?['id'], isNotNull, reason: c.syncStatus);
    await c.send('我喜欢观星。');
    final old = c.turns.last;
    chat.answer = '那我们约好，下次一起看星星。';
    await c.send('我喜欢看月亮。', replacement: old);
    expect(c.error, isEmpty);
    expect((await site.history(origin)).last.user, '我喜欢看月亮。');
    // A different-device edit must cause a conflict, preserving the authoritative turn.
    await site.request(origin, 'PUT', '/api/room/chat/turn/${old.id}', {
      'expectedUserMessage': c.turns.last.user,
      'expectedAssistantMessage': c.turns.last.assistant,
      'userMessage': '另一台设备修改',
      'assistantMessage': '保留另一台的回复。',
      'memoryEnabled': false,
    });
    await c.send('过时修改', replacement: c.turns.last);
    expect(c.error, isNotEmpty);
    expect((await site.history(origin)).last.user, '另一台设备修改');
    await c.sync();
    final asset = (await site.request(origin, 'POST', '/api/assets', {
      'dataUrl': png,
      'fileName': 'native-share.png',
      'mimeType': 'image/png',
      'alt': 'Native integration fixture',
      'storage': 'auto',
      'collection': 'share-card',
    }))['data'];
    final share = (await site.request(origin, 'POST', '/api/room/shares', {
      'turnId': old.id,
      'title': 'Native fixture',
      'ogImageAssetId': asset['id'],
      'scene': {
        'weather': 'clear',
        'timePhase': 'night',
        'season': 'autumn',
        'city': '测试房间',
      },
    }))['data'];
    expect(
      (await site.request(
        origin,
        'GET',
        '/api/room/shares/${share['shareKey']}',
      ))['data']['assistantMessage'],
      '保留另一台的回复。',
    );
    await site.request(
      origin,
      'DELETE',
      '/api/room/shares/${share['shareKey']}',
    );
    await expectLater(
      site.request(origin, 'GET', '/api/room/shares/${share['shareKey']}'),
      throwsA(isA<ApiFailure>().having((v) => v.status, 'status', 404)),
    );
    await c.workspace.archive.savePersona({'name': '日记测试作者'});
    await c.workspace.archive.sync();
    expect(c.workspace.archive.status, '已与网站同步');
    final diary = await c.finishDiary();
    expect(diary?['characterName'], '日记测试作者');
    expect(c.turns, isEmpty);
    final diaryRows =
        (await site.request(
              origin,
              'GET',
              '/api/room/diary',
            ))['data']['entries']
            as List;
    expect(diaryRows.any((e) => e['diaryId'] == diary!['diaryId']), true);
    expect(
      jsonDecode(c.workspace.archive.exportText())['data']['prompts'],
      isNotEmpty,
    );
    final id = diary!['diaryId'];
    await c.workspace.archive.delete('$id');
    await c.workspace.archive.sync();
    expect(
      ((await site.request(origin, 'GET', '/api/room/diary'))['data']['entries']
              as List)
          .any((v) => v['diaryId'] == id && v['deleted'] == true),
      true,
    );
    site.cookie = 'tsukuyomi_session=expired-fixture';
    await c.send('登录过期时暂存');
    expect(c.sessionExpired, true);
    expect(c.pendingCount, 1);
    await c.login('e2e-user', 'e2e-password');
    expect(c.pendingCount, 0);
    expect(c.turns.last.user, '登录过期时暂存');
  }, skip: !const bool.fromEnvironment('RUN_WEBSITE_INTEGRATION'));
}
