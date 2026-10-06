import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/game/game_session.dart';
import 'package:tsukuyomi_space_app/features/game/kaguya_assets.dart';
import 'package:tsukuyomi_space_app/features/game/kaguya_audio.dart';
import 'package:tsukuyomi_space_app/features/game/kaguya_runtime.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';

Map<String, dynamic> shippedProject() =>
    jsonDecode(File('assets/game/project.json').readAsStringSync())
        as Map<String, dynamic>;
KaguyaRuntime shippedRuntime() =>
    KaguyaRuntime(shippedProject(), random: Random(7))
      ..setMasks(File('assets/game/masks.bin').readAsBytesSync());
void frames(KaguyaRuntime vm, int count) {
  for (var i = 0; i < count; i++) {
    vm.advance(1 / 30);
  }
}

class GameApi extends FakeSite implements SiteDataService {
  final calls = <(String, String, Map<String, dynamic>?)>[];
  Completer<Map<String, dynamic>>? pending;
  bool failScores = false;
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    calls.add((method, path, body));
    if (method == 'POST') {
      if (pending != null) return pending!.future;
      if (failScores) throw const ApiFailure('offline');
      return {
        'data': {
          'current': {'score': body!['score'], 'rank': 2},
        },
      };
    }
    final second = path.contains('page=2');
    return {
      'data': {
        'entries': [
          {'userId': 'one', 'username': 'one', 'rank': 1, 'score': 1000},
          if (second)
            {'userId': 'two', 'username': 'two', 'rank': 2, 'score': 500},
        ],
        'totalPages': 2,
        'current': {'score': 30, 'rank': 3},
      },
    };
  }
}

class PendingGameVoice implements KaguyaSoundVoice {
  Completer<void>? playGate;
  final events = <String>[];
  @override
  bool playing = false;
  @override
  bool paused = false;
  @override
  Future<void> playAsset(String path, double volume) async {
    events.add('play:$path');
    if (playGate != null) await playGate!.future;
    playing = true;
    paused = false;
  }

  @override
  Future<void> stop() async {
    events.add('stop');
    playing = paused = false;
  }

  @override
  Future<void> pause() async {
    paused = true;
    playing = false;
  }

  @override
  Future<void> resume() async {
    paused = false;
    playing = true;
  }

  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> dispose() async {
    events.add('dispose');
    playing = paused = false;
  }
}

void main() {
  test('200 postgame cycles preserve score/mood with acknowledged resets and bounded clones/speed', () {
    final vm = shippedRuntime();
    addTearDown(vm.dispose);
    vm.greenFlag();
    frames(vm, 90);
    vm.startGame();
    frames(vm, 90);
    expect(KaguyaRuntime.number(vm.variableByName('轮回启动完成')), 1);
    for (var i = 1; i <= 200; i++) {
      vm.setVariableByName('心情值', 1000);
      vm.setVariableByName('分数', i * 10000);
      frames(vm, 90);
      expect(vm.score, greaterThanOrEqualTo(i * 10000), reason: 'cycle $i');
      expect(vm.mood, greaterThan(0));
      expect(KaguyaRuntime.number(vm.variableByName('轮回启动完成')), 1);
      expect(KaguyaRuntime.number(vm.variableByName('关卡轮换中')), 0);
      expect(
        KaguyaRuntime.number(vm.variableByName('背景速度（我跑步速度')),
        lessThanOrEqualTo(14),
      );
      expect(vm.cloneCount, lessThanOrEqualTo(300));
      expect(vm.sprites.firstWhere((s) => s.name == '开始游戏').visible, false);
    }
    expect(vm.unknownOpcodes, isEmpty);
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'all opcode types in the independently shipped full project are supported',
    () {
      final vm = shippedRuntime();
      addTearDown(vm.dispose);
      expect(vm.sprites, hasLength(70));
      expect(vm.unsupportedProjectOpcodes, isEmpty);
      final originalTypes = {
        for (final s in vm.sprites)
          for (final b in s.blocks.values) b['opcode'],
      };
      expect(originalTypes.length, greaterThan(100));
    },
  );
  test('shipped project initializes, starts real running scripts, jumps and reaches game over', () {
    final vm = shippedRuntime();
    addTearDown(vm.dispose);
    vm.greenFlag();
    frames(vm, 3);
    final start = vm.sprites.firstWhere((s) => s.name == '开始游戏');
    expect(start.visible, true);
    vm.startGame();
    frames(vm, 150);
    expect(start.visible, false);
    expect(KaguyaRuntime.number(vm.variableByName('可以操作吗')), 1);
    final kaguya = vm.sprites.firstWhere((s) => s.name == '辉夜');
    final initialY = kaguya.y;
    vm.key('space', true);
    frames(vm, 5);
    vm.key('space', false);
    expect(kaguya.y, greaterThan(initialY));
    var peakClones = vm.cloneCount;
    for (var frame = 0; frame < 120; frame++) {
      vm.advance(1 / 30);
      peakClones = max(peakClones, vm.cloneCount);
    }
    expect(
      peakClones,
      greaterThan(0),
      reason: jsonEncode({
        'time': vm.time,
        'easterEgg': vm.variableByName('彩蛋局'),
        'created': vm.executedOpcodes.contains('control_create_clone_of'),
        'threads': vm.executionState,
      }),
    );
    // "成功跳过一个障碍" only selects a happy character animation. Points
    // are added by an actual obstacle clone after its x crosses -10.
    // 黑1 is the source's ordinary-obstacle stage, following the first block.
    vm.broadcast('黑1');
    var pressedFrames = 0, jumps = 0;
    final scoringFrames = <Map<String, dynamic>>[];
    // Give the source's random 1–3.5 s spawn delay and the full crossing time
    // room to complete. Jump in response to an approaching real obstacle.
    for (var frame = 0; frame < 360 && vm.score == 0; frame++) {
      if (pressedFrames > 0) {
        pressedFrames--;
        if (pressedFrames == 0) vm.key('space', false);
      } else if (KaguyaRuntime.number(vm.variableByName('跳起？')) == 0 &&
          vm.sprites.any(
            (s) =>
                s.name == '障碍' &&
                s.isClone &&
                s.visible &&
                s.x <= 140 &&
                s.x > 60,
          )) {
        vm.key('space', true);
        pressedFrames = 5;
        jumps++;
      }
      vm.advance(1 / 30);
      if (frame % 15 == 0) {
        scoringFrames.add({
          'time': vm.time,
          'score': vm.score,
          'mood': vm.mood,
          'jumping': vm.variableByName('跳起？'),
          'speed': vm.variableByName('背景速度（我跑步速度'),
          'sprites': [
            for (final s in vm.sprites.where(
              (s) => ['辉夜', '障碍', '受伤碰撞', '地'].contains(s.name),
            ))
              {
                'name': s.name,
                'clone': s.cloneId,
                'x': s.x,
                'y': s.y,
                'visible': s.visible,
                'bounds': '${s.bounds}',
              },
          ],
          'threads': vm.executionState
              .where((t) => t['sprite'] == '障碍')
              .toList(),
        });
      }
    }
    vm.key('space', false);
    expect(
      jumps,
      greaterThan(0),
      reason: 'The player must react to a real obstacle.',
    );
    expect(
      vm.score,
      greaterThanOrEqualTo(10),
      reason: jsonEncode(scoringFrames),
    );
    vm.setVariableByName('心情值', 0);
    frames(vm, 180);
    expect(vm.sprites.firstWhere((s) => s.name == '游戏结束').visible, true);
    expect(vm.unknownOpcodes, isEmpty);
    expect(
      vm.executedOpcodes,
      containsAll([
        'control_create_clone_of',
        'sensing_keypressed',
        'sensing_touchingobject',
        'procedures_call',
      ]),
    );
    vm.restart();
    frames(vm, 3);
    expect(start.visible, true);
    expect(vm.unknownOpcodes, isEmpty);
  });

  test(
    'shipped sine tweens retain their independent in and out directions',
    () {
      for (final direction in ['in', 'out']) {
        final project = shippedProject();
        final targets = project['targets'] as List;
        final aim = targets.firstWhere(
          (s) => s['name'] == '瞄准',
        ) as Map<String, dynamic>;
        final blocks = aim['blocks'] as Map<String, dynamic>;
        final original =
            blocks.values
                    .where((b) => b['opcode'] == 'jeremygamerTweening_tweenXY')
                    .firstWhere((b) {
                      final menu = blocks[b['inputs']['DIRECTION'][1]];
                      return menu['fields']['direction'][0] == direction;
                    })
                as Map<String, dynamic>;
        final tween = Map<String, dynamic>.from(original);
        tween['next'] = null;
        tween['inputs'] = {
          ...original['inputs'] as Map,
          'SEC': [
            1,
            [4, '1'],
          ],
          'X': [
            1,
            [4, '100'],
          ],
          'Y': [
            1,
            [4, '50'],
          ],
        };
        final menus = {
          for (final name in ['MODE', 'DIRECTION'])
            '${original['inputs'][name][1]}':
                blocks[original['inputs'][name][1]],
        };
        for (final target in targets) {
          target['blocks'] = <String, dynamic>{};
        }
        aim['x'] = aim['y'] = 0;
        aim['blocks'] = {
          ...menus,
          'start': {'opcode': 'event_whenflagclicked', 'next': 'tween'},
          'tween': tween,
        };
        final vm = KaguyaRuntime(project);
        addTearDown(vm.dispose);
        vm.greenFlag();
        frames(vm, 1);
        frames(vm, 15);
        final sprite = vm.sprites.firstWhere((s) => s.name == '瞄准');
        final fraction = direction == 'in' ? 1 - cos(pi / 4) : sin(pi / 4);
        expect(sprite.x, closeTo(100 * fraction, .0001));
        expect(sprite.y, closeTo(50 * fraction, .0001));
        frames(vm, 16);
        expect(sprite.x, closeTo(100, 1e-9));
        expect(sprite.y, closeTo(50, 1e-9));
        expect(vm.unknownOpcodes, isEmpty);
      }
    },
  );

  test('original game-over text types at 15 Hz, blocks the script and shakes for .5 s', () {
    final project = shippedProject();
    for (final target in project['targets'] as List) {
      if (target['name'] != '游戏结束') target['blocks'] = <String, dynamic>{};
    }
    final vm = KaguyaRuntime(project);
    addTearDown(vm.dispose);
    vm.greenFlag();
    vm.broadcast('死了拉！');
    frames(vm, 1);
    final text = vm.sprites.firstWhere((s) => s.name == '游戏结束');
    expect(text.font, contains('HYPixel11pxU-2'));
    expect(text.displayedText(vm.time), 'g');
    frames(vm, 6);
    expect(text.displayedText(vm.time).length, inInclusiveRange(3, 4));
    expect(text.textAnimation, 'type');
    expect(text.isTextShaking(vm.time), false);
    frames(vm, 12);
    expect(text.displayedText(vm.time), 'game over');
    expect(text.textAnimation, 'type');
    frames(vm, 6);
    expect(text.textAnimation, 'shake');
    expect(text.isTextShaking(vm.time), true);
    expect(text.shake, 20);
    frames(vm, 16);
    expect(text.isTextShaking(vm.time), false);
    expect(vm.unknownOpcodes, isEmpty);
  });

  test(
    'game restart cannot resurrect a sound waiting for the native platform',
    () async {
      final vm = shippedRuntime();
      addTearDown(vm.dispose);
      final voice = PendingGameVoice()..playGate = Completer<void>();
      final audio = KaguyaAudio(vm, voiceFactory: () => voice);
      final sprite = vm.sprites.firstWhere((s) => s.sounds.isNotEmpty);
      final sound = sprite.sounds.first;
      vm.onSound!(sprite, sound, false);
      await Future<void>.delayed(Duration.zero);
      expect(voice.events.where((e) => e.startsWith('play:')), hasLength(1));
      vm.restart();
      voice.playGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(voice.playing, false);
      voice.playGate = null;
      vm.onSound!(sprite, sound, false);
      await Future<void>.delayed(Duration.zero);
      expect(voice.playing, true);
      audio.pause(true);
      await Future<void>.delayed(Duration.zero);
      expect(voice.paused, true);
      audio.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(voice.playing, false);
      expect(voice.events.last, 'dispose');
    },
  );

  test('flight, rhythm, combat and 10000-point repeat execute shipped broadcast scripts', () {
    final vm = shippedRuntime();
    addTearDown(vm.dispose);
    vm.greenFlag();
    frames(vm, 3);
    vm.startGame();
    frames(vm, 150);
    for (final event in [
      '遇到第一个飞船',
      '月人召唤仪式',
      '音游结束',
      '切换战斗辉夜模型',
      '切换第四阶段背景1',
    ]) {
      vm.broadcast(event);
      vm.setVariableByName('心情值', 9000);
      frames(vm, 90);
    }
    vm.setVariableByName('分数', 10000);
    vm.setVariableByName('心情值', 9000);
    frames(vm, 60);
    expect(vm.score, greaterThanOrEqualTo(10000));
    expect(KaguyaRuntime.number(vm.variableByName('关卡轮换中')), 0);
    expect(
      vm.unknownOpcodes,
      isEmpty,
      reason: 'No extension opcode may silently become a no-op.',
    );
    // Box2D is the combat lantern's reaction to a lower weapon hit.
    vm.broadcast('月人老母来');
    vm.setVariableByName('心情值', 9000);
    // The source's first rhythm cue is 19.074 seconds (minus its .86s lead).
    frames(vm, 570);
    final lantern = vm.sprites.firstWhere((s) => s.isClone && s.name == '月人');
    final hitbox = vm.sprites.firstWhere((s) => s.name == '攻击判定下');
    // Isolate a hit from random placement, retaining the original sensing,
    // clone costume change and physics commands.
    hitbox.visible = true;
    lantern.x = hitbox.x;
    lantern.y = hitbox.y;
    vm.setVariableByName('是否造成伤害了刀子', 1);
    vm.setVariableByName('攻击方向', '下');
    vm.key('down arrow', true);
    for (var frame = 0; frame < 6; frame++) {
      hitbox.visible = true;
      lantern.x = hitbox.x;
      lantern.y = hitbox.y;
      vm.setVariableByName('是否造成伤害了刀子', 1);
      vm.setVariableByName('攻击方向', '下');
      vm.advance(1 / 30);
    }
    vm.key('down arrow', false);
    frames(vm, 60);
    expect(vm.unknownOpcodes, isEmpty);
    expect(
      vm.executedOpcodes,
      containsAll(['griffpatch_setPhysics', 'griffpatch_doTick']),
    );
  });

  test(
    'pause freezes simulation time, keys normalize and restart removes clones',
    () {
      final vm = shippedRuntime();
      addTearDown(vm.dispose);
      vm.greenFlag();
      vm.key('ArrowUp', true);
      expect(vm.keys, contains('up arrow'));
      vm.togglePause();
      frames(vm, 30);
      expect(vm.time, 0);
      vm.togglePause();
      frames(vm, 30);
      expect(vm.time, closeTo(1, .00001));
      vm.restart();
      expect(vm.cloneCount, 0);
      expect(vm.keys, isEmpty);
      expect(KaguyaRuntime.truth('0'), false);
      expect(KaguyaRuntime.truth('false'), false);
      expect(KaguyaRuntime.compare('15', 15), 0);
    },
  );

  test(
    'pixel alpha collision respects holes, hidden sensors and clone masks',
    () {
      final project = shippedProject();
      final raw = Map<String, dynamic>.from((project['targets'] as List)[1]);
      raw['costumes'] = [
        {
          'name': 'ring',
          'bitmapResolution': 1,
          'rotationCenterX': 1,
          'rotationCenterY': 1,
          'imageWidth': 3,
          'imageHeight': 3,
          'alphaBounds': [0, 0, 3, 3],
          'maskOffset': 0,
          'maskLength': 2,
        },
      ];
      raw['currentCostume'] = 0;
      raw['x'] = raw['y'] = 0;
      raw['size'] = 100;
      raw['direction'] = 90;
      final a = KaguyaSprite(raw);
      // 3×3 opaque ring with a transparent centre.
      a.masks = Uint8List.fromList([0xef, 1]);
      expect(a.containsPoint(const Offset(.5, -.5)), false);
      expect(a.containsPoint(const Offset(-.5, -.5)), true);
      final b = a.clone(1)..x = 3;
      expect(a.touching(b), false);
      b.x = 0;
      a.visible = false;
      expect(a.touching(b), true);
      b.visible = false;
      expect(a.touching(b), false);
    },
  );

  test(
    'Box2D gravity uses original 50-unit scale and torque changes orientation',
    () {
      final vm = shippedRuntime();
      addTearDown(vm.dispose);
      final sprite = vm.sprites.firstWhere((s) => s.name == '辉夜')
        ..x = 0
        ..y = 100
        ..size = 20
        ..direction = 90
        ..rotationStyle = 'all around';
      vm.physics.setStage(false);
      vm.physics.enable(sprite);
      vm.physics.setVelocity(sprite, 0, -6);
      vm.physics.tick();
      expect(sprite.y, closeTo(100 - 6 - 50 * 10 / 900, .01));
      vm.physics.torque(sprite, 15);
      vm.physics.tick();
      expect(sprite.direction, isNot(90));
    },
  );

  test('game score request uses actual contract, cooldown, paged leaderboard and scoped best', () async {
    final api = GameApi(), storage = MemoryStorage();
    final controller = RoomController(
      storage: storage,
      site: api,
      chat: FakeChat(),
      voice: SilentVoice(),
    )..account = const Account('alice', 'alice');
    addTearDown(controller.dispose);
    var clock = DateTime(2026);
    final session = GameSession(controller, now: () => clock);
    addTearDown(session.dispose);
    await session.initialize();
    expect(session.touchControls, false);
    expect(session.entries.map((e) => e['userId']), ['one']);
    expect(session.totalPages, 2);
    await session.refreshLeaderboard(targetPage: 2);
    expect(session.entries.map((e) => e['userId']), ['one', 'two']);
    session.updateScore(100);
    await Future<void>.delayed(Duration.zero);
    expect(api.calls.where((c) => c.$1 == 'POST').single.$3, {'score': 100});
    session.updateScore(350);
    await Future<void>.delayed(Duration.zero);
    expect(api.calls.where((c) => c.$1 == 'POST'), hasLength(1));
    clock = clock.add(const Duration(seconds: 15));
    session.updateScore(351);
    await Future<void>.delayed(Duration.zero);
    expect(api.calls.where((c) => c.$1 == 'POST').last.$3, {'score': 351});
    await Future<void>.delayed(Duration.zero);
    expect(storage.drafts.values, contains('351'));
    expect(storage.secrets, isEmpty);
  });

  test('guest score is local and late score response cannot overwrite another account', () async {
    final api = GameApi(),
        controller = RoomController(
          storage: MemoryStorage(),
          site: api,
          chat: FakeChat(),
          voice: SilentVoice(),
        );
    addTearDown(controller.dispose);
    final session = GameSession(controller);
    addTearDown(session.dispose);
    session.updateScore(200);
    expect(api.calls.where((c) => c.$1 == 'POST'), isEmpty);
    await controller.login('alice', 'pw');
    await Future<void>.delayed(Duration.zero);
    api.pending = Completer();
    session.updateScore(300);
    await controller.login('bob', 'pw');
    api.pending!.complete({
      'data': {
        'current': {'score': 99999, 'rank': 1},
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(session.best, lessThan(99999));
    expect(session.saving, false);
  });

  testWidgets(
    'real bundled costumes load and paint a native 480×360 opening screen',
    (tester) async {
      late KaguyaAssets assets;
      await tester.runAsync(() async {
        assets = await KaguyaAssets.load();
      });
      final vm = assets.runtime(random: Random(1));
      vm.greenFlag();
      frames(vm, 3);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomPaint(
              size: const Size(480, 360),
              painter: KaguyaPainter(vm, assets),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        Future<void> capture(String name) async {
          final recorder = ui.PictureRecorder();
          KaguyaPainter(
            vm,
            assets,
          ).paint(Canvas(recorder), const Size(480, 360));
          final picture = recorder.endRecording();
          final image = await picture.toImage(480, 360);
          final rgba = await image.toByteData();
          expect(rgba, isNotNull);
          expect(rgba!.buffer.asUint8List().toSet().length, greaterThan(30));
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('artifacts').create(recursive: true);
          await File('artifacts/game-native-$name.png')
              .writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
        }

        await capture('opening');
        vm.startGame();
        frames(vm, 150);
        await capture('running');
        vm.setVariableByName('心情值', 0);
        frames(vm, 180);
        await capture('gameover');
      });
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
      assets.dispose();
    },
  );
}
