import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/user_center_page.dart';
import 'package:tsukuyomi_space_app/features/site/native_gallery_details.dart';

import 'support/fakes.dart';

Map<String, dynamic> accountProfile(String owner) => {
  'success': true,
  'data': {
    'id': owner,
    'username': owner,
    'email': '$owner@example.com',
    'bio': '$owner 的私有介绍',
    'created_at': '2026-09-30',
  },
};

class AccountProfileSite extends FakeSite implements SiteDataService {
  final profiles = <String>[];
  final requests = <String>[];
  final writes = <Map<String, dynamic>>[];
  final articles = <Map<String, dynamic>>[];
  final articleRequests = <String>[];
  Completer<Map<String, dynamic>>? pendingArticles;
  bool failArticles = false;

  Completer<Map<String, dynamic>>? pendingAlice;
  Map<String, dynamic> growth = {};
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    requests.add('$method $path');
    if (path.startsWith('/api/user/articles')) {
      articleRequests.add(userId);
      if (pendingArticles != null && userId == 'alice') {
        return pendingArticles!.future;
      }
      if (failArticles) throw const ApiFailure('文章暂时不可用');
      return {
        'success': true,
        'data': [
          for (final article in articles) {...article},
        ],
      };
    }
    if (path == '/api/user/profile') {
      if (method == 'PUT') writes.add({...?body});
      final owner = userId;
      profiles.add(owner);
      if (owner == 'alice' && pendingAlice != null) return pendingAlice!.future;
      return accountProfile(owner);
    }
    if (path == '/api/growth/me') return {'success': true, 'data': growth};
    return {'success': true, 'data': {}};
  }
}

Future<RoomController> mountAccount(
  WidgetTester tester,
  AccountProfileSite site, {
  double width = 1280,
}) async {
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final room = RoomController(
    storage: MemoryStorage(),
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  addTearDown(room.dispose);
  await room.initialize();
  await room.login('alice', 'test-password');
  await tester.pumpWidget(
    MaterialApp(
      home: UserCenterPage(controller: room, onGo: (_) {}),
    ),
  );
  await tester.pumpAndSettle();
  return room;
}

Future<void> selectAccountTab(WidgetTester tester, String tab) async {
  final finder = find.byKey(ValueKey('account-tab-$tab'));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  for (final level in [
    {
      'level': {
        'level': 8,
        'title': '永恒月契',
        'totalXp': 7654,
        'progressPercent': 42,
      },
    },
    {
      'summary': {'level': 8},
    },
  ]) {
    testWidgets(
      'Account growth parses ${level.keys.first} and routes through the badge without printing objects',
      (tester) async {
        final site = AccountProfileSite()..growth = level;
        final room = RoomController(
          storage: MemoryStorage(),
          site: site,
          chat: FakeChat(),
          voice: SilentVoice(),
        );
        addTearDown(room.dispose);
        await room.initialize();
        await room.login('alice', 'test-password');
        final destinations = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: UserCenterPage(controller: room, onGo: destinations.add),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Lv.8'), findsNWidgets(2));
        expect(find.text('永恒月契'), findsNWidgets(2));
        expect(
          tester
              .widget<NativeUserLevelBadge>(
                find.byType(NativeUserLevelBadge).first,
              )
              .level,
          8,
        );
        expect(
          tester
              .widgetList<Text>(find.byType(Text))
              .any((text) => '${text.data}'.contains('totalXp')),
          isFalse,
        );
        await tester.ensureVisible(
          find.byKey(const Key('account-growth-link')),
        );
        await tester.tap(find.byKey(const Key('account-growth-link')));
        expect(destinations, ['/growth']);
        expect(find.text('新建投稿'), findsOneWidget);
        expect(find.text('图库管理'), findsOneWidget);
        expect(find.text('附件库'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'default demo mode isolates account center and ignores a late previous profile',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final site = AccountProfileSite();
      final room = RoomController(
        storage: MemoryStorage(),
        site: site,
        chat: FakeChat(),
        voice: SilentVoice(),
      );
      addTearDown(room.dispose);
      await room.initialize();
      await room.login('alice', 'test-password');
      expect(room.settings.demo, isTrue);
      expect(room.scope, 'demo');
      await tester.pumpWidget(
        MaterialApp(
          home: UserCenterPage(controller: room, onGo: (_) {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('alice 的私有介绍'), findsWidgets);
      final delayed = Completer<Map<String, dynamic>>();
      site.pendingAlice = delayed;
      final pendingRefresh = tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pump();
      expect(site.profiles, ['alice', 'alice']);
      await room.login('bob', 'test-password');
      await tester.pumpAndSettle();
      expect(
        room.scope,
        'demo',
        reason:
            'Room demonstration scope remains independent of the site account',
      );
      expect(find.text('alice 的私有介绍'), findsNothing);
      expect(find.text('bob 的私有介绍'), findsWidgets);
      expect(site.profiles, ['alice', 'alice', 'bob']);
      delayed.complete(accountProfile('alice'));
      await pendingRefresh;
      await tester.pumpAndSettle();
      expect(find.text('alice 的私有介绍'), findsNothing);
      expect(find.text('bob 的私有介绍'), findsWidgets);
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .where((field) => field.controller?.text == 'bob 的私有介绍'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'account workspace preserves edits across tabs and blocks refresh until reset',
    (tester) async {
      final site = AccountProfileSite();
      await mountAccount(tester, site);
      await tester.enterText(
        find.byKey(const Key('account-nickname')),
        '尚未保存的新昵称',
      );
      await tester.enterText(find.byKey(const Key('account-bio')), '尚未保存的简介');
      await tester.pump();
      expect(find.text('有尚未保存的修改'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('account-refresh')))
            .onPressed,
        isNull,
      );
      final previousRequests = site.profiles.length;
      await tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      expect(site.profiles, hasLength(previousRequests));
      await selectAccountTab(tester, 'articles');
      await selectAccountTab(tester, 'profile');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('account-nickname')))
            .controller!
            .text,
        '尚未保存的新昵称',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('account-bio')))
            .controller!
            .text,
        '尚未保存的简介',
      );
      await tester.ensureVisible(
        find.byKey(const Key('account-reset-profile')),
      );
      await tester.tap(find.byKey(const Key('account-reset-profile')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('account-nickname')))
            .controller!
            .text,
        'alice',
      );
      expect(find.text('资料已保存'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('account-save-profile')))
            .onPressed,
        isNull,
      );
      expect(site.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'articles refresh on entry, retain results on failure, and ignore previous account response',
    (tester) async {
      final site = AccountProfileSite()
        ..articles.add({'id': 42, 'title': '已有稿件', 'view_count': 7});
      final room = await mountAccount(tester, site);
      expect(site.articleRequests, ['alice']);
      await selectAccountTab(tester, 'articles');
      expect(site.articleRequests, ['alice', 'alice']);
      expect(find.text('已有稿件'), findsOneWidget);
      site.failArticles = true;
      await tester.ensureVisible(
        find.byKey(const Key('account-content-refresh')),
      );
      await tester.tap(find.byKey(const Key('account-content-refresh')));
      await tester.pumpAndSettle();
      expect(find.text('已有稿件'), findsOneWidget);
      expect(find.textContaining('文章暂时不可用'), findsWidgets);
      site.failArticles = false;
      final pending = Completer<Map<String, dynamic>>();
      site.pendingArticles = pending;
      await tester.tap(find.byKey(const Key('account-content-refresh')));
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('account-content-refresh')),
            )
            .onPressed,
        isNull,
      );
      site.articles
        ..clear()
        ..add({'id': 43, 'title': '新账号稿件'});
      await room.login('bob', 'test-password');
      await tester.pumpAndSettle();
      expect(find.text('已有稿件'), findsNothing);
      expect(find.text('新账号稿件'), findsOneWidget);
      pending.complete({
        'success': true,
        'data': [
          {'id': 99, 'title': '过期账号稿件'},
        ],
      });
      await tester.pumpAndSettle();
      expect(find.text('过期账号稿件'), findsNothing);
      expect(find.text('新账号稿件'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('articles refresh after returning from the native editor route', (
    tester,
  ) async {
    final site = AccountProfileSite()
      ..articles.add({'id': 42, 'title': '编辑前标题'});
    await mountAccount(tester, site);
    await selectAccountTab(tester, 'articles');
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('原生编辑器')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    site.articles[0]['title'] = '编辑后标题';
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('编辑后标题'), findsOneWidget);
    expect(find.text('编辑前标题'), findsNothing);
    expect(site.articleRequests, ['alice', 'alice', 'alice']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'desktop navigation searches sections and account information stays read only',
    (tester) async {
      await mountAccount(tester, AccountProfileSite());
      expect(find.text('我的账号'), findsOneWidget);
      expect(find.text('创作与互动'), findsOneWidget);
      expect(find.text('我的素材'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('account-navigation-search')),
        'email',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('account-tab-security')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('account-tab-articles')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('account-navigation-search')),
        '不匹配的关键词',
      );
      await tester.pump();
      expect(find.text('没有找到相关功能'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('account-information')));
      await tester.tap(find.byKey(const Key('account-information')));
      await tester.pumpAndSettle();
      expect(find.text('alice@example.com'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('内容管理'), findsNothing);
      expect(find.text('管理终端'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'mobile navigation exposes a section selector and material popup',
    (tester) async {
      await mountAccount(tester, AccountProfileSite(), width: 390);
      expect(find.byKey(const Key('account-navigation-search')), findsNothing);
      expect(find.byKey(const Key('account-mobile-section')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('account-mobile-materials')),
      );
      await tester.tap(find.byKey(const Key('account-mobile-materials')));
      await tester.pumpAndSettle();
      expect(find.text('图库管理'), findsOneWidget);
      expect(find.text('附件库'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'article confirmation cannot delete content after switching accounts',
    (tester) async {
      final site = AccountProfileSite()
        ..articles.add({'id': 42, 'title': '原账号稿件'});
      final room = await mountAccount(tester, site);
      await selectAccountTab(tester, 'articles');
      await tester.ensureVisible(find.text('删除'));
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await room.login('bob', 'test-password');
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(
        site.requests.where((request) => request.startsWith('DELETE ')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
