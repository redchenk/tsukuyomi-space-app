import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';

import 'support/site_fixture.dart';

void main() {
  test('native NetEase API uses real private sessions, QR rotation and website owner isolation', () async {
    const site = siteFixtureOrigin;
    final client = SiteClient();
    addTearDown(client.dispose);
    await client.login(site, 'e2e-user', 'e2e-password');
    final before = client.cookie;
    final status = await client.request(site, 'GET', '/api/music/status');
    expect(status['enabled'], true);
    expect(status['profile'], null);
    final qr = await client.request(site, 'POST', '/api/music/qr', {});
    expect(Uri.parse(qr['url']).host, 'music.163.com');
    expect(qr['qrId'], isNotEmpty);
    final authorized = await client.request(
      site,
      'POST',
      '/api/music/qr/check',
      {'qrId': qr['qrId']},
    );
    expect(authorized['status'], 'authorized');
    expect(authorized['profile']['id'], '101');
    final search = await client.request(
      site,
      'GET',
      '/api/music/search?q=fixture&offset=20',
    );
    expect(search['tracks'].single['id'], '21');
    expect(search['total'], 40);
    expect(
      (await client.request(
        site,
        'GET',
        '/api/music/playlists?offset=0',
      ))['playlists'].single['id'],
      '201',
    );
    expect(
      (await client.request(
        site,
        'GET',
        '/api/music/playlists/201?offset=0',
      ))['tracks'].single['id'],
      '1',
    );
    final playback = await client.request(
      site,
      'GET',
      '/api/music/tracks/1/playback',
    );
    expect(playback['url'], 'https://music-fixture.example/audio.mp3');
    // Switching website identity cannot access the previous owner's private library.
    client.setSessionCookie(site, null);
    await expectLater(
      client.request(site, 'GET', '/api/music/search?q=fixture'),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 401)),
    );
    client.setSessionCookie(site, before);
    expect((await client.me(site)).username, 'e2e-user');
    await client.request(site, 'POST', '/api/music/logout', {});
    expect(
      (await client.request(site, 'GET', '/api/music/status'))['profile'],
      null,
    );
    expect((await client.me(site)).username, 'e2e-user');
  }, skip: !const bool.fromEnvironment('RUN_WEBSITE_INTEGRATION'));
}
