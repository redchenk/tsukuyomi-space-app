import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/music_playback_order.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/music_library.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';

const token =
    'tsukuyomi_music=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
http.Response ok(Map<String, dynamic> body, {String? cookie}) => http.Response(
  jsonEncode({'success': true, ...body}),
  200,
  headers: {'content-type': 'application/json', 'set-cookie': ?cookie},
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('closing the drawer cancels QR authorization but retains selected playback resolution', () async {
    final gate = Completer<http.Response>();
    final client = SiteClient(client: MockClient((_) => gate.future));
    addTearDown(client.dispose);
    final room = RoomController(
      storage: MemoryStorage(),
      chat: FakeChat(),
      site: client,
      voice: SilentVoice(),
    );
    addTearDown(room.dispose);
    final library = MusicLibrary(
      room,
      useLocal: () {},
      playTracks: (_, _) async {},
    );
    addTearDown(library.dispose);
    final pending = library.request('/tracks/1/playback');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    library.setOpen(false);
    gate.complete(ok({'url': 'https://music.example/song.mp3'}));
    expect((await pending)['url'], 'https://music.example/song.mp3');
  });
  test(
    'four queue modes distinguish automatic completion and manual navigation',
    () {
      final order = MusicPlaybackOrder(random: Random(7));
      expect(
        order.next(2, 3, MusicPlaybackMode.sequence, automatic: true),
        null,
      );
      expect(order.next(2, 3, MusicPlaybackMode.sequence), 0);
      expect(order.next(2, 3, MusicPlaybackMode.loop, automatic: true), 0);
      expect(order.next(1, 3, MusicPlaybackMode.single, automatic: true), 1);
      expect(order.next(1, 3, MusicPlaybackMode.single), 2);
      order.reset(0, 4);
      final played = [0];
      for (var i = 0; i < 3; i++) {
        played.add(order.next(played.last, 4, MusicPlaybackMode.shuffle)!);
      }
      expect(played.toSet().length, 4);
      expect(
        order.previous(played.last, 4, MusicPlaybackMode.shuffle),
        played[2],
      );
      expect(order.next(played[2], 4, MusicPlaybackMode.shuffle), played[3]);
    },
  );
  test('music cookie is purpose-scoped, rotates, and never expires site login on 401', () async {
    final requests = <http.Request>[];
    var unauthorized = 0;
    final saved = <String?>[];
    final client =
        SiteClient(
            client: MockClient((r) async {
              requests.add(r);
              if (r.url.path.endsWith('/qr')) {
                return ok({
                  'qrId': 'fixture',
                }, cookie: '$token; Path=/api/music; HttpOnly');
              }
              if (r.url.path.endsWith('/search')) {
                return http.Response(
                  '{"success":false,"message":"请扫码"}',
                  401,
                  headers: {
                    'set-cookie':
                        'tsukuyomi_music=; Path=/api/music; Max-Age=0',
                    'content-type': 'application/json; charset=utf-8',
                  },
                );
              }
              return ok({});
            }),
          )
          ..onUnauthorized = () {
            unauthorized++;
          }
          ..onMusicCookie = (_, value) => saved.add(value);
    addTearDown(client.dispose);
    client.setSessionCookie('https://site.example', 'tsukuyomi_session=site');
    await client.request('https://site.example', 'POST', '/api/music/qr', {});
    await client.request('https://site.example', 'GET', '/api/music/status');
    expect(requests.last.headers['cookie'], contains(token));
    expect(requests.last.headers['origin'], 'https://site.example');
    expect(requests.last.headers['x-requested-with'], 'XMLHttpRequest');
    await client.request('https://site.example', 'GET', '/api/articles');
    expect(requests.last.headers['cookie'], isNot(contains('tsukuyomi_music')));
    await expectLater(
      client.request('https://site.example', 'GET', '/api/music/search'),
      throwsA(isA<ApiFailure>()),
    );
    expect(unauthorized, 0);
    expect(client.cookie, 'tsukuyomi_session=site');
    expect(saved, [token, null]);
  });
  test(
    'a late authorized response cannot rotate a cancelled music session',
    () async {
      final gate = Completer<http.Response>();
      final saved = <String?>[];
      final client = SiteClient(client: MockClient((_) => gate.future))
        ..onMusicCookie = (_, value) => saved.add(value);
      addTearDown(client.dispose);
      final pending = client.request(
        'https://site.example',
        'POST',
        '/api/music/qr/check',
        {'qrId': 'fixture'},
      );
      await Future<void>.delayed(Duration.zero);
      client.cancelMusicRequests();
      gate.complete(
        ok({'status': 'authorized'}, cookie: '$token; Path=/api/music'),
      );
      await expectLater(pending, throwsA(isA<ApiFailure>()));
      expect(saved, isEmpty);
    },
  );
  test('library uses actual backend envelope, paging does not alter playback queue', () async {
    var plays = 0, local = 0;
    final requests = <String>[];
    final api = SiteClient(
      client: MockClient((r) async {
        requests.add(r.url.toString());
        if (r.url.path.endsWith('/status')) {
          return ok({
            'enabled': true,
            'profile': {'id': 'netease-1', 'nickname': 'fixture'},
          });
        }
        if (r.url.path.endsWith('/search')) {
          return ok({
            'tracks': [
              {'id': '1', 'title': 'fixture'},
            ],
            'total': 40,
          });
        }
        return ok({});
      }),
    );
    final room = RoomController(
      storage: MemoryStorage(),
      chat: FakeChat(),
      site: api,
      voice: SilentVoice(),
    );
    addTearDown(room.dispose);
    final library = MusicLibrary(
      room,
      useLocal: () => local++,
      playTracks: (track, queue) async {
        plays++;
        expect(queue.single['id'], '1');
      },
    );
    addTearDown(library.dispose);
    library.setOpen(true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    library.query = '歌';
    await library.browse('search');
    expect(library.more, true);
    await library.play(library.results.first);
    expect(plays, 1);
    await library.browse('search', page: 20);
    expect(plays, 1);
    expect(library.offset, 20);
    expect(requests.last, contains('offset=20'));
    expect(local, 0);
    library.setOpen(false);
  });
}
