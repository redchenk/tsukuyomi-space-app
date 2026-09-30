import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/access_page.dart';
import 'package:tsukuyomi_space_app/features/site/friend_link_application.dart';
import 'package:tsukuyomi_space_app/features/site/friend_links_page.dart';
import 'package:tsukuyomi_space_app/features/site/native_site_shell.dart';
import 'package:tsukuyomi_space_app/features/site/reality_page.dart';
import 'package:tsukuyomi_space_app/features/site/site_widgets.dart';
import 'package:tsukuyomi_space_app/features/site/user_profile_page.dart';
import 'package:tsukuyomi_space_app/features/site/wiki_page.dart';

import 'support/fakes.dart';

typedef ArchiveRequest = Future<Map<String, dynamic>> Function(
  String method,
  String path,
  Map<String, dynamic>? body,
);

class ArchiveSite extends FakeSite implements SiteDataService {
  ArchiveSite(this.handle);
  final ArchiveRequest handle;
  final calls = <String>[];
  final bodies = <Map<String, dynamic>?>[];
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) {
    calls.add('$method $path');
    bodies.add(body);
    return handle(method, path, body);
  }
}

Future<RoomController> archiveController(
  ArchiveSite site, {
  MemoryStorage? storage,
  String? account,
}) async {
  final c = RoomController(
    storage: storage ?? MemoryStorage(),
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await c.initialize();
  if (account != null) await c.login(account, 'password');
  return c;
}

Future<void> mountArchive(
  WidgetTester tester,
  Widget child, {
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

Map<String, dynamic> publicProfile({String name = 'Bob'}) => {
  'success': true,
  'data': {
    'user': {
      'id': name.toLowerCase(),
      'username': name,
      'bio': '月下创作记录',
      'role': 'user',
      'created_at': '2026-01-01',
    },
    'viewer': {'isSelf': false, 'isFollowing': false},
    'stats': {'articles': 1, 'totalViews': 23, 'followers': 7, 'following': 2},
    'articles': [
      {
        'id': 42,
        'slug': 'moon-story',
        'title': '月光故事',
        'excerpt': '记录一段月下的旅程',
        'category': '故事',
        'view_count': 23,
      },
    ],
  },
};

void main() {
  test(
    'complete original Wiki archive includes every entry and local image',
    () {
      final wiki = SiteArchive.wiki;
      expect(SiteArchive.entries.length, 19);
      expect(
        SiteArchive.entries.where((e) => e['kind'] == 'character').length,
        12,
      );
      expect(SiteArchive.entries.where((e) => e['kind'] == 'term').length, 7);
      expect(rowsOf(wiki['music']).length, 16);
      expect(wiki['staff'], hasLength(18));
      expect(wiki['cast'], hasLength(16));
      expect(rowsOf(wiki['references']).length, 9);
      expect(rowsOf(wiki['tocEntries']).length, 8);
      expect(SiteArchive.entries.where((e) => e['source'] != null).length, 8);
      for (final entry in SiteArchive.entries) {
        expect(
          entry['sections'] as List,
          isNotEmpty,
          reason: '${entry['slug']}',
        );
        expect(rowsOf(entry['sourceLinks']), isNotEmpty);
        if (entry['source'] != null) {
          final source = mapOf(entry['source']);
          expect(rowsOf(source['sections']).length, 5);
          for (final section in rowsOf(source['sections'])) {
            expect(textOf(section, 'html'), isNotEmpty);
          }
        }
      }
      final paths = RegExp(
        r'/assets/images/wiki/[a-zA-Z0-9_./-]+\.(?:webp|png|jpg|gif)',
      ).allMatches(jsonEncode(wiki)).map((m) => m[0]!).toSet();
      expect(paths.length, greaterThan(80));
      for (final path in paths) {
        expect(
          File(SiteArchive.imageAsset(path)!).existsSync(),
          isTrue,
          reason: path,
        );
      }
      expect(
        SiteArchive.imageAsset('/assets/images/wiki/../secret.png'),
        isNull,
      );
      expect(SiteArchive.imageAsset('https://example.com/photo.png'), isNull);
      expect(rowsOf(SiteArchive.reality['privacyRows']).length, 5);
      expect(rowsOf(SiteArchive.reality['rightsCards']).length, 3);
      expect(SiteArchive.reality['attributions'], hasLength(7));
    },
  );

  test('friend application enforces the actual backend field contracts', () {
    expect(FriendLinkApplication.validate('name', '月'), isNotNull);
    expect(FriendLinkApplication.validate('description', '简介'), isNotNull);
    expect(
      FriendLinkApplication.validate('url', 'javascript:alert(1)'),
      isNotNull,
    );
    expect(
      FriendLinkApplication.validate('url', 'https://user:pass@example.com'),
      isNotNull,
    );
    expect(
      FriendLinkApplication.validate('avatar_url', 'http://example.com/a.png'),
      isNotNull,
    );
    expect(FriendLinkApplication.validate('name', '<script>'), isNotNull);
    expect(FriendLinkApplication.validate('backlink_url', ''), isNull);
    expect(FriendLinkApplication.validate('avatar_url', ''), isNull);
    expect(
      FriendLinkApplication.body({
        'name': '  月下\n 故事  ',
        'url': ' https://example.com/ ',
        'description': ' 一段\n月下的故事 ',
      }),
      {
        'name': '月下 故事',
        'description': '一段 月下的故事',
        'url': 'https://example.com/',
        'avatar_url': '',
        'backlink_url': '',
        'note': '',
      },
    );
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets('Wiki total directory has complete native sections at $width', (
      tester,
    ) async {
      final site = ArchiveSite(
        (_, _, _) async => {'success': true, 'data': {}},
      );
      final c = await archiveController(site);
      addTearDown(c.dispose);
      final destinations = <String>[];
      await mountArchive(
        tester,
        WikiPage(controller: c, onGo: destinations.add),
        width: width,
      );
      expect(find.text('词条目录'), findsOneWidget);
      expect(find.text('展开完整剧情与结局剧透'), findsOneWidget);
      expect(site.calls, isEmpty);
      await tester.ensureVisible(find.byKey(const Key('wiki-search')));
      await tester.enterText(
        find.byKey(const Key('wiki-search')),
        'Black onyX',
      );
      await tester.pumpAndSettle();
      final result = find.widgetWithText(ListTile, 'Black onyX').first;
      await tester.ensureVisible(result);
      await tester.tap(result);
      expect(destinations.last, '/wiki/terms/black-onyx');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Wiki character detail renders full source and image variants', (
    tester,
  ) async {
    final site = ArchiveSite((_, _, _) async => {'success': true, 'data': {}});
    final c = await archiveController(site);
    addTearDown(c.dispose);
    await mountArchive(
      tester,
      WikiPage(controller: c, path: '/wiki/characters/kaguya', onGo: (_) {}),
    );
    expect(find.text('辉夜'), findsWidgets);
    expect(find.byType(ChoiceChip), findsWidgets);
    expect(find.byType(ExpansionTile), findsWidgets);
    expect(site.calls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'friend directory reads monitor contracts and links to the actual destination',
    (tester) async {
      final site = ArchiveSite(
        (_, _, _) async => {
          'success': true,
          'data': [
            {
              'name': '月下站点',
              'url': 'https://example.com/',
              'description': '创作与分享的站点',
              'monitor_status': 'online',
              'response_time_ms': 123,
              'has_backlink': true,
              'last_checked_at': '2026-09-30',
            },
          ],
        },
      );
      final c = await archiveController(site);
      addTearDown(c.dispose);
      final destinations = <String>[];
      await mountArchive(
        tester,
        FriendLinksPage(controller: c, onGo: destinations.add),
        width: 320,
      );
      expect(site.calls, ['GET /api/friend-links']);
      expect(find.text('在线 · 123ms'), findsOneWidget);
      await tester.ensureVisible(find.text('example.com'));
      await tester.tap(find.text('example.com'));
      expect(destinations.last, 'https://example.com/');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'application keeps draft after failed submit and sends exactly one write',
    (tester) async {
      final site = ArchiveSite((method, path, body) async {
        if (method == 'POST') throw const ApiFailure('服务器拒绝重复申请', status: 409);
        return {
          'success': true,
          'data': [
            {
              'name': '过去的申请',
              'url': 'https://old.example/',
              'status': 'pending',
            },
          ],
        };
      });
      final storage = MemoryStorage();
      final c = await archiveController(
        site,
        storage: storage,
        account: 'Alice',
      );
      addTearDown(c.dispose);
      await mountArchive(
        tester,
        FriendLinksPage(
          controller: c,
          path: '/friend-links/apply',
          onGo: (_) {},
        ),
      );
      for (final entry in {
        'name': '月下站点',
        'url': 'https://example.com/',
        'description': '创作与分享的站点',
      }.entries) {
        final finder = find.byKey(Key('friend-${entry.key}'));
        await tester.ensureVisible(finder);
        await tester.enterText(finder, entry.value);
      }
      await tester.ensureVisible(find.byKey(const Key('friend-submit')));
      await tester.tap(find.byKey(const Key('friend-submit')));
      await tester.pumpAndSettle();
      expect(
        site.calls.where((call) => call == 'POST /api/friend-links').length,
        1,
      );
      expect(find.textContaining('服务器拒绝重复申请'), findsOneWidget);
      expect(find.text('月下站点'), findsOneWidget);
      expect(
        storage.drafts.entries
            .where((e) => e.key.startsWith('friend-link-application:'))
            .single
            .value,
        contains('https://example.com/'),
      );
      expect(find.text('审核中'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'public profile follows and unfollows using actual API and opens article slug',
    (tester) async {
      final site = ArchiveSite((method, path, body) async {
        if (path.startsWith('/api/growth/public')) {
          return {'success': true, 'data': []};
        }
        if (path.startsWith('/api/user/follow/')) {
          return {
            'success': true,
            'data': {
              'isFollowing': method == 'POST',
              'followers': method == 'POST' ? 8 : 7,
              'following': 2,
            },
          };
        }
        return publicProfile();
      });
      final c = await archiveController(site, account: 'Alice');
      addTearDown(c.dispose);
      final destinations = <String>[];
      await mountArchive(
        tester,
        UserProfilePage(
          controller: c,
          path: '/users/Bob',
          onGo: destinations.add,
        ),
      );
      await tester.ensureVisible(find.byKey(const Key('profile-follow')));
      await tester.tap(find.byKey(const Key('profile-follow')));
      await tester.pumpAndSettle();
      expect(find.text('取消关注'), findsOneWidget);
      await tester.tap(find.byKey(const Key('profile-follow')));
      await tester.pumpAndSettle();
      expect(find.text('关注作者'), findsOneWidget);
      expect(
        site.calls,
        containsAll([
          'GET /api/user/public/Bob',
          'POST /api/user/follow/bob',
          'DELETE /api/user/follow/bob',
        ]),
      );
      await tester.ensureVisible(find.text('月光故事').first);
      await tester.tap(find.text('月光故事').first);
      expect(destinations.last, '/articles/42/moon-story');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'late profile response cannot appear after navigation to another user',
    (tester) async {
      final late = Completer<Map<String, dynamic>>();
      final site = ArchiveSite((_, path, _) async {
        if (path == '/api/user/public/Bob') return late.future;
        if (path.startsWith('/api/growth/')) {
          return {'success': true, 'data': []};
        }
        return publicProfile(name: 'Carol');
      });
      final c = await archiveController(site);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: UserProfilePage(
            controller: c,
            path: '/users/Bob',
            onGo: (_) {},
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: UserProfilePage(
            controller: c,
            path: '/users/Carol',
            onGo: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      late.complete(publicProfile());
      await tester.pumpAndSettle();
      expect(find.text('Carol'), findsOneWidget);
      expect(find.text('Bob'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Reality carries full privacy, rights and original attributions at mobile width',
    (tester) async {
      final site = ArchiveSite(
        (_, _, _) async => {'success': true, 'data': {}},
      );
      final c = await archiveController(site);
      addTearDown(c.dispose);
      await mountArchive(
        tester,
        RealityPage(controller: c, onGo: (_) {}),
        width: 320,
      );
      expect(find.byType(SelectableText), findsWidgets);
      expect(find.textContaining('Mem0', findRichText: true), findsWidgets);
      expect(site.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Access still enters Hub once when settings service is unavailable',
    (tester) async {
      final site = ArchiveSite(
        (_, _, _) async => throw const ApiFailure('没有公告', status: 404),
      );
      final c = await archiveController(site);
      addTearDown(c.dispose);
      final destinations = <String>[];
      await mountArchive(
        tester,
        AccessPage(controller: c, playVideo: false, onGo: destinations.add),
        width: 320,
      );
      await tester.ensureVisible(find.byKey(const Key('access-enter')));
      await tester.tap(find.byKey(const Key('access-enter')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      expect(destinations, ['/hub']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
