import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/room/room_page.dart';
import 'package:tsukuyomi_space_app/features/room/room_chat_view.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/live2d/character_stage.dart';

import '../test/support/fakes.dart';

Element? _find(Element root, bool Function(Widget) matches) {
  if (matches(root.widget)) return root;
  Element? result;
  root.visitChildren((child) => result ??= _find(child, matches));
  return result;
}

Future<void> _wait(bool Function() ready, String description) async {
  final deadline = DateTime.now().add(const Duration(seconds: 12));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Native Room IME timed out: $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  await WidgetsBinding.instance.endOfFrame;
}

/// Uses the actual platform text input connection, not flutter_test's fake IME.
Future<void> probeAndroidRoomKeyboard(Live2DModel model) async {
  final room = RoomController(
    storage: MemoryStorage(),
    chat: FakeChat(),
    site: FakeSite(),
    voice: SilentVoice(),
  );
  await room.initialize();
  room.turns = List.generate(
    2000,
    (i) => ChatTurn(
      id: 'native-history-$i',
      user: '历史问题 $i',
      assistant: i == 1999
          ? List.generate(600, (j) => '第 $j 句是较长的历史回复。').join()
          : '历史回复 $i。第二句。',
      createdAt: DateTime(2020),
    ),
  );
  runApp(
    MaterialApp(
      home: RoomPage(controller: room, modelLoader: () async => model),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  await Future<void>.delayed(const Duration(milliseconds: 200));
  Element field() {
    final root = WidgetsBinding.instance.rootElement!;
    final slot = _find(root, (w) => w.key == const Key('message-input'))!;
    return _find(slot, (w) => w is EditableText)!;
  }

  Rect viewport() {
    final e = _find(
      WidgetsBinding.instance.rootElement!,
      (w) => w.key == const Key('room-character-viewport'),
    )!;
    final box = e.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  final before = field();
  final editable = (before as StatefulElement).state as EditableTextState;
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final initialViewport = viewport();
  try {
    final chatElement = _find(
      WidgetsBinding.instance.rootElement!,
      (widget) => widget is RoomChatView,
    )!;
    var mountedTexts = 0;
    void countTexts(Element element) {
      if (element.widget is SelectableText) mountedTexts++;
      element.visitChildren(countTexts);
    }

    countTexts(chatElement);
    final scrollElement = _find(chatElement, (widget) => widget is Scrollable)!;
    final scroll = (scrollElement as StatefulElement).state as ScrollableState;
    final activity =
        (_find(
                  WidgetsBinding.instance.rootElement!,
                  (widget) => widget is CharacterStage,
                )!.widget
                as CharacterStage)
            .interacting!;
    if (mountedTexts > 40 || mountedTexts == 0) {
      throw StateError('Native transcript mounted $mountedTexts text widgets');
    }
    var modelUpdates = 0;
    void updated() => modelUpdates++;
    model.addListener(updated);
    try {
      await _wait(() => modelUpdates > 0, 'visible model advances before drag');
      final drag = scroll.position.drag(
        DragStartDetails(globalPosition: Offset(100, 400)),
        () {},
      );
      drag.update(
        DragUpdateDetails(
          delta: Offset(0, 40),
          primaryDelta: 40,
          globalPosition: Offset(100, 440),
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!activity.value) {
        throw StateError('Native drag did not signal activity');
      }
      final beforeDrag = modelUpdates;
      await _wait(
        () => activity.value && modelUpdates > beforeDrag,
        'model advances during drag',
      );
      final duringDrag = modelUpdates - beforeDrag;
      final afterDrag = modelUpdates;
      drag.cancel();
      await _wait(() => !activity.value, 'drag completes');
      await _wait(() => modelUpdates > afterDrag, 'model continues after drag');
      // ignore: avoid_print
      print(
        'TSUKUYOMI_ROOM_LAZY_OK turns=2000 sentences=600 mounted_texts=$mountedTexts drag_model_updates=$duringDrag animation_continues=true resumed=true',
      );
    } finally {
      model.removeListener(updated);
    }
    for (var cycle = 0; cycle < 3; cycle++) {
      final text = '你好 $cycle';
      editable.widget.controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      await room.saveComposerDraft(text);
      editable.widget.focusNode.requestFocus();
      await WidgetsBinding.instance.endOfFrame;
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      await _wait(() => view.viewInsets.bottom > 0, 'show keyboard');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      room.error = 'fixture status update';
      room.workspace.changed();
      await WidgetsBinding.instance.endOfFrame;
      if (!identical(field(), before) ||
          !editable.widget.focusNode.hasFocus ||
          editable.widget.controller.text != text ||
          view.viewInsets.bottom <= 0 ||
          viewport() != initialViewport) {
        throw StateError(
          'Native Room keyboard lost its editor, focus, text or stable viewport',
        );
      }
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await _wait(() => view.viewInsets.bottom == 0, 'hide keyboard');
      if (!identical(field(), before)) {
        throw StateError('IME close replaced the editor');
      }
    }
    // ignore: avoid_print
    print(
      'TSUKUYOMI_ROOM_IME_OK cycles=3 actual_keyboard=true stable_editor=true stable_viewport=true',
    );
  } finally {
    runApp(const MaterialApp(home: SizedBox.shrink()));
    await WidgetsBinding.instance.endOfFrame;
    room.dispose();
  }
}
