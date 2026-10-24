import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/core/voice_service.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'compatible_services_test.dart' show wav;
import 'official_payments_test.dart' show dashboard;
import 'support/fakes.dart';

class RecordingPlayer extends Fake implements AudioPlayer {
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final sources = <Source>[];
  @override
  Stream<PlayerState> get onPlayerStateChanged => states.stream;
  @override
  Stream<Duration> get onPositionChanged => const Stream.empty();
  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {
    expect(source, isA<DeviceFileSource>());
    expect(await File((source as DeviceFileSource).path).readAsBytes(), wav());
    sources.add(source);
    states.add(PlayerState.playing);
  }

  @override
  Future<void> stop() async => states.add(PlayerState.stopped);
  @override
  Future<void> dispose() async => states.close();
}

class AutomaticVoiceFixture {
  final player = RecordingPlayer();
  final translations = <String>[];
  final syntheses = <String>[];
  String user = 'alice';
  bool expired = false;
  late final voice = AudioVoice(
    player: player,
    clientFactory: () => MockClient(handle),
  );
  late final site = SiteClient(client: MockClient(handle));
  late final controller = RoomController(
    storage: MemoryStorage()
      ..value = const RoomSettings(
        siteUrl: 'https://site.test',
        llmUrl: 'https://site.test/official-api/v1/chat/completions',
        model: 'deepseek-chat',
        speak: true,
        options: {
          'ttsProvider': 'official',
          'officialTtsAccount': 'alice',
          'officialTtsOrigin': 'https://site.test',
        },
      ),
    site: site,
    chat: FakeChat(),
    voice: voice,
  );
  http.Response json(Object? data) => http.Response(
    jsonEncode({'success': true, 'data': data}),
    200,
    headers: {'content-type': 'application/json'},
  );
  Future<http.Response> handle(http.Request req) async {
    final path = req.url.path;
    if (path == '/api/auth/login') {
      user = '${jsonDecode(req.body)['username']}'.split('@').first;
      return http.Response(
        jsonEncode({
          'success': true,
          'data': {
            'user': {'id': user, 'username': user},
          },
        }),
        200,
        headers: {
          'content-type': 'application/json',
          'set-cookie': 'tsukuyomi_session=$user; HttpOnly; Path=/',
        },
      );
    }
    if (path == '/api/auth/logout') return json({});
    if (path == '/api/room/chat') return json([]);
    if (path == '/api/room/memory/events') {
      return http.Response(
        '',
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    if (path == '/api/auth/me') {
      if (expired) return http.Response('{"success":false}', 401);
      expect(req.headers['cookie'], 'tsukuyomi_session=$user');
      return json({'id': user, 'username': user});
    }
    if (path == '/official-api/api/dashboard') {
      expect(req.headers['cookie'], 'tsukuyomi_session=$user');
      return http.Response(
        jsonEncode(dashboard(user)),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path == '/official-api/v1/chat/completions') {
      expect(req.headers['cookie'], 'tsukuyomi_session=$user');
      expect(req.headers['x-official-expected-account'], 'official-$user');
      expect(req.headers['authorization'], isNull);
      final messages = jsonDecode(req.body)['messages'] as List;
      expect(messages.last['content'], '这是完整回复。');
      translations.add(user);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'こんにちは。'},
              'finish_reason': 'stop',
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path == '/api/tts/official/status') {
      return json({
        'online': true,
        'language': 'ja',
        'priceAtoms': '50000000',
        'maxCharacters': 1000,
        'retentionHours': 24,
      });
    }
    if (path.startsWith('/api/tts/official/jobs')) {
      expect(req.headers['cookie'], 'tsukuyomi_session=$user');
      expect(req.headers['x-tts-account'], user);
      if (req.method == 'POST') {
        expect(jsonDecode(req.body)['text'], 'こんにちは。');
        syntheses.add(user);
      }
      if (path.endsWith('/audio')) {
        return http.Response.bytes(
          wav(),
          200,
          headers: {'content-type': 'audio/wav'},
        );
      }
      return json({
        'id':
            'req_voice_${List.filled(64, user == 'alice' ? 'a' : 'b').join()}',
        'state': 'ready',
        'chargedAtoms': '50000000',
      });
    }
    throw StateError('Unexpected request: ${req.method} $path');
  }

  Future<void> login([String name = 'alice@example.com']) async {
    await controller.login(name, 'fixture-password');
    controller.pause();
  }

  Future<void> waitForSpeech() async {
    for (
      var i = 0;
      i < 100 && !voice.playing && controller.error.isEmpty;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.error, isEmpty);
    expect(voice.playing, isTrue);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'password login -> Chinese chat -> translation -> official audio -> replay',
    () async {
      final f = AutomaticVoiceFixture();
      addTearDown(f.controller.dispose);
      await f.controller.initialize();
      await f.login();
      expect(f.controller.sessionVerified, isTrue);
      await f.controller.send('你好');
      await f.waitForSpeech();
      expect(f.translations, ['alice']);
      expect(f.syntheses, ['alice']);
      expect(f.player.sources, hasLength(1));
      await f.controller.replay('这是完整回复。');
      expect(f.player.sources, hasLength(2));
      expect(f.translations, ['alice']);
      expect(f.syntheses, ['alice']);
      await f.voice.stop();
    },
  );
  test(
    'account switch rejects old voice binding then uses the new identity',
    () async {
      final f = AutomaticVoiceFixture();
      addTearDown(f.controller.dispose);
      await f.controller.initialize();
      await f.login();
      await f.controller.send('你好');
      await f.waitForSpeech();
      await f.login('bob@example.com');
      await f.controller.replay('这是完整回复。');
      expect(f.syntheses, ['alice']);
      expect(f.voice.playing, isFalse);
      await f.controller.configure(
        f.controller.settings.copyWith(
          options: {
            ...f.controller.settings.options,
            'officialTtsAccount': 'bob',
          },
        ),
      );
      f.controller.pause();
      await f.controller.send('你好');
      await f.waitForSpeech();
      expect(f.translations, ['alice', 'bob']);
      expect(f.syntheses, ['alice', 'bob']);
      await f.voice.stop();
    },
  );

  test(
    'expired password session cannot translate or create a voice job',
    () async {
      final f = AutomaticVoiceFixture();
      addTearDown(f.controller.dispose);
      await f.controller.initialize();
      await f.login();
      f.expired = true;
      await f.controller.send('你好');
      for (var i = 0; i < 100 && f.controller.error.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(f.controller.error, isNotEmpty);
      expect(f.translations, isEmpty);
      expect(f.syntheses, isEmpty);
      expect(f.player.sources, isEmpty);
    },
  );
}
