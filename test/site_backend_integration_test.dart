import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';

// Run against the website's isolated tests/e2e-server.cjs, never a production account.
void main() {
  test('native client shares website auth, chat, memory, articles, plaza, growth and profile contracts', () async {
    const site = 'http://127.0.0.1:4184';
    final api = SiteClient();
    addTearDown(api.dispose);
    final user = await api.login(site, 'e2e-user', 'e2e-password');
    expect((await api.me(site)).id, user.id);
    final turn = ChatTurn(
      id: newTurnId(),
      user: '我喜欢观星。',
      assistant: '一起看看星空吧。',
      createdAt: DateTime.now(),
    );
    await api.saveTurn(site, turn);
    await api.saveTurn(site, turn);
    expect((await api.history(site)).where((t) => t.id == turn.id).length, 1);
    final memory = await api.request(site, 'POST', '/api/room/memory', {
      'content': '原生客户端的测试记忆：喜欢月亮。',
      'summary': '喜欢月亮',
      'type': 'fact',
      'captureChat': false,
    });
    final memoryData = memory['data'] is List
        ? (memory['data'] as List).first
        : memory['data'];
    expect(memoryData['id'], isNotNull);
    final id = memoryData['id'];
    await api.request(site, 'PUT', '/api/room/memory/$id', {
      'content': '编辑后的记忆。',
      'summary': '已编辑',
    });
    final memories = await api.request(
      site,
      'GET',
      '/api/room/memory?view=manage',
    );
    expect(
      (memories['data']['items'] as List).any(
        (m) => m['id'] == id && m['summary'] == '已编辑',
      ),
      isTrue,
    );
    expect(
      (await api.request(
        site,
        'GET',
        '/api/room/memory/$id',
      ))['data']['content'],
      '编辑后的记忆。',
    );
    await api.request(site, 'DELETE', '/api/room/memory/$id');
    await expectLater(
      api.request(site, 'GET', '/api/room/memory/$id'),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 404)),
    );
    final articles = await api.request(site, 'GET', '/api/articles?limit=6');
    expect(articles['data'], isNotEmpty);
    final articleId = articles['data'][0]['id'];
    final article = await api.request(site, 'GET', '/api/articles/$articleId');
    expect(article['data']['content'], isNotEmpty);
    expect(article['reading']['token'], isNotEmpty);
    expect(api.readerCookies[site], startsWith('tsukuyomi_reader='));
    await api.request(site, 'POST', '/api/user/bookmarks/$articleId');
    expect(
      (await api.request(
        site,
        'GET',
        '/api/user/bookmarks/$articleId/status',
      ))['data']['bookmarked'],
      isTrue,
    );
    await api.request(site, 'POST', '/api/user/article-likes/$articleId');
    expect(
      (await api.request(
        site,
        'GET',
        '/api/user/article-likes/$articleId/status',
      ))['data']['liked'],
      isTrue,
    );
    final post = await api.request(site, 'POST', '/api/messages', {
      'content': '原生客户端联调：今晚月色很好。',
    });
    final messageId = post['data']['id'];
    await api.request(site, 'POST', '/api/messages/$messageId/reply', {
      'content': '测试回复。',
    });
    final messages =
        (await api.request(site, 'GET', '/api/messages'))['data'] as List;
    expect(messages.any((m) => m['parent_id'] == messageId), isTrue);
    await api.request(site, 'PUT', '/api/user/profile', {'bio': '来自原生应用的简介'});
    expect(
      (await api.request(site, 'GET', '/api/user/profile'))['data']['bio'],
      '来自原生应用的简介',
    );
    await api.request(site, 'POST', '/api/growth/check-in');
    final checkin = await api.request(site, 'POST', '/api/growth/check-in');
    expect(checkin['data']['award']['awarded'], isFalse);
    expect(
      (await api.request(
        site,
        'GET',
        '/api/growth/me',
      ))['data']['today']['tasks'],
      isNotEmpty,
    );
    await api.request(site, 'POST', '/api/growth/actions/share', {
      'platform': 'copy',
    });
    final shared = await api.request(
      site,
      'POST',
      '/api/growth/actions/share',
      {'platform': 'copy'},
    );
    expect(shared['data']['award']['awarded'], isFalse);
    await Future<void>.delayed(const Duration(seconds: 13));
    final receipt = await api.request(
      site,
      'POST',
      '/api/articles/$articleId/read',
      {'token': article['reading']['token']},
    );
    expect(receipt['data']['viewCount'], isA<num>());
    final oldCookie = api.cookie;
    await api.logout(site);
    api.cookie = oldCookie;
    await expectLater(
      api.me(site),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 401)),
    );
    await api.login(site, 'e2e-user', 'e2e-password');
    expect((await api.history(site)).any((t) => t.id == turn.id), isTrue);
  }, skip: !const bool.fromEnvironment('RUN_WEBSITE_INTEGRATION'));
}
