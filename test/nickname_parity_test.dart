import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/native_gallery_details.dart';
import 'package:tsukuyomi_space_app/features/site/user_center_page.dart';

import 'support/fakes.dart';

class NicknameSite extends FakeSite implements SiteDataService {
  String nickname = '原昵称';
  final writes = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path == '/api/user/profile') {
      if (method == 'PUT') {
        writes.add(Map.of(body!));
        nickname = body['nickname'] as String;
      }
      return {
        'success': true,
        'data': {
          'id': userId,
          'username': userId,
          'nickname': nickname,
          'bio': '介绍',
        },
      };
    }
    return {'success': true, 'data': {}};
  }
}

void main() {
  test('display names prefer nicknames without changing account identity or public avatar paths', () {
    const user = Account('fixed-id', 'fixed-login', nickname: '显示名称');
    expect(user.displayName, '显示名称');
    expect(user.username, 'fixed-login');
    expect(const Account('id', 'legacy').displayName, 'legacy');
    final asset = {
      'owner_username': 'fixed-login',
      'owner_nickname': '🌙 显示名',
      'owner_has_avatar': true,
    };
    expect(galleryUploaderName(asset), '🌙 显示名');
    expect(
      galleryUploaderAvatar(asset, 'https://site.example'),
      'https://site.example/api/user/public/fixed-login/avatar',
    );
    expect(
      userDisplayName({
        'author': 'login',
        'author_nickname': '作家',
      }, prefix: 'author'),
      '作家',
    );
    expect(userDisplayName({'author': 'legacy'}, prefix: 'author'), 'legacy');
  });
  test('nickname validation counts Unicode code points and rejects controls and invalid surrogates', () {
    expect(nicknameError('🌙' * 32), isNull);
    expect(nicknameError('🌙' * 33), isNotNull);
    expect(nicknameError(' \n '), isNotNull);
    expect(nicknameError('a\u202eb'), isNotNull);
    expect(nicknameError(String.fromCharCode(0xd800)), isNotNull);
  });
  testWidgets(
    'profile saves nickname only and preserves immutable identity, role, scope and public link',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final site = NicknameSite();
      final room = RoomController(
        storage: MemoryStorage(),
        chat: FakeChat(),
        site: site,
        voice: SilentVoice(),
      );
      await room.initialize();
      await room.login('alice', 'fixture-password');
      final scope = room.scope, cookie = room.site.cookie, targets = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: UserCenterPage(controller: room, onGo: targets.add),
        ),
      );
      await tester.pumpAndSettle();
      expect(room.account!.displayName, '原昵称');
      await tester.enterText(
        find.byKey(const Key('account-nickname')),
        '🌙 新昵称',
      );
      await tester.ensureVisible(find.text('保存资料'));
      await tester.tap(find.text('保存资料'));
      await tester.pumpAndSettle();
      expect(site.writes.single, {'nickname': '🌙 新昵称', 'bio': '介绍'});
      expect(room.account!.displayName, '🌙 新昵称');
      expect(room.account!.id, 'alice');
      expect(room.account!.username, 'alice');
      expect(room.account!.role, 'user');
      expect(room.scope, scope);
      expect(room.site.cookie, cookie);
      await tester.ensureVisible(find.text('查看公开主页'));
      await tester.tap(find.text('查看公开主页'));
      expect(targets, ['/users/alice']);
      await tester.enterText(
        find.byKey(const Key('account-nickname')),
        'bad\u202e',
      );
      await tester.ensureVisible(find.text('保存资料'));
      await tester.tap(find.text('保存资料'));
      await tester.pumpAndSettle();
      expect(site.writes, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      room.dispose();
    },
  );
}
