import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/management_service.dart';
import 'package:tsukuyomi_space_app/features/site/native_article_editor.dart';
import 'package:tsukuyomi_space_app/features/site/native_asset_service.dart';

import 'support/fakes.dart';

// Original Express/SQLite fixture only. Never target an arbitrary configured
// site: password changes and uploads belong to this disposable local database.
const _site = 'http://127.0.0.1:4184';
bool get _enabled =>
    Platform.environment['RUN_SITE_FIXTURE'] == '1' ||
    const bool.fromEnvironment('RUN_SITE_FIXTURE');
Matcher status(int code) =>
    isA<ApiFailure>().having((e) => e.status, 'HTTP status', code);
Map<String, dynamic> data(Map<String, dynamic> result) =>
    Map<String, dynamic>.from(result['data'] as Map);

Future<RoomController> signedRoom(String user, String password) async {
  final storage = MemoryStorage()
    ..value = const RoomSettings(siteUrl: _site, demo: true);
  final room = RoomController(
    storage: storage,
    site: SiteClient(),
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await room.initialize();
  await room.login(user, password);
  addTearDown(room.dispose);
  return room;
}

Uint8List tinyPng() {
  final bitmap = image.Image(width: 32, height: 18);
  image.fill(bitmap, color: image.ColorRgba8(150, 100, 225, 255));
  return Uint8List.fromList(image.encodePng(bitmap));
}

AssetUploadFile uploadFile(Uint8List bytes, String name) => AssetUploadFile(
  name: name,
  size: bytes.length,
  modified: 1234,
  readRange: (start, end) async => Uint8List.sublistView(bytes, start, end),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalOverrides = HttpOverrides.current;
  setUp(() => HttpOverrides.global = null);
  tearDown(() => HttpOverrides.global = originalOverrides);
  group('real original backend native full-site contracts', () {
    test('NativeAssetService uploads actual checksum chunks; NativeArticleEditor creates, updates and deletes a covered article', () async {
      final room = await signedRoom('e2e-user', 'e2e-password');
      final assets = NativeAssetService(room);
      final uploaded = await assets.upload(
        uploadFile(tinyPng(), 'native-fixture-cover.png'),
        sleep: (_) => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      final assetId = uploaded['id'];
      expect(assetId, isNotNull);
      expect(uploaded['mime_type'], 'image/png');
      String? articleId;
      try {
        final library = data(
          await assets.request(
            'GET',
            '/api/assets?collection=attachments&limit=120',
          ),
        );
        expect(
          (library['assets'] as List).any((a) => '${a['id']}' == '$assetId'),
          true,
        );
        final author = NativeArticleEditor(room, '/editor');
        addTearDown(author.dispose);
        await author.initialize();
        expect(author.error, isEmpty);
        expect(author.moderator, false);
        expect(author.allowedCategories.any((c) => c['name'] == '公告'), false);
        author.change(
          'title',
          '原生真实契约 ${DateTime.now().microsecondsSinceEpoch}',
        );
        author.change('content', '# 本地联调\n\n正文包含 **原生编辑** 与封面附件。');
        author.change('excerpt', '真实原站后端验证');
        author.change(
          'cover_image',
          uploaded['markdown_url'] ?? '/api/assets/proxy/$assetId',
        );
        author.change('cover_image_asset_id', assetId);
        final created = await author.submit();
        expect(created, isNotNull, reason: author.error);
        articleId = '${data(created!)['id']}';
        final read = data(
          await assets.request('GET', '/api/user/articles/$articleId'),
        );
        expect(read['content'], contains('**原生编辑**'));
        expect('${read['cover_image_asset_id']}', '$assetId');
        final editor = NativeArticleEditor(room, '/editor?id=$articleId');
        addTearDown(editor.dispose);
        await editor.initialize();
        expect(editor.error, isEmpty);
        editor.change('title', '已更新的原生文章');
        editor.change('content', '<h2>HTML 正文</h2><p>原生保存</p>');
        editor.change('content_format', 'html');
        expect(await editor.submit(), isNotNull, reason: editor.error);
        final edited = data(
          await assets.request('GET', '/api/user/articles/$articleId'),
        );
        expect(edited['title'], '已更新的原生文章');
        expect(edited['content_format'], 'html');
        expect(edited['content'], contains('<h2>HTML 正文</h2>'));
        await assets.request('DELETE', '/api/user/articles/$articleId');
        await expectLater(
          assets.request('GET', '/api/user/articles/$articleId'),
          throwsA(status(404)),
        );
        articleId = null;
      } finally {
        if (articleId != null) {
          await assets.request('DELETE', '/api/user/articles/$articleId');
        }
        await assets.request('DELETE', '/api/assets/$assetId');
      }
      expect(
        (data(
                  await assets.request(
                    'GET',
                    '/api/assets?collection=attachments&limit=120',
                  ),
                )['assets']
                as List)
            .any((a) => '${a['id']}' == '$assetId'),
        false,
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('ordinary accounts are denied management, site admin edits through moderation, terminal super_admin has its own role', () async {
      final user = await signedRoom('e2e-user', 'e2e-password');
      final api = user.site as SiteClient;
      await expectLater(
        api.request(_site, 'GET', '/api/moderation/summary'),
        throwsA(status(403)),
      );
      await expectLater(
        api.request(_site, 'GET', '/api/assets?scope=all'),
        throwsA(status(403)),
      );
      final moderator = await signedRoom(
        'notify-site-admin',
        'notify-staff-password',
      );
      final moderation = ManagementService(
        moderator.site as SiteDataService,
        _site,
        terminalSession: false,
      );
      final identity = await moderation.data('GET', '/me') as Map;
      expect(identity['role'], 'admin');
      expect(await moderation.data('GET', '/summary'), isA<Map>());
      final terminalStaff = SiteClient();
      addTearDown(terminalStaff.dispose);
      final staffLogin = data(
        await terminalStaff.request(_site, 'POST', '/api/admin/login', {
          'username': 'notify-staff',
          'password': 'notify-staff-password',
        }),
      );
      expect((staffLogin['admin'] as Map)['role'], 'admin');
      await expectLater(
        terminalStaff.request(
          _site,
          'PATCH',
          '/api/admin/users/e2e-user-001/role',
          {'role': 'user'},
        ),
        throwsA(status(403)),
      );
      final superClient = SiteClient();
      addTearDown(superClient.dispose);
      final rootLogin = data(
        await superClient.request(_site, 'POST', '/api/admin/login', {
          'username': 'admin',
          'password': 'admin-test-password',
        }),
      );
      expect((rootLogin['admin'] as Map)['role'], 'super_admin');
      final terminal = ManagementService(
        superClient,
        _site,
        terminalSession: true,
      );
      expect((await terminal.data('GET', '/me') as Map)['role'], 'super_admin');
      expect(await terminal.data('GET', '/users'), isA<List>());
      final author = NativeArticleEditor(user, '/editor');
      addTearDown(author.dispose);
      await author.initialize();
      author.change(
        'title',
        '管理员修改契约 ${DateTime.now().microsecondsSinceEpoch}',
      );
      author.change('content', '管理员将经由原生编辑器读取并保存此文章。');
      final created = await author.submit();
      expect(created, isNotNull, reason: author.error);
      final id = data(created!)['id'];
      try {
        final editor = NativeArticleEditor(moderator, '/editor?id=$id');
        addTearDown(editor.dispose);
        await editor.initialize();
        expect(editor.error, isEmpty);
        expect(editor.moderator, true);
        expect(editor.allowedCategories.any((c) => c['name'] == '公告'), true);
        editor.change('title', '原生审核已保存');
        editor.change('category', '公告');
        expect(await editor.submit(), isNotNull, reason: editor.error);
        expect(
          (await moderation.data('GET', '/articles/$id') as Map)['category'],
          '公告',
        );
        await moderation.request('DELETE', '/articles/$id');
        await expectLater(
          moderation.data('GET', '/articles/$id'),
          throwsA(status(404)),
        );
      } finally {
        // If an assertion failed earlier, release only this test's article.
        try {
          await api.request(_site, 'DELETE', '/api/user/articles/$id');
        } on ApiFailure catch (e) {
          if (e.status != 404) rethrow;
        }
      }
      await superClient.request(_site, 'POST', '/api/admin/logout');
      // Original site intentionally retains the paired ordinary site session.
      // ensureSiteUserForAdmin pairs a terminal administrator with a site
      // administrator. The terminal role remains super_admin independently.
      expect((await superClient.me(_site)).role, 'admin');
      await terminalStaff.request(_site, 'POST', '/api/admin/logout');
    });

    test('profile/avatar and password change validates current credentials and rolls back fixture password', () async {
      final room = await signedRoom('e2e-user', 'e2e-password');
      final api = room.site as SiteClient;
      final profile = data(
        await api.request(_site, 'GET', '/api/user/profile'),
      );
      final oldBio = profile['bio'];
      final avatar = 'data:image/png;base64,${base64Encode(tinyPng())}';
      await expectLater(
        api.request(_site, 'POST', '/api/user/avatar', {
          'avatar': 'javascript:alert(1)',
        }),
        throwsA(status(400)),
      );
      await api.request(_site, 'PUT', '/api/user/profile', {
        'bio': ' 原生个人简介回归 ',
      });
      expect(
        data(await api.request(_site, 'GET', '/api/user/profile'))['bio'],
        '原生个人简介回归',
      );
      await api.request(_site, 'POST', '/api/user/avatar', {'avatar': avatar});
      expect(
        data(await api.request(_site, 'GET', '/api/user/profile'))['avatar'],
        avatar,
      );
      await api.request(_site, 'PUT', '/api/user/profile', {
        'bio': oldBio ?? '',
      });
      if ('${profile['avatar'] ?? ''}'.isNotEmpty) {
        await api.request(_site, 'POST', '/api/user/avatar', {
          'avatar': profile['avatar'],
        });
      }
      await expectLater(
        api.request(_site, 'PUT', '/api/user/password', {
          'currentPassword': 'incorrect-fixture-password',
          'newPassword': 'native-temporary-password',
        }),
        throwsA(status(400)),
      );
      await expectLater(
        api.request(_site, 'PUT', '/api/user/password', {
          'currentPassword': 'e2e-password',
          'newPassword': 'short',
        }),
        throwsA(status(400)),
      );
      const nextPassword = 'native-temporary-password';
      bool changed = false;
      final fresh = SiteClient();
      addTearDown(fresh.dispose);
      try {
        await api.request(_site, 'PUT', '/api/user/password', {
          'currentPassword': 'e2e-password',
          'newPassword': nextPassword,
        });
        changed = true;
        await fresh.login(_site, 'e2e-user', nextPassword);
        expect((await fresh.me(_site)).username, 'e2e-user');
      } finally {
        if (changed) {
          // The old session can be invalidated by password revision; establish
          // the current session before restoring the shared fixture account.
          await fresh.login(_site, 'e2e-user', nextPassword);
          await fresh.request(_site, 'PUT', '/api/user/password', {
            'currentPassword': nextPassword,
            'newPassword': 'e2e-password',
          });
        }
      }
      await api.login(_site, 'e2e-user', 'e2e-password');
      expect((await api.me(_site)).username, 'e2e-user');
    });

    test('messages PATCH preserves ownership; bookmarks and likes use real separate POST/DELETE contracts', () async {
      final room = await signedRoom('e2e-user', 'e2e-password');
      final api = room.site as SiteClient;
      final other = SiteClient();
      addTearDown(other.dispose);
      await other.login(_site, 'notify-site-admin', 'notify-staff-password');
      final created = data(
        await api.request(_site, 'POST', '/api/messages', {
          'content': '原生 PATCH 契约 ${DateTime.now().microsecondsSinceEpoch}',
        }),
      );
      final id = created['id'];
      try {
        final edited = data(
          await api.request(_site, 'PATCH', '/api/messages/$id', {
            'content': '原生留言已编辑',
          }),
        );
        expect(edited['content'], '原生留言已编辑');
        await expectLater(
          other.request(_site, 'PATCH', '/api/messages/$id', {
            'content': '不可越权编辑',
          }),
          throwsA(status(404)),
        );
        await expectLater(
          api.request(_site, 'PUT', '/api/messages/$id', {'content': '错误方法'}),
          throwsA(isA<ApiFailure>()),
        );
      } finally {
        await api.request(_site, 'DELETE', '/api/messages/$id');
      }
      final articles = await api.request(_site, 'GET', '/api/articles?limit=1');
      final article = (articles['data'] as List).first['id'];
      final bookmarkPath = '/api/user/bookmarks/$article',
          likePath = '/api/user/article-likes/$article';
      final wasBookmarked =
          data(
            await api.request(_site, 'GET', '$bookmarkPath/status'),
          )['bookmarked'] ==
          true;
      final wasLiked =
          data(await api.request(_site, 'GET', '$likePath/status'))['liked'] ==
          true;
      try {
        await api.request(_site, 'POST', bookmarkPath);
        await api.request(_site, 'POST', bookmarkPath);
        expect(
          data(
            await api.request(_site, 'GET', '$bookmarkPath/status'),
          )['bookmarked'],
          true,
        );
        expect(
          (await api.request(_site, 'GET', '/api/user/bookmarks'))['data'],
          isA<List>(),
        );
        await api.request(_site, 'DELETE', bookmarkPath);
        expect(
          data(
            await api.request(_site, 'GET', '$bookmarkPath/status'),
          )['bookmarked'],
          false,
        );
        await api.request(_site, 'POST', likePath);
        expect(
          data(await api.request(_site, 'GET', '$likePath/status'))['liked'],
          true,
        );
        await api.request(_site, 'DELETE', likePath);
        expect(
          data(await api.request(_site, 'GET', '$likePath/status'))['liked'],
          false,
        );
      } finally {
        await api.request(
          _site,
          wasBookmarked ? 'POST' : 'DELETE',
          bookmarkPath,
        );
        await api.request(_site, wasLiked ? 'POST' : 'DELETE', likePath);
      }
    });
  }, skip: !_enabled);
}
