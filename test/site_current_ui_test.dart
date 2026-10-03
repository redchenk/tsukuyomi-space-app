import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/native_auth_page.dart';
import 'package:tsukuyomi_space_app/features/site/plaza_composer.dart';
import 'package:tsukuyomi_space_app/features/site/site_page.dart';

import 'support/fakes.dart';

Map<String, dynamic> _message(
  int id,
  String content,
  String created, {
  int? parent,
}) => {
  'id': id,
  'parent_id': parent,
  'author': 'writer-$id',
  'author_nickname': '创作者 $id',
  'content': content,
  'created_at': created,
  'like_count': 0,
};

class _CurrentSite extends FakeSite implements SiteDataService {
  final calls = <Uri>[];
  final messages = [
    _message(1, '#月读# 主题留言', '2026-10-01T12:00:00Z'),
    _message(2, '回复最多但发布最早', '2026-09-28T12:00:00Z'),
    _message(3, '同回复数量较早', '2026-10-02T08:00:00+08:00'),
    _message(4, '同回复数量较晚', '2026-10-02T01:00:00Z'),
    _message(21, '只在回复中的搜索词：鹈鹕骑车', '2026-10-01T12:00:00Z', parent: 2),
    _message(22, '第二条回复', '2026-10-01T12:10:00Z', parent: 2),
    _message(31, '较早留言的回复', '2026-10-02T01:00:00Z', parent: 3),
    _message(41, '较晚留言的回复', '2026-10-02T02:00:00Z', parent: 4),
  ];
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = Uri.parse(path.replaceFirst(RegExp(r'^/api/live/\d+'), '/api'));
    calls.add(uri);
    expect(method, 'GET');
    final Object data;
    switch (uri.path) {
      case '/api/articles':
        return {
          'success': true,
          'data': [
            {
              'id': 42,
              'title': '保留筛选条件的文章',
              'excerpt': '导航回归正文摘要',
              'category': '技术',
              'author_username': 'alice',
              'created_at': '2026-10-02T00:00:00Z',
              'read_time': '2 min',
            },
          ],
          'pagination': {
            'page': int.tryParse(uri.queryParameters['page'] ?? '1'),
            'totalPages': 3,
            'total': 18,
          },
        };
      case '/api/articles/42':
        data = {
          'id': 42,
          'title': '保留筛选条件的文章',
          'category': '技术',
          'content': '文章正文',
          'content_format': 'markdown',
        };
      case '/api/article-categories':
        data = [
          {'id': 1, 'name': '技术'},
          {'id': 2, 'name': '公告'},
        ];
      case '/api/articles/42/messages':
        data = <Map<String, dynamic>>[];
      case '/api/messages':
        data = messages;
      case '/api/stats':
        data = {'messages': 4, 'articles': 18};
      case '/api/messages/topics':
        data = [
          {'topic': '月读', 'count': 1},
        ];
      case '/api/growth/public':
        data = <Map<String, dynamic>>[];
      default:
        throw StateError('Unexpected current UI API: $method $uri');
    }
    return {'success': true, 'data': data};
  }

  Uri get lastArticleRequest =>
      calls.lastWhere((uri) => uri.path == '/api/articles');
}

class _NavigationLog extends NavigatorObserver {
  final names = <String>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    names.add(route.settings.name ?? '');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    names.add(newRoute?.settings.name ?? '');
  }
}

Future<
  ({
    _CurrentSite site,
    RoomController room,
    GlobalKey<NavigatorState> navigation,
    _NavigationLog log,
  })
>
_mountSite(WidgetTester tester, String path) async {
  tester.view.physicalSize = const Size(1440, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final site = _CurrentSite();
  final room = RoomController(
    storage: MemoryStorage(),
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await room.initialize();
  final navigation = GlobalKey<NavigatorState>(), log = _NavigationLog();
  Route<void> makeRoute(RouteSettings settings) => MaterialPageRoute<void>(
    settings: settings,
    builder: (_) {
      final target = settings.name ?? path;
      return target == '/friend-links'
          ? const Scaffold(body: Text('native friend links'))
          : SitePage(controller: room, path: target);
    },
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    room.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigation,
      navigatorObservers: [log],
      initialRoute: path,
      onGenerateInitialRoutes: (initial) => [
        makeRoute(RouteSettings(name: initial)),
      ],
      onGenerateRoute: makeRoute,
    ),
  );
  await tester.pumpAndSettle();
  return (site: site, room: room, navigation: navigation, log: log);
}

Future<TextEditingController> _mountComposer(
  WidgetTester tester, {
  required VoidCallback onSubmit,
  bool busy = false,
  bool signedIn = true,
  ValueChanged<String>? onChanged,
}) async {
  final controller = TextEditingController();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PlazaComposer(
            controller: controller,
            signedIn: signedIn,
            busy: busy,
            onSubmit: onSubmit,
            onLogin: () {},
            onChanged: onChanged ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _shortcut(WidgetTester tester, LogicalKeyboardKey modifier) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

void main() {
  testWidgets('stage defaults to latest with no inherited filters', (
    tester,
  ) async {
    final result = await _mountSite(tester, '/stage');
    expect(result.site.lastArticleRequest.queryParameters, {
      'limit': '6',
      'page': '1',
      'sort': 'latest',
      'category': '',
      'q': '',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'stage deep link retains filter context through article and resets on a fresh bare route',
    (tester) async {
      final start = Uri(
        path: '/stage',
        queryParameters: {
          'sort': 'daily',
          'page': '2',
          'category': '技术',
          'q': '月',
        },
      ).toString();
      final result = await _mountSite(tester, start);
      final expected = {
        'limit': '6',
        'page': '2',
        'sort': 'daily',
        'category': '技术',
        'q': '月',
      };
      expect(result.site.lastArticleRequest.queryParameters, expected);
      final article = find.text('保留筛选条件的文章');
      await tester.ensureVisible(article);
      await tester.tap(article);
      await tester.pumpAndSettle();
      final target = Uri.parse(result.log.names.last);
      expect(target.path, '/articles/42');
      final from = Uri.parse(target.queryParameters['from']!);
      expect(from.path, '/stage');
      expect(from.queryParameters, {
        'sort': 'daily',
        'page': '2',
        'category': '技术',
        'q': '月',
      });
      final back = find.text('返回主舞台');
      await tester.ensureVisible(back);
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(
        Uri.parse(result.log.names.last).queryParameters,
        from.queryParameters,
      );
      expect(result.site.lastArticleRequest.queryParameters, expected);
      result.navigation.currentState!.pushNamed('/stage');
      await tester.pumpAndSettle();
      expect(result.site.lastArticleRequest.queryParameters, {
        'limit': '6',
        'page': '1',
        'sort': 'latest',
        'category': '',
        'q': '',
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'composer caps typed text at 300 and disables empty or whitespace posts',
    (tester) async {
      var submitted = 0;
      final controller = await _mountComposer(
        tester,
        onSubmit: () => submitted++,
      );
      FilledButton button() =>
          tester.widget<FilledButton>(find.byKey(const Key('plaza-submit')));
      expect(button().onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('plaza-composer-input')),
        '  \n\t ',
      );
      await tester.pump();
      expect(button().onPressed, isNull);
      await _shortcut(tester, LogicalKeyboardKey.controlLeft);
      expect(submitted, 0);
      await tester.enterText(
        find.byKey(const Key('plaza-composer-input')),
        List.filled(320, '月').join(),
      );
      await tester.pump();
      expect(controller.text, hasLength(300));
      expect(button().onPressed, isNotNull);
      controller.text = List.filled(301, '月').join();
      await tester.pump();
      expect(
        button().onPressed,
        isNull,
        reason: 'Restored overlong text cannot bypass the publisher limit.',
      );
    },
  );

  testWidgets(
    'topic inserts a selected placeholder and mention replaces selection while preserving input focus',
    (tester) async {
      final changes = <String>[];
      final controller = await _mountComposer(
        tester,
        onSubmit: () {},
        onChanged: changes.add,
      );
      final input = find.byKey(const Key('plaza-composer-input'));
      await tester.enterText(input, '今天');
      controller.selection = const TextSelection.collapsed(offset: 2);
      await tester.tap(find.byKey(const Key('plaza-insert-topic')));
      await tester.pump();
      expect(controller.text, '今天#话题#');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 3, extentOffset: 5),
      );
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.focusNode.hasFocus, isTrue);
      expect(changes.last, '今天#话题#');
      await tester.tap(find.byKey(const Key('plaza-insert-mention')));
      await tester.pump();
      expect(controller.text, '今天#@#');
      expect(controller.selection, const TextSelection.collapsed(offset: 4));
      expect(editable.focusNode.hasFocus, isTrue);
      expect(changes.last, '今天#@#');
      controller.value = TextEditingValue(
        text: List.filled(300, '月').join(),
        selection: const TextSelection.collapsed(offset: 300),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('plaza-insert-topic')));
      await tester.pump();
      expect(
        controller.text,
        hasLength(300),
        reason: 'Toolbar insertion obeys the same length limit.',
      );
    },
  );

  testWidgets(
    'composer accepts Control or Command Enter but never submits active IME composition',
    (tester) async {
      var submitted = 0;
      final controller = await _mountComposer(
        tester,
        onSubmit: () => submitted++,
      );
      await tester.enterText(
        find.byKey(const Key('plaza-composer-input')),
        '准备发布',
      );
      await _shortcut(tester, LogicalKeyboardKey.controlLeft);
      expect(submitted, 1);
      await _shortcut(tester, LogicalKeyboardKey.metaLeft);
      expect(submitted, 2);
      controller.value = const TextEditingValue(
        text: '输入中的月',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('plaza-submit')))
            .onPressed,
        isNull,
      );
      await _shortcut(tester, LogicalKeyboardKey.controlLeft);
      await _shortcut(tester, LogicalKeyboardKey.metaLeft);
      expect(submitted, 2);
      controller.value = controller.value.copyWith(composing: TextRange.empty);
      await tester.pump();
      await _shortcut(tester, LogicalKeyboardKey.controlLeft);
      expect(submitted, 3);
    },
  );

  testWidgets('busy composer disables publishing and insertion', (
    tester,
  ) async {
    var submitted = 0;
    final controller = await _mountComposer(
      tester,
      busy: true,
      onSubmit: () => submitted++,
    );
    controller.text = '等待发布结果';
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('plaza-submit')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<ActionChip>(find.byKey(const Key('plaza-insert-topic')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<ActionChip>(find.byKey(const Key('plaza-insert-mention')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('plaza-composer-input')))
          .enabled,
      isFalse,
    );
    expect(submitted, 0);
  });

  testWidgets(
    'plaza topic deep link filters immediately and search matches reply content',
    (tester) async {
      await _mountSite(
        tester,
        Uri(path: '/plaza', queryParameters: {'topic': '月读'}).toString(),
      );
      final search = find.byKey(const Key('plaza-search'));
      expect(tester.widget<TextField>(search).controller!.text, '#月读');
      expect(find.byKey(const Key('site-message-1')), findsOneWidget);
      expect(find.byKey(const Key('site-message-2')), findsNothing);
      await tester.enterText(search, '鹈鹕骑车');
      await tester.pumpAndSettle(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('site-message-2')), findsOneWidget);
      expect(find.byKey(const Key('site-message-22')), findsOneWidget);
      expect(find.byKey(const Key('site-message-21')), findsNothing);
      final expand = find.text('查看全部 2 条回复');
      await tester.ensureVisible(expand);
      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('site-message-21')), findsOneWidget);
      expect(find.byKey(const Key('site-message-1')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'plaza replied filter sorts reply count before actual creation time',
    (tester) async {
      await _mountSite(tester, '/plaza');
      await tester.tap(find.text('有回复'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('site-message-1')),
        findsNothing,
        reason: 'No-reply roots are excluded.',
      );
      final most = tester
          .getTopLeft(find.byKey(const Key('site-message-2')))
          .dy;
      final later = tester
          .getTopLeft(find.byKey(const Key('site-message-4')))
          .dy;
      final earlier = tester
          .getTopLeft(find.byKey(const Key('site-message-3')))
          .dy;
      expect(
        most,
        lessThan(later),
        reason: 'Reply count takes priority over creation date.',
      );
      expect(
        later,
        lessThan(earlier),
        reason: '01:00Z is later than 08:00+08:00 on the same day.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('plaza friend links entry navigates natively', (tester) async {
    final result = await _mountSite(tester, '/plaza');
    final entry = find.byKey(const Key('plaza-friend-links'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(result.log.names.last, '/friend-links');
    expect(find.text('native friend links'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('plaza topics inside content filter the native wall', (
    tester,
  ) async {
    await _mountSite(tester, '/plaza');
    final content = find.text('#月读# 主题留言', findRichText: true);
    await tester.ensureVisible(content);
    await tester.tapAt(tester.getTopLeft(content) + const Offset(18, 12));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('plaza-search')))
          .controller!
          .text,
      '#月读',
    );
    expect(find.byKey(const Key('site-message-2')), findsNothing);
    // The source "mine" filter opens authentication for guests rather than
    // changing the wall to an empty private feed.
    final mine = find.widgetWithText(ChoiceChip, '我的');
    await tester.ensureVisible(mine);
    await tester.tap(mine);
    await tester.pumpAndSettle();
    expect(find.byType(NativeAuthPage), findsOneWidget);
  });
}
