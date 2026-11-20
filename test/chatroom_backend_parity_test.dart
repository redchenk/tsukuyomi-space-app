import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/chatroom/chatroom_session.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';
import 'support/site_fixture.dart';

void main() {
  test('two native channel sessions see a post and its removal on the real fixture server', () async {
    expect(
      Uri.parse(siteFixtureOrigin).host,
      isIn(['127.0.0.1', 'localhost', '::1']),
    );
    Future<RoomController> room() async {
      final client = SiteClient();
      final c = RoomController(
        storage: MemoryStorage()
          ..value = const RoomSettings(demo: false, siteUrl: siteFixtureOrigin),
        site: client,
        chat: FakeChat(),
        voice: SilentVoice(),
      );
      addTearDown(c.dispose);
      await c.initialize();
      return c;
    }

    Future<void> until(ChatroomSession s, bool Function() test) async {
      if (test()) return;
      final done = Completer<void>();
      void check() {
        if (test() && !done.isCompleted) done.complete();
      }

      s.addListener(check);
      try {
        await done.future.timeout(const Duration(seconds: 12));
      } finally {
        s.removeListener(check);
      }
    }

    final writer = await room(), reader = await room();
    await writer.login('e2e-user', 'e2e-password');
    final sender = ChatroomSession(writer, 'studio'),
        viewer = ChatroomSession(reader, 'studio');
    addTearDown(sender.dispose);
    addTearDown(viewer.dispose);
    sender.activate(true);
    viewer.activate(true);
    await until(viewer, () => viewer.status == 'live');
    final message =
        'local native channel fixture ${DateTime.now().microsecondsSinceEpoch}';
    sender.draft.text = message;
    await sender.send();
    expect(sender.feedback, isEmpty);
    await until(
      viewer,
      () => viewer.messages.values.any((m) => m['content'] == message),
    );
    final id =
        viewer.messages.values.singleWhere((m) => m['content'] == message)['id']
            as int;
    await sender.action(id, 'remove');
    await until(viewer, () => viewer.messages[id]?['removed'] == true);
    expect(viewer.messages[id]?['content'], isNot(message));
  }, skip: !const bool.fromEnvironment('RUN_WEBSITE_INTEGRATION'));
}
