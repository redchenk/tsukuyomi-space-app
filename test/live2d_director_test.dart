import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/live2d/live2d_director_controller.dart';
import 'package:tsukuyomi_space_app/features/live2d/live2d_page.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/live2d/live2d_semantics.dart';
import 'package:tsukuyomi_space_app/live2d/room_animation.dart';

import 'support/fakes.dart';

class DirectorChat extends FakeChat {
  final prompts = <String>[];
  int cancellations = 0;
  @override
  Stream<String> reply(
    RoomSettings settings,
    List<ChatTurn> history,
    String message,
  ) {
    prompts.add(message);
    return super.reply(settings, history, message);
  }

  @override
  void cancel() {
    cancellations++;
    super.cancel();
  }
}

class DelayedDirectorStorage extends MemoryStorage {
  final restored = Completer<String>();
  @override
  Future<String> draft(String scope) =>
      scope.startsWith('live2d-director-history:')
      ? restored.future
      : super.draft(scope);
}

RoomController directorRoom({MemoryStorage? storage, ChatService? chat}) =>
    RoomController(
      storage: storage ?? MemoryStorage(),
      chat: chat ?? FakeChat(),
      site: FakeSite(),
      voice: SilentVoice(),
    );

void main() {
  test(
    'all original semantic actions retain aliases, seconds, sides and stagger',
    () {
      expect(Live2DSemantics.actions, hasLength(24));
      final actions = Live2DSemantics.normalizeActions([
        {'type': 'tilt', 'direction': 'l', 'duration': 1.2, 'strength': 4},
        'breath',
        {'type': 'jump', 'delay': .15, 'duration': -2},
        'unrecognized',
      ]);
      expect(actions, hasLength(3));
      expect(actions[0]['type'], 'head_tilt');
      expect(actions[0]['side'], 'left');
      expect(actions[0]['durationMs'], 1200);
      expect(actions[0]['intensity'], 1);
      expect(actions[1]['type'], 'breathe');
      expect(actions[1]['delayMs'], 864);
      expect(actions[2]['type'], 'bounce');
      expect(actions[2]['delayMs'], 150);
      expect(actions[2]['durationMs'], 260);
      final targets = Live2DSemantics.parameters({
        'ParamEyeBallX': {'value': 99, 'weight': 7, 'durationMs': 3},
        'ParamCheek': -5,
        'unknown': 1,
        'ParamAngleX': double.nan,
      });
      expect(targets, hasLength(2));
      expect(targets[0], containsPair('value', 1));
      expect(targets[0], containsPair('weight', 1));
      expect(targets[0], containsPair('durationMs', 250));
      expect(targets[1], containsPair('value', 0));
    },
  );

  test('native rig applies side, intensity and delayed parameter targets', () {
    RoomAnimation tilt(String side, double intensity, {bool delayed = true}) {
      final animation = RoomAnimation()..ready = true;
      addTearDown(animation.dispose);
      animation.custom({
        'actions': [
          {
            'type': 'head_tilt',
            'side': side,
            'intensity': intensity,
            'durationMs': 1200,
          },
        ],
        'parameters': [
          if (delayed)
            {
              'id': 'ParamCheek',
              'value': 1,
              'delayMs': 700,
              'durationMs': 700,
              'weight': 1,
            },
        ],
        'durationMs': 2000,
      });
      animation.advance(.45);
      return animation;
    }

    final left = tilt('left', 1),
        right = tilt('right', 1),
        soft = tilt('left', .2),
        baseline = tilt('left', 1, delayed: false);
    expect(left.parameters['ParamAngle_HeadZ'], lessThan(0));
    expect(right.parameters['ParamAngle_HeadZ'], greaterThan(0));
    expect(
      soft.parameters['ParamAngle_HeadZ']!.abs(),
      lessThan(left.parameters['ParamAngle_HeadZ']!.abs()),
    );
    // Neutral expression targets may explicitly write the rig's zero baseline.
    // The delayed target must not raise the cheek before its start time.
    expect(
      left.parameters['ParamCheek'] ?? 0,
      baseline.parameters['ParamCheek'] ?? 0,
    );
    left.advance(.55);
    baseline.advance(.55);
    expect(left.parameters['ParamCheek'], greaterThan(.8));
    expect(
      left.parameters['ParamCheek']! - (baseline.parameters['ParamCheek'] ?? 0),
      greaterThan(.8),
    );
    final wink = RoomAnimation()..ready = true;
    addTearDown(wink.dispose);
    wink.custom({
      'actions': [
        {'type': 'wink', 'side': 'left', 'durationMs': 1000},
      ],
    });
    wink.advance(.4);
    expect(wink.parameters['ParamEyeLOpen'], lessThan(.3));
    expect(wink.parameters['ParamEyeROpen'] ?? 1, 1);
  });

  test('priority protection queues, replace interrupts and completion clears overrides', () {
    final animation = RoomAnimation()..ready = true;
    addTearDown(animation.dispose);
    animation.custom({
      'expression': 'closed_smile',
      'durationMs': 1000,
      'interruptPolicy': {'mode': 'protect', 'minHoldMs': 600, 'priority': 8},
    });
    animation.advance(.1);
    expect(animation.parameters['ParamEyeLOpen'], 0);
    animation.custom({
      'expression': 'neutral',
      'priority': 2,
      'durationMs': 900,
    });
    expect(animation.current?['expression'], 'closed_smile');
    expect(animation.queue, hasLength(1));
    animation.custom({
      'actions': [
        {'type': 'head_tilt', 'side': 'right'},
      ],
      'durationMs': 900,
      'interruptPolicy': {'mode': 'replace', 'blendInMs': 0},
    });
    expect(animation.current, isNull);
    animation.advance(.4);
    expect(animation.parameters['ParamAngle_HeadZ'], greaterThan(0));
    animation.advance(1);
    expect(animation.parameters, isEmpty);
    expect(animation.expression, 'neutral');
    animation.clear();
    expect(animation.queue, isEmpty);
    expect(animation.scale, 1);
  });

  test('decoder handles chunked beats/voice/control and suppresses reasoning', () {
    final decoder = Live2DStreamDecoder();
    const first =
        '<think>private plan</think>\nBEAT: {"expression":"surprised","actions":[{"type":"head_tilt","side":"left"}]}\nVOICE: 今天的直播终于开始啦。';
    final lines = decoder.push(first);
    expect(lines, hasLength(1));
    expect(lines.single.text, '今天的直播终于开始啦。');
    expect(lines.single.intent['expression'], 'surprised');
    const finalOutput =
        '$first\nVOICE: 你们想先聊哪一个话题呢？\nCONTROL: {"reply":"今天的直播终于开始啦。你们想先聊哪一个话题呢？","expression":"smile","bodyPose":"bounce"}';
    final rest = decoder.push(finalOutput, flush: true);
    expect(rest.map((l) => l.text).join(), '你们想先聊哪一个话题呢？');
    expect(
      Live2DStreamDecoder.parse(finalOutput)['reply'],
      isNot(contains('CONTROL')),
    );
    expect(Live2DStreamDecoder.parse('<think>unfinished')['reply'], '');
    expect(
      Live2DStreamDecoder.parse(
        '你好。\nAction: head_tilt\nExpression: smile',
      )['reply'],
      '你好。',
    );
    final json = Live2DStreamDecoder();
    expect(json.push('{"reply":"\\u4f60\\u597d'), isEmpty);
    expect(
      json
          .push(
            '{"reply":"\\u4f60\\u597d，欢迎来到月读空间！","expression":"smile"}',
            flush: true,
          )
          .map((l) => l.text)
          .join(),
      '你好，欢迎来到月读空间！',
    );
  });

  test('first director request awaits stored history and clear removes persisted context', () async {
    final storage = DelayedDirectorStorage(), chat = DirectorChat();
    chat.answer = jsonEncode({
      'reply': '欢迎回到直播间。',
      'expression': 'smile',
      'bodyPose': 'bounce',
    });
    final room = directorRoom(storage: storage),
        director = Live2DDirectorController(room, chat: chat);
    addTearDown(room.dispose);
    addTearDown(director.dispose);
    final request = director.perform('继续直播', streaming: false);
    await Future<void>.delayed(Duration.zero);
    expect(chat.prompts, isEmpty);
    storage.restored.complete(
      jsonEncode([
        ChatTurn(
          id: 'old',
          user: '之前的问题',
          assistant: '之前的回复',
          createdAt: DateTime(2026),
        ).toJson(),
      ]),
    );
    await request;
    expect(chat.lastContext.single.user, '之前的问题');
    expect(director.caption, '欢迎回到直播间。');
    expect(director.animation.queue, isNotEmpty);
    expect(director.history, hasLength(2));
    director.clearHistory();
    await Future<void>.delayed(Duration.zero);
    expect(director.history, isEmpty);
    expect(director.showLog, isEmpty);
    expect(director.animation.queue, isEmpty);
    expect(jsonDecode(storage.drafts[director.historyKey]!), isEmpty);
  });

  test('director persistent history uses real account keys even when Room scope is demo', () async {
    final storage = MemoryStorage(), chat = DirectorChat();
    final room = directorRoom(storage: storage)
      ..account = const Account('alice', 'Alice');
    final aliceKey = 'live2d-director-history:https://yachiyo.hk:alice';
    final bobKey = 'live2d-director-history:https://yachiyo.hk:bob';
    String savedHistory(String owner) => jsonEncode([
      ChatTurn(
        id: '$owner-history',
        user: '$owner 的私有导演问题',
        assistant: '$owner 的私有回答',
        createdAt: DateTime(2026),
      ).toJson(),
    ]);
    storage.drafts[aliceKey] = savedHistory('alice');
    storage.drafts[bobKey] = savedHistory('bob');
    final director = Live2DDirectorController(room, chat: chat);
    addTearDown(room.dispose);
    addTearDown(director.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(room.scope, 'demo');
    expect(director.historyKey, aliceKey);
    expect(director.history.single.user, 'alice 的私有导演问题');
    await director.perform('alice 的新问题', streaming: false);
    await Future<void>.delayed(Duration.zero);
    room.account = const Account('bob', 'Bob');
    room.notifyListeners();
    await Future<void>.delayed(Duration.zero);
    expect(room.scope, 'demo');
    expect(director.historyKey, bobKey);
    expect(director.history.single.user, 'bob 的私有导演问题');
    await director.perform('bob 的新问题', streaming: false);
    await Future<void>.delayed(Duration.zero);
    expect(chat.lastContext.single.user, 'bob 的私有导演问题');
    expect(storage.drafts[bobKey], contains('bob 的新问题'));
    expect(storage.drafts[bobKey], isNot(contains('alice')));
    expect(storage.drafts[aliceKey], contains('alice 的新问题'));
    room.account = const Account('alice', 'Alice');
    room.notifyListeners();
    await Future<void>.delayed(Duration.zero);
    expect(director.history.map((t) => t.user), [
      'alice 的私有导演问题',
      'alice 的新问题',
    ]);
  });

  test('director uses a separate transport and ignores responses after account changes', () async {
    final roomChat = DirectorChat(), chat = DirectorChat()..controlled = true;
    final room = directorRoom(chat: roomChat),
        director = Live2DDirectorController(room, chat: chat);
    addTearDown(room.dispose);
    addTearDown(director.dispose);
    final pending = director.perform('旧账号提示');
    await Future<void>.delayed(Duration.zero);
    chat.stream!.add('VOICE: 旧账号尚未结束的回复');
    room.account = const Account('other', 'Other');
    room.notifyListeners();
    await pending;
    expect(director.history, isEmpty);
    expect(director.caption, '');
    expect(director.animation.queue, isEmpty);
    expect(roomChat.cancellations, 0);
    expect(chat.cancellations, greaterThan(0));
  });

  testWidgets(
    'live director consumes three audience messages and stop cancels scheduled ticks',
    (tester) async {
      final chat = DirectorChat()
        ..answer =
            '{"reply":"观众朋友们晚上好。","expression":"smile","bodyPose":"nod"}';
      final room = directorRoom(),
          director = Live2DDirectorController(room, chat: chat)
            ..autoVoice = false;
      addTearDown(room.dispose);
      addTearDown(director.dispose);
      for (var i = 0; i < 4; i++) {
        director.sendAudience('第${i + 1}条观众留言');
      }
      director.start();
      await tester.pump();
      expect(chat.prompts.single, contains('LIVE_DIRECTOR_TICK'));
      expect(chat.prompts.single, contains('1. 第1条观众留言'));
      expect(chat.prompts.single, contains('3. 第3条观众留言'));
      expect(chat.prompts.single, isNot(contains('第4条观众留言')));
      expect(director.audienceQueue, ['第4条观众留言']);
      expect(director.turn, 1);
      director.stop();
      await tester.pump(const Duration(seconds: 12));
      expect(chat.prompts, hasLength(1));
      expect(director.running, isFalse);
    },
  );

  testWidgets(
    'native workbench fits 320/1280 and JSON button writes real rig targets',
    (tester) async {
      final room = directorRoom(),
          director = Live2DDirectorController(room, chat: DirectorChat());
      director.animation.ready = true;
      addTearDown(room.dispose);
      addTearDown(director.dispose);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final width in [320.0, 1280.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpWidget(
          MaterialApp(
            home: Live2DPage(
              controller: room,
              onGo: (_) {},
              loadNative: false,
              director: director,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('live2d-json')), findsOneWidget);
      }
      await tester.ensureVisible(find.byKey(const Key('live2d-json')));
      await tester.enterText(
        find.byKey(const Key('live2d-json')),
        '{"parameters":{"ParamCheek":{"value":1,"weight":1,"durationMs":1000}},"durationMs":1200}',
      );
      await tester.ensureVisible(find.text('应用 JSON'));
      await tester.tap(find.text('应用 JSON'));
      await tester.pump();
      director.animation.advance(.4);
      expect(director.animation.parameters['ParamCheek'], 1);
      await tester.enterText(
        find.byKey(const Key('live2d-json')),
        '{"parameters":{"unknown":1}}',
      );
      await tester.tap(find.text('应用 JSON'));
      await tester.pump();
      expect(find.textContaining('没有可执行的 Live2D'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
