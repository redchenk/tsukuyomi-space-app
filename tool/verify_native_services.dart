// Build separately: flutter build macos --release -t tool/verify_native_services.dart
// Uses only loopback fixtures and an isolated temporary key; never user settings.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/storage.dart';
import 'package:tsukuyomi_space_app/core/voice_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Native service verification'))),
    ),
  );
  final results = <String>[];
  final voice = AudioVoice();
  var success = false;
  try {
    final storage = DeviceRoomStorage(await SharedPreferences.getInstance());
    final key = 'releaseSmoke.${DateTime.now().microsecondsSinceEpoch}';
    try {
      await storage.writeSecret(key, 'local-test-only');
      if (await storage.readSecret(key) != 'local-test-only') {
        throw StateError('Secure storage did not round-trip');
      }
      results.add('PASS native secure storage write/read');
    } finally {
      await storage.writeSecret(key, null);
    }
    const settings = RoomSettings(
      llmUrl: 'http://127.0.0.1:18877/v1',
      model: 'release-smoke',
      apiKey: 'release-test-only',
      demo: false,
      ttsUrl: 'http://127.0.0.1:18877/v1',
      ttsKey: 'release-test-only',
    );
    final reply = await LlmClient()
        .reply(settings, [], 'native release fixture')
        .join();
    if (!reply.contains('HTTP')) throw StateError('Missing loopback response');
    results.add('PASS native HTTP UTF-8 SSE');
    await voice.speak(settings, reply);
    var played = false, movedMouth = false, stopped = false;
    for (var i = 0; i < 700; i++) {
      played = played || voice.playing;
      movedMouth = movedMouth || voice.mouth > 0.01;
      if (played && !voice.playing) {
        stopped = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!played || !stopped || !movedMouth) {
      throw StateError(
        'Playback incomplete: playing=$played completion=$stopped mouth=$movedMouth',
      );
    }
    results.add('PASS native WAV playback completion and lip envelope');
    success = true;
  } catch (error) {
    results.add('FAIL $error');
  } finally {
    await voice.stop();
    voice.dispose();
  }
  final report = results.join('\n');
  final output = File(
    '${Directory.systemTemp.path}/tsukuyomi-native-services.txt',
  );
  await output.writeAsString(report);
  stdout.writeln(report);
  stdout.writeln('Report: ${output.path}');
  exit(success ? 0 : 1);
}
