import 'support/site_fixture.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/site/site_notification.dart';

// Disposable original Express/SQLite backend started by site_room_fixture.cjs.
void main() {
  test('real notification and Hub contracts survive read, read-all and account isolation', () async {
    const site = siteFixtureOrigin;
    final recipient = SiteClient(), actor = SiteClient();
    addTearDown(recipient.dispose);
    addTearDown(actor.dispose);
    await recipient.login(site, 'e2e-user', 'e2e-password');
    await actor.login(site, 'reply-writer', 'mem0-test-password');
    await recipient.request(site, 'POST', '/api/user/notifications/read-all');
    final created = await recipient.request(site, 'POST', '/api/messages', {
      'content': '通知契约回归：${DateTime.now().microsecondsSinceEpoch}',
    });
    final messageId = created['data']['id'];
    for (var i = 0; i < 2; i++) {
      await actor.request(site, 'POST', '/api/messages/$messageId/reply', {
        'content': '来自另一个账号的回复 $i',
      });
    }
    final response = await recipient.request(
      site,
      'GET',
      '/api/user/notifications?limit=12&page=1',
    );
    final rows = (response['data'] as List)
        .map((row) => SiteNotification(Map<String, dynamic>.from(row as Map)))
        .toList();
    final unread = rows.where((row) => row.unread).toList();
    expect(unread.length, 2);
    expect(response['unread'], 2);
    expect(unread.first.data.containsKey('is_read'), isFalse);
    expect(unread.first.link, contains('/plaza'));
    await expectLater(
      actor.request(
        site,
        'POST',
        '/api/user/notifications/${unread.first.id}/read',
      ),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 404)),
    );
    final read = await recipient.request(
      site,
      'POST',
      '/api/user/notifications/${unread.first.id}/read',
    );
    expect(
      SiteNotification(Map<String, dynamic>.from(read['data'] as Map)).unread,
      isFalse,
    );
    expect(read['data']['read_at'], isNotEmpty);
    expect(read['unread'], 1);
    final refreshed = await recipient.request(
      site,
      'GET',
      '/api/user/notifications?limit=12&page=1',
    );
    expect(
      (refreshed['data'] as List)
          .where((row) => row['id'].toString() == unread.first.id)
          .single['unread'],
      isFalse,
    );
    final all = await recipient.request(
      site,
      'POST',
      '/api/user/notifications/read-all',
    );
    expect(all['data']['count'], 0);
    final after = await recipient.request(
      site,
      'GET',
      '/api/user/notifications?limit=12&page=1',
    );
    expect(after['unread'], 0);
    expect(
      (after['data'] as List).every((row) => row['unread'] == false),
      isTrue,
    );
    final hub = await recipient.request(site, 'GET', '/api/hub-preview');
    expect(hub['success'], isTrue);
    expect(hub['data'], isA<Map>());
    expect(hub['data']['stats'], isA<Map>());
    expect(hub['data']['article'], isA<Map>());
    final settings = await recipient.request(site, 'GET', '/api/settings');
    expect(settings['success'], isTrue);
    expect(settings['data'], isA<Map>());
  }, skip: !const bool.fromEnvironment('RUN_WEBSITE_INTEGRATION'));
}
