import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';

void main() {
  late MemoryStorage storage;
  late FakeChat chat;
  late FakeSite site;
  late RoomController c;
  setUp(() {
    storage = MemoryStorage();
    chat = FakeChat();
    site = FakeSite();
    c = RoomController(
      storage: storage,
      chat: chat,
      site: site,
      voice: SilentVoice(),
    );
  });
  tearDown(() => c.dispose());
  test(
    'many stream fragments preserve text and coalesce UI notifications',
    () async {
      chat.controlled = true;
      await c.initialize();
      final sending = c.send('分片回复');
      for (var i = 0; chat.stream == null && i < 50; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(chat.stream, isNotNull);
      var updates = 0;
      void changed() => updates++;
      c.streamRevision.addListener(changed);
      final expected = StringBuffer();
      for (var i = 0; i < 10000; i++) {
        final fragment = i % 3 == 0 ? '你好😀' : '$i ';
        expected.write(fragment);
        chat.stream!.add(fragment);
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final text = expected.toString();
      expect(c.partial, text);
      expect(identical(c.partial, c.partial), true);
      expect(updates, inInclusiveRange(1, 2));
      await chat.stream!.close();
      await sending;
      expect(c.turns.single.assistant, text.trim());
      expect(c.partial, isEmpty);
      c.streamRevision.removeListener(changed);
    },
  );
  test(
    'new conversation resets model context without deleting saved history',
    () async {
      await c.initialize();
      await c.send('previous conversation');
      final previous = c.turns.single.id;
      await c.startConversation();
      expect(c.visibleTurns, isEmpty);
      expect(c.turns.single.id, previous);
      await c.send('fresh conversation');
      expect(chat.lastContext, isEmpty);
      expect(c.visibleTurns.single.user, 'fresh conversation');
      expect(storage.histories['demo'], hasLength(2));
    },
  );
  test(
    'new context excludes known turns even when their timestamp is ahead',
    () async {
      await c.initialize();
      c.turns = [
        ChatTurn(
          id: 'clock-ahead',
          user: 'old',
          assistant: 'old reply',
          createdAt: DateTime(2100),
        ),
      ];
      await c.startConversation();
      expect(c.visibleTurns, isEmpty);
      await c.send('new');
      expect(chat.lastContext, isEmpty);
      expect(c.visibleTurns.single.user, 'new');
      expect(c.turns.map((turn) => turn.id), contains('clock-ahead'));
    },
  );
  test('demo replies never upload even after login', () async {
    await c.initialize();
    await c.login('alice', 'pass');
    await c.send('hello');
    expect(c.turns.single.assistant, chat.answer);
    expect(site.savedIds, isEmpty);
    expect(storage.histories['demo']!.length, 1);
  });
  test('interrupted generation retains draft but no partial turn', () async {
    chat.controlled = true;
    await c.initialize();
    final future = c.send('unfinished');
    await Future<void>.delayed(Duration.zero);
    chat.stream!.add('partial');
    await Future<void>.delayed(Duration.zero);
    expect(c.partial, 'partial');
    c.stop(fromComposer: true);
    await future;
    expect(c.interruptedReply, 'partial');
    expect(c.canRetryReply, isTrue);
    expect(c.turns, isEmpty);
    expect(c.draft, 'unfinished');
    expect(c.generating, false);
    expect(site.savedIds, isEmpty);
    chat.controlled = false;
    await c.retryReply();
    expect(c.interruptedReply, isEmpty);
    expect(c.turns.single.user, 'unfinished');
    expect(c.turns.single.assistant, chat.answer);
  });
  test(
    'a broken replacement keeps the original turn and retries in place',
    () async {
      await c.initialize();
      await c.send('first');
      final original = c.turns.single;
      chat.controlled = true;
      final sending = c.send('edited', replacement: original);
      await Future<void>.delayed(Duration.zero);
      chat.stream!.add('broken reply');
      chat.stream!.addError(const ModelStreamInterrupted('connection closed'));
      await chat.stream!.close();
      await sending;
      expect(c.turns.single, same(original));
      expect(c.interruptedReply, 'broken reply');
      expect(c.canRetryReply, isTrue);
      chat.controlled = false;
      await c.retryReply();
      expect(c.turns.single.id, original.id);
      expect(c.turns.single.user, 'edited');
      expect(c.interruptedReply, isEmpty);
    },
  );
  test(
    'declined content never enters a retained partial or a saved turn',
    () async {
      await c.initialize();
      chat.controlled = true;
      final sending = c.send('test');
      await Future<void>.delayed(Duration.zero);
      chat.stream!.add('unconfirmed');
      chat.stream!.addError(const ApiFailure('provider declined'));
      await chat.stream!.close();
      await sending;
      expect(c.interruptedReply, isEmpty);
      expect(c.turns, isEmpty);
    },
  );
  test(
    'offline completed turns retry with the same ID and stay account scoped',
    () async {
      storage.value = const RoomSettings(demo: false, model: 'test');
      await c.initialize();
      await c.login('alice', 'pass');
      site.offline = true;
      await c.send('remember this');
      final id = c.turns.single.id;
      expect(c.pendingCount, 1);
      expect(storage.histories['https://yachiyo.hk:alice']!.single.id, id);
      site.offline = false;
      await c.sync();
      expect(c.pendingCount, 0);
      expect(site.savedIds, [id, id]);
      await c.logout();
      expect(c.turns, isEmpty);
      expect(storage.histories['https://yachiyo.hk:alice']!.single.id, id);
    },
  );
  test('disk failure prevents upload and preserves draft', () async {
    storage.value = const RoomSettings(demo: false, model: 'test');
    await c.initialize();
    await c.login('alice', 'pass');
    storage.failHistory = true;
    await c.send('persist first');
    expect(site.savedIds, isEmpty);
    expect(c.turns, isEmpty);
    expect(c.draft, 'persist first');
    expect(c.error, isNotEmpty);
  });
  test('server deletion is reflected on explicit sync', () async {
    storage.value = const RoomSettings(demo: false, model: 'test');
    await c.initialize();
    await c.login('alice', 'pass');
    await c.send('hello');
    expect(c.turns, hasLength(1));
    site.data.clear();
    await c.sync();
    expect(c.turns, isEmpty);
  });
  test('switching service origin drops the previous account cookie', () async {
    await c.initialize();
    await c.login('alice', 'pass');
    await c.configure(
      const RoomSettings(
        siteUrl: 'https://other.example.com',
        demo: false,
        model: 'x',
      ),
    );
    expect(c.account, isNull);
    expect(site.cookie, isNull);
    expect(c.turns, isEmpty);
  });
}
