import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_studio_motion/tsukuyomi_studio_motion.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/room/room_chat_view.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/live2d/character_stage.dart';
import 'package:tsukuyomi_space_app/main.dart';

import 'support/fakes.dart';

class _CountingModel extends Live2DModel {
  int ticks = 0;
  @override
  List<ui.Image> get textures => [];
  @override
  List<LiveMesh> get meshes => [];
  @override
  Rect get bounds => const Rect.fromLTWH(0, 0, 1, 1);
  @override
  List<String> get expressions => [];
  @override
  double get updateMilliseconds => 0;
  @override
  void tick(
    double seconds,
    double delta, {
    double mouth = 0,
    double lookX = 0,
    double lookY = 0,
    String expression = 'neutral',
  }) {
    ticks++;
    notifyListeners();
  }
}

void main() {
  final motionSource = File('assets/live2d/studio-motion.js')
      .readAsStringSync();
  Future<StudioRuntime> motionLoader() async =>
      createStudioRuntime(motionSource);
  for (final mobile in [true, false]) {
    testWidgets(
      'held performance gestures retain the stream on ${mobile ? 'mobile' : 'desktop'}',
      (tester) async {
        tester.view.physicalSize = mobile
            ? const Size(390, 844)
            : const Size(1280, 820);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final chat = FakeChat()..controlled = true;
        final room = RoomController(
          storage: MemoryStorage(),
          chat: chat,
          site: FakeSite(),
          voice: SilentVoice(),
        );
        addTearDown(room.dispose);
        await room.initialize();
        room.turns = List.generate(
          100,
          (i) => ChatTurn(
            id: 'held-$i',
            user: '历史问题$i',
            assistant: '这是用于拖动的历史回复$i。还有一段完整解释。',
            createdAt: DateTime(2020),
          ),
        );
        final model = _CountingModel();
        await tester.pumpWidget(
          TsukuyomiApp(
            controller: room,
            motionLoader: motionLoader,
            modelLoader: () async => model,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 34));
        final sending = room.send('并行流式性能测试');
        for (var i = 0; chat.stream == null && i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(chat.stream, isNotNull);
        final list = find
            .descendant(
              of: find.descendant(
                of: find.byType(RoomChatView),
                matching: find.byType(CustomScrollView),
              ),
              matching: find.byType(Scrollable),
            )
            .first;
        final rect = tester.getRect(list);
        final start = Offset(rect.left + 8, rect.top + rect.height * .15);
        final move = (rect.height * .6 / 18).clamp(4.0, 20.0);
        TestGesture? gesture;
        for (var step = 0; step < 240; step++) {
          expect(chat.stream!.isClosed, false, reason: 'stream step $step');
          expect(room.generating, true, reason: 'stream step $step');
          chat.stream!.add('片段 $step，');
          if (step % 24 == 0) gesture = await tester.startGesture(start);
          if (step % 24 < 18) {
            await gesture!.moveBy(Offset(0, move));
          } else if (step % 24 == 18) {
            await gesture!.up();
            gesture = null;
          }
          await tester.pump(const Duration(milliseconds: 16));
        }
        await chat.stream!.close();
        await sending;
        expect(room.generating, false);
        expect(room.turns.last.assistant, contains('片段 239'));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant({
        mobile ? TargetPlatform.android : TargetPlatform.windows,
      }),
    );
  }
  testWidgets(
    'Android Room animates during scrolling, typing and changing insets',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final room = RoomController(
        storage: MemoryStorage(),
        chat: FakeChat(),
        site: FakeSite(),
        voice: SilentVoice(),
      );
      addTearDown(room.dispose);
      await room.initialize();
      room.turns = List.generate(
        100,
        (i) => ChatTurn(
          id: 'activity-$i',
          user: '历史问题$i',
          assistant: '这是用于拖动的历史回复$i。还有一段完整解释。',
          createdAt: DateTime(2020),
        ),
      );
      final model = _CountingModel();
      await tester.pumpWidget(
        TsukuyomiApp(
          controller: room,
          motionLoader: motionLoader,
          modelLoader: () async => model,
        ),
      );
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 34));
      }
      expect(model.ticks, greaterThan(3));
      final stage = tester.widget<CharacterStage>(find.byType(CharacterStage));
      final activity = stage.interacting!;
      final chat = find.byType(RoomChatView);
      final scroll = find
          .descendant(
            of: find.descendant(
              of: chat,
              matching: find.byType(CustomScrollView),
            ),
            matching: find.byType(Scrollable),
          )
          .first;
      final gesture = await tester.startGesture(tester.getCenter(scroll));
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
      expect(activity.value, true);
      final dragTicks = model.ticks;
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(model.ticks, greaterThan(dragTicks));
      await gesture.up();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 200));
      expect(activity.value, false);
      await tester.pump(const Duration(milliseconds: 34));
      await tester.pump(const Duration(milliseconds: 34));
      expect(model.ticks, greaterThan(dragTicks));

      final field = find.byKey(const Key('message-input'));
      await tester.tap(field);
      await tester.pump();
      final editor = tester.state<EditableTextState>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '中文输入',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 0, end: 4),
        ),
      );
      await tester.pump();
      expect(activity.value, true);
      final typingTicks = model.ticks;
      await tester.pump(const Duration(milliseconds: 100));
      expect(model.ticks, greaterThan(typingTicks));
      await tester.pump(const Duration(milliseconds: 30));
      expect(activity.value, false);
      // Animation continues without replacing the focused composing editor.
      await tester.pump(const Duration(milliseconds: 34));
      await tester.pump(const Duration(milliseconds: 34));
      expect(model.ticks, greaterThan(typingTicks));
      expect(editor.widget.focusNode.hasFocus, true);

      tester.view.viewInsets = const FakeViewPadding(bottom: 50);
      await tester.pump();
      expect(activity.value, true);
      final insetTicks = model.ticks;
      for (final inset in [100.0, 180.0, 240.0, 330.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 32));
      }
      await tester.pump(const Duration(milliseconds: 190));
      expect(activity.value, false);
      await tester.pump(const Duration(milliseconds: 34));
      await tester.pump(const Duration(milliseconds: 34));
      expect(model.ticks, greaterThan(insetTicks));
      expect(
        tester.state<EditableTextState>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        ),
        same(editor),
      );
      expect(
        editor.widget.controller.value.composing,
        const TextRange(start: 0, end: 4),
      );
      expect(
        tester.widget<CharacterStage>(find.byType(CharacterStage)).interacting,
        same(activity),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}
