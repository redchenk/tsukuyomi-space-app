import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/site_message_anchor.dart';
import 'package:tsukuyomi_space_app/features/site/site_page.dart';
import 'package:tsukuyomi_space_app/features/site/site_widgets.dart';

import 'support/fakes.dart';

List<Map<String, dynamic>> _messages(String owner) => [
  for (var id = 1; id <= 18; id++)
    {
      'id': id,
      'parent_id': null,
      'author': '$owner-$id',
      'content': '根留言 $id',
      'created_at': '2026-09-${(31 - id).toString().padLeft(2, '0')}',
    },
  for (var id = 101; id <= 104; id++)
    {
      'id': id,
      'parent_id': 10,
      'author': '$owner-$id',
      'content': '隐藏回复 $id',
      'created_at': '2026-09-30T${id - 100}:00:00',
    },
];

class _AnchorSite extends FakeSite implements SiteDataService {
  final requests = <String>[];
  Future<Map<String, dynamic>> Function(String owner)? messages;
  Future<Map<String, dynamic>> Function(String owner)? comments;

  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    requests.add('$method $path');
    final owner = userId;
    if (path.endsWith('/articles/7/messages')) {
      return comments?.call(owner) ??
          Future.value({'success': true, 'data': _messages(owner)});
    }
    if (path.endsWith('/messages')) {
      return messages?.call(owner) ??
          Future.value({'success': true, 'data': _messages(owner)});
    }
    if (path.endsWith('/articles/7')) {
      return {
        'success': true,
        'data': {
          'id': 7,
          'title': '文章',
          'content': '[跳到隐藏回复](#comment-104)\n\n正文。',
          'content_format': 'markdown',
        },
      };
    }
    return {'success': true, 'data': []};
  }
}

Future<RoomController> _controller(_AnchorSite site) async {
  final controller = RoomController(
    storage: MemoryStorage(),
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await controller.initialize();
  await controller.login('alice', 'test');
  return controller;
}

Widget _app(RoomController controller, String path) => MaterialApp(
  home: SitePage(
    key: const ValueKey('anchor-page'),
    controller: controller,
    path: path,
  ),
);

void _size(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

ScrollController _scroll(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(find.byType(SingleChildScrollView).first)
    .controller!;

void _expectVisible(WidgetTester tester, String content) {
  final text = find.byWidgetPredicate(
    (widget) => widget is SelectableText && widget.data == content,
  );
  expect(text, findsOneWidget);
  final rect = tester.getRect(text);
  final header = tester.getRect(find.byType(SiteHeader));
  expect(rect.top, greaterThanOrEqualTo(header.bottom));
  expect(rect.bottom, lessThanOrEqualTo(800));
}

void main() {
  test('anchor parser accepts only the matching website message fragment', () {
    expect(SiteMessageAnchor.parse('/plaza', 'msg-17')?.id, '17');
    expect(
      SiteMessageAnchor.parse('/articles/7/slug', 'comment-104')?.id,
      '104',
    );
    expect(SiteMessageAnchor.parse('/plaza', 'comment-104'), isNull);
    expect(SiteMessageAnchor.parse('/articles/7', 'msg-17'), isNull);
    expect(SiteMessageAnchor.parse('/plaza', 'msg-17-more'), isNull);
    expect(SiteMessageAnchor.parse('/plaza', 'msg-NaN'), isNull);
  });

  test('anchor selects the root page for a nested website reply', () {
    final threads = messageThreads(_messages('alice'));
    expect(findSiteMessageAnchor(threads, '17')?.page, 3);
    final reply = findSiteMessageAnchor(threads, '104')!;
    expect(reply.page, 2);
    expect(reply.rootId, '10');
    expect(reply.reply, isTrue);
    expect(findSiteMessageAnchor(threads, '999'), isNull);
  });

  testWidgets('plaza target selects its page and scrolls into the viewport', (
    tester,
  ) async {
    _size(tester);
    final site = _AnchorSite();
    final controller = await _controller(site);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller, '/plaza#msg-17'));
    await tester.pumpAndSettle();
    expect(find.text('第 3 页 / 共 3 页'), findsOneWidget);
    expect(find.byKey(const ValueKey('site-message-1')), findsNothing);
    _expectVisible(tester, '根留言 17');
    expect(_scroll(tester).offset, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden plaza reply is expanded before scrolling to its page', (
    tester,
  ) async {
    _size(tester);
    final site = _AnchorSite();
    final controller = await _controller(site);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller, '/plaza#msg-104'));
    await tester.pumpAndSettle();
    expect(find.text('第 2 页 / 共 3 页'), findsOneWidget);
    expect(find.text('收起回复'), findsOneWidget);
    _expectVisible(tester, '隐藏回复 104');
    expect(tester.takeException(), isNull);
  });

  testWidgets('comment reveal waits for loading and expands the exact reply', (
    tester,
  ) async {
    _size(tester);
    final site = _AnchorSite();
    final pending = Completer<Map<String, dynamic>>();
    site.comments = (_) => pending.future;
    final c = await _controller(site);
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c, '/articles/7#comment-104'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('site-message-104')), findsNothing);
    expect(_scroll(tester).offset, 0);
    pending.complete({'success': true, 'data': _messages('alice')});
    await tester.pumpAndSettle();
    _expectVisible(tester, '隐藏回复 104');
    expect(find.text('收起回复'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'same document hash changes reuse content and choose the new page',
    (tester) async {
      _size(tester);
      final site = _AnchorSite();
      final controller = await _controller(site);
      addTearDown(controller.dispose);
      await tester.pumpWidget(_app(controller, '/plaza#msg-17'));
      await tester.pumpAndSettle();
      final requests = site.requests.length;
      await tester.pumpWidget(_app(controller, '/plaza#msg-1'));
      await tester.pumpAndSettle();
      expect(site.requests.length, requests);
      expect(find.text('第 1 页 / 共 3 页'), findsOneWidget);
      _expectVisible(tester, '根留言 1');
      tester.widget<SiteHeader>(find.byType(SiteHeader)).onGo('/plaza#msg-104');
      await tester.pumpAndSettle();
      expect(site.requests.length, requests);
      expect(find.text('第 2 页 / 共 3 页'), findsOneWidget);
      _expectVisible(tester, '隐藏回复 104');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual pagination stays put until the anchor is requested again',
    (tester) async {
      _size(tester);
      final site = _AnchorSite();
      final c = await _controller(site);
      addTearDown(c.dispose);
      await tester.pumpWidget(_app(c, '/plaza#msg-17'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('上一页'));
      await tester.tap(find.text('上一页'));
      await tester.pumpAndSettle();
      expect(find.text('第 2 页 / 共 3 页'), findsOneWidget);
      await tester.pumpWidget(_app(c, '/plaza#msg-17'));
      await tester.pumpAndSettle();
      expect(find.text('第 2 页 / 共 3 页'), findsOneWidget);
      tester.widget<SiteHeader>(find.byType(SiteHeader)).onGo('/plaza#msg-17');
      await tester.pumpAndSettle();
      expect(find.text('第 3 页 / 共 3 页'), findsOneWidget);
      _expectVisible(tester, '根留言 17');
    },
  );

  testWidgets(
    'missing targets do not schedule repeated scrolling or change pages',
    (tester) async {
      _size(tester);
      final site = _AnchorSite();
      final c = await _controller(site);
      addTearDown(c.dispose);
      await tester.pumpWidget(_app(c, '/plaza#msg-999'));
      await tester.pumpAndSettle();
      expect(find.text('第 1 页 / 共 3 页'), findsOneWidget);
      expect(_scroll(tester).offset, 0);
      await tester.ensureVisible(find.text('下一页'));
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(find.text('第 2 页 / 共 3 页'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('account switching cancels a target awaiting the old response', (
    tester,
  ) async {
    _size(tester);
    final site = _AnchorSite();
    final pending = Completer<Map<String, dynamic>>();
    site.messages = (owner) => owner == 'alice'
        ? pending.future
        : Future.value({'success': true, 'data': _messages(owner)});
    final c = await _controller(site);
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c, '/plaza#msg-17'));
    await tester.pump();
    await c.logout();
    await c.login('bob', 'test');
    await tester.pumpAndSettle();
    pending.complete({'success': true, 'data': _messages('alice')});
    await tester.pumpAndSettle();
    expect(find.text('第 1 页 / 共 3 页'), findsOneWidget);
    expect(find.byKey(const ValueKey('site-message-17')), findsNothing);
    expect(find.text('alice-1'), findsNothing);
    expect(_scroll(tester).offset, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'copying a reply links its exact anchor without awarding plaza growth',
    (tester) async {
      _size(tester);
      final site = _AnchorSite();
      final c = await _controller(site);
      addTearDown(c.dispose);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(_app(c, '/plaza#msg-104'));
      await tester.pumpAndSettle();
      final copy = find.descendant(
        of: find.byKey(const ValueKey('site-message-104')),
        matching: find.text('复制链接'),
      );
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(copied, 'https://yachiyo.hk/plaza#msg-104');
      expect(site.requests.where((path) => path.startsWith('POST ')), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
