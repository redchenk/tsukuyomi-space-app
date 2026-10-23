import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/official_tts.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/core/tts_client.dart';

import 'compatible_services_test.dart' show wav;
import 'support/fakes.dart';

const settings = RoomSettings(
  siteUrl: 'https://site.example',
  // Official synthesis must ignore all custom-provider addresses and secrets.
  ttsUrl: 'https://supplier.invalid/speech',
  ttsKey: 'must-not-leave-this-device',
  ttsModel: 'unused-custom-model',
  options: {
    'ttsProvider': 'official',
    'officialTtsAccount': 'alice',
    'officialTtsOrigin': 'https://site.example',
  },
);

class VoiceFixture {
  final site = FakeSite()..cookie = 'alice-session';
  bool online = true;
  String state = 'ready';
  int translations = 0, statusReads = 0, audioReads = 0;
  final posts = <Map<String, dynamic>>[];
  final paths = <String>[];
  Future<http.Response> Function(http.Request)? onPost, onAudio, onGet;
  String get id => 'req_voice_${List.filled(64, 'a').join()}';
  Map<String, dynamic> get job => {
    'id': id,
    'state': state,
    'chargedAtoms': state == 'ready' ? '50000000' : '0',
  };
  http.Response json(dynamic data, [int status = 200]) => http.Response(
    jsonEncode({'success': true, 'data': data}),
    status,
    headers: {'content-type': 'application/json'},
  );
  Future<String> prepare(String text, String language) async {
    translations++;
    expect(language, 'ja');
    return 'こんにちは。';
  }

  Future<http.Response> handle(http.Request request) async {
    expect(request.url.origin, 'https://site.example');
    expect(request.followRedirects, isFalse);
    expect(request.headers['origin'], 'https://site.example');
    expect(request.headers['authorization'], isNull);
    expect(request.headers['api-key'], isNull);
    paths.add('${request.method} ${request.url.path}');
    if (request.url.path.endsWith('/status')) {
      statusReads++;
      return json({
        'online': online,
        'priceAtoms': '50000000',
        'price': '0.05',
        'maxCharacters': 1000,
        'retentionHours': 24,
        'language': 'ja',
      });
    }
    expect(request.headers['cookie'], site.cookie);
    expect(request.headers['x-tts-account'], site.userId);
    if (request.method == 'POST') {
      final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      expect(body.keys.toSet(), {'text', 'requestKey'});
      expect(body['requestKey'], matches(RegExp(r'^[A-Za-z0-9_-]{16,100}$')));
      posts.add(body);
      return onPost == null ? json(job, 202) : onPost!(request);
    }
    if (request.url.path.endsWith('/audio')) {
      audioReads++;
      return onAudio == null
          ? http.Response.bytes(
              wav(),
              200,
              headers: {'content-type': 'audio/wav'},
            )
          : onAudio!(request);
    }
    return onGet == null ? json(job) : onGet!(request);
  }

  OfficialTtsClient client({
    Duration? timeout,
    Future<void> Function(Duration)? delay,
  }) => OfficialTtsClient(
    site: site,
    clientFactory: () => MockClient(handle),
    pollTimeout: timeout ?? const Duration(seconds: 110),
    delay: delay ?? (_) async {},
  );
}

Matcher failure(String text, [int? status]) => isA<ApiFailure>()
    .having((e) => e.message, 'message', contains(text))
    .having((e) => e.status, 'status', status);

void main() {
  test('official channel uses the fixed same-site job contract, not supplier keys or prices', () async {
    final fixture = VoiceFixture();
    final tts = TtsClient(clientFactory: () => MockClient(fixture.handle))
      ..siteService = fixture.site;
    final audio = await tts.synthesize(settings, officialTtsPreview);
    expect(audio.format, 'wav');
    expect(audio.bytes, wav());
    expect(fixture.posts.single['text'], officialTtsPreview);
    expect(
      fixture.paths.last,
      'GET /api/tts/official/jobs/${fixture.id}/audio',
    );
    tts.cancel();
  });

  test('valid replay reuses the job and prepared Japanese even when compute goes offline', () async {
    final f = VoiceFixture(), client = f.client();
    await client.synthesize(settings, '你好', prepareText: f.prepare);
    f.online = false;
    await client.synthesize(settings, '你好', prepareText: f.prepare);
    expect(f.translations, 1);
    expect(f.posts, hasLength(1));
    expect(f.audioReads, 2);
    expect(f.statusReads, 1);
  });

  test('offline preflight does not translate or submit a paid job', () async {
    final f = VoiceFixture()..online = false;
    await expectLater(
      f.client().synthesize(settings, '你好', prepareText: f.prepare),
      throwsA(failure('离线')),
    );
    expect(f.translations, 0);
    expect(f.posts, isEmpty);
    expect(f.audioReads, 0);
  });

  test(
    'settings audition and Room playback share the same paid job cache',
    () async {
      final f = VoiceFixture();
      final audition = f.client();
      await audition.synthesize(settings, '你好', prepareText: f.prepare);
      audition.cancel();
      final room = f.client();
      await room.synthesize(settings, '你好', prepareText: f.prepare);
      expect(f.posts, hasLength(1));
      expect(f.translations, 1);
      expect(f.audioReads, 2);
    },
  );

  test(
    'concurrent players share translation and submit the same request key',
    () async {
      final f = VoiceFixture();
      final translated = Completer<String>(), entered = Completer<void>();
      Future<String> prepare(String text, String language) async {
        f.translations++;
        entered.complete();
        return translated.future;
      }

      final a = f.client().synthesize(settings, '你好', prepareText: prepare);
      await entered.future;
      final b = f.client().synthesize(settings, '你好', prepareText: prepare);
      await Future<void>.delayed(Duration.zero);
      translated.complete('こんにちは。');
      await Future.wait([a, b]);
      expect(f.translations, 1);
      // Concurrent requests may both POST; the server deduplicates their key.
      expect(f.posts, isNotEmpty);
      expect(f.posts.map((p) => p['requestKey']).toSet(), hasLength(1));
      expect(f.posts.every((p) => p['text'] == 'こんにちは。'), isTrue);
    },
  );

  test(
    'lost POST response reuses both text and idempotency key on the next click',
    () async {
      final f = VoiceFixture();
      f.onPost = (_) async {
        if (f.posts.length == 1) {
          throw TimeoutException('server accepted job; response lost');
        }
        return f.json(f.job, 202);
      };
      final client = f.client();
      await expectLater(
        client.synthesize(settings, '你好', prepareText: f.prepare),
        throwsA(failure('超时')),
      );
      await client.synthesize(settings, '你好', prepareText: f.prepare);
      expect(f.posts, hasLength(2));
      expect(f.posts[1], f.posts[0]);
      expect(f.translations, 1);
    },
  );

  test('poll timeout preserves the job; the next click resumes without another POST', () async {
    final f = VoiceFixture()..state = 'processing';
    final client = f.client(timeout: Duration.zero);
    await expectLater(
      client.synthesize(settings, '你好', prepareText: f.prepare),
      throwsA(failure('仍在处理中')),
    );
    f.state = 'ready';
    await client.synthesize(settings, '你好', prepareText: f.prepare);
    expect(f.posts, hasLength(1));
    expect(f.translations, 1);
  });

  test(
    'server processing is polled rather than issuing another synthesis request',
    () async {
      final f = VoiceFixture()..state = 'processing';
      final client = f.client(
        delay: (_) async {
          f.state = 'ready';
        },
      );
      await client.synthesize(settings, '你好', prepareText: f.prepare);
      expect(f.posts, hasLength(1));
      expect(f.paths, contains('GET /api/tts/official/jobs/${f.id}'));
    },
  );

  test(
    'stop cannot promise a refund and retry keeps an uncertain job request key',
    () async {
      final f = VoiceFixture();
      final entered = Completer<void>(), reply = Completer<http.Response>();
      f.onPost = (_) async {
        if (f.posts.length == 1) {
          entered.complete();
          return reply.future;
        }
        return f.json(f.job, 202);
      };
      final client = f.client();
      final first = client.synthesize(settings, '你好', prepareText: f.prepare);
      final stopped = expectLater(first, throwsA(failure('已停止')));
      await entered.future;
      client.cancel();
      reply.complete(f.json(f.job, 202));
      await stopped;
      await client.synthesize(settings, '你好', prepareText: f.prepare);
      expect(f.posts[1], f.posts[0]);
      expect(f.translations, 1);
    },
  );

  for (final state in ['failed', 'expired']) {
    test(
      '$state job is surfaced, never automatically regenerated or billed',
      () async {
        final f = VoiceFixture()..state = state;
        final client = f.client();
        await expectLater(
          client.synthesize(settings, '你好'),
          throwsA(isA<ApiFailure>()),
        );
        expect(f.posts, hasLength(1));
        expect(f.audioReads, 0);
        f.state = 'ready';
        await client.synthesize(settings, '你好');
        expect(f.posts, hasLength(2));
        expect(f.posts[1]['requestKey'], isNot(f.posts[0]['requestKey']));
      },
    );
  }

  for (final status in [401, 402, 409, 429, 500]) {
    test('HTTP $status never causes a hidden new paid request', () async {
      final f = VoiceFixture();
      f.onPost = (_) async => http.Response(
        jsonEncode({'success': false, 'message': 'fixture rejected'}),
        status,
        headers: {'content-type': 'application/json'},
      );
      final client = f.client();
      await expectLater(
        client.synthesize(settings, '你好'),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', status)),
      );
      expect(f.posts, hasLength(1));
      expect(f.audioReads, 0);
    });
  }

  test('account switch discards late private audio and does not reuse another account cache', () async {
    final f = VoiceFixture();
    final entered = Completer<void>(), response = Completer<http.Response>();
    f.onAudio = (_) async {
      entered.complete();
      return response.future;
    };
    final client = f.client();
    final first = client.synthesize(settings, '你好', prepareText: f.prepare);
    final switched = expectLater(first, throwsA(failure('账号已变化', 409)));
    await entered.future;
    f.site
      ..userId = 'bob'
      ..cookie = 'bob-session';
    response.complete(
      http.Response.bytes(wav(), 200, headers: {'content-type': 'audio/wav'}),
    );
    await switched;
    f.onAudio = null;
    await client.synthesize(
      settings.copyWith(
        options: {...settings.options, 'officialTtsAccount': 'bob'},
      ),
      '你好',
      prepareText: f.prepare,
    );
    expect(f.posts, hasLength(2));
    expect(f.posts[1]['requestKey'], isNot(f.posts[0]['requestKey']));
    expect(f.translations, 2);
  });

  test(
    'saved account and origin must match before any paid transport is opened',
    () async {
      final f = VoiceFixture(), client = f.client();
      f.site.userId = 'bob';
      await expectLater(
        client.synthesize(settings, '你好'),
        throwsA(failure('账号已变化', 409)),
      );
      await expectLater(
        client.synthesize(
          settings.copyWith(siteUrl: 'https://another.example'),
          '你好',
        ),
        throwsA(failure('站点已变化', 409)),
      );
      expect(f.paths, isEmpty);
    },
  );

  test(
    'native site cookie cannot be forwarded to a newly entered origin',
    () async {
      var calls = 0;
      final site = SiteClient(
        client: MockClient((_) async {
          calls++;
          throw StateError('must not send');
        }),
      )..setSessionCookie('https://original.example', 'private-session');
      final client = OfficialTtsClient(
        site: site,
        clientFactory: () => MockClient((_) async {
          calls++;
          throw StateError('must not send');
        }),
      );
      await expectLater(
        client.synthesize(settings, '你好'),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 409)),
      );
      expect(calls, 0);
      site.dispose();
    },
  );

  test('Unicode length is enforced before translation, rather than splitting surrogate pairs', () async {
    final f = VoiceFixture(), client = f.client();
    final tooLong = List.filled(1001, '🌙').join();
    await expectLater(
      client.synthesize(settings, tooLong, prepareText: f.prepare),
      throwsA(failure('1,000')),
    );
    expect(f.translations, 0);
    expect(f.paths, isEmpty);
    final allowed = List.filled(1000, '🌙').join();
    await client.synthesize(settings, allowed);
    expect((f.posts.single['text'] as String).runes.length, 1000);
  });

  test(
    'server job IDs cannot redirect private audio requests to arbitrary paths',
    () async {
      final f = VoiceFixture();
      f.onPost = (_) async =>
          f.json({'id': '../../elsewhere', 'state': 'ready'}, 202);
      await expectLater(
        f.client().synthesize(settings, '你好'),
        throwsA(failure('任务信息异常')),
      );
      expect(f.audioReads, 0);
    },
  );

  test(
    'invalid audio does not trigger new synthesis or discard a paid job',
    () async {
      final f = VoiceFixture();
      f.onAudio = (_) async => f.json({'message': 'not audio'});
      final client = f.client();
      await expectLater(
        client.synthesize(settings, '你好'),
        throwsA(failure('未返回音频')),
      );
      f.onAudio = null;
      await client.synthesize(settings, '你好');
      expect(f.posts, hasLength(1));
    },
  );

  test('public readiness has no cookie or account headers and does not create a job', () async {
    final client = OfficialTtsClient(
      clientFactory: () => MockClient((request) async {
        expect(request.headers['cookie'], isNull);
        expect(request.headers['x-tts-account'], isNull);
        expect(request.method, 'GET');
        expect(request.url.path, '/api/tts/official/status');
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {'online': true},
          }),
          200,
        );
      }),
    );
    expect((await client.status(settings.siteUrl))['online'], true);
  });
}
