import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/site_page.dart';
import 'package:tsukuyomi_space_app/features/site/site_widgets.dart';

import 'support/fakes.dart';

void main() {
  test('flat website replies remain under their root', () {
    final threads = messageThreads([
      {'id': 1, 'parent_id': null},
      {'id': 2, 'parent_id': 1},
      {'id': 3, 'parent_id': 1},
      {'id': 4, 'parent_id': 2},
      {'id': 5, 'parent_id': 99},
      {'id': 6, 'parent_id': 7},
      {'id': 7, 'parent_id': 6},
    ]);
    expect(threads.length, 1);
    expect((threads.single['replies'] as List).length, 3);
  });
  for (final width in [320.0, 390.0, 1280.0]) {
    for (final page in [
      '/stage',
      '/plaza',
      '/growth',
      '/user',
      '/conversations',
      '/articles/1',
    ]) {
      testWidgets('$page fits width $width with website contract', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final site = SiteClient(
          client: MockClient((req) async {
            dynamic data = [];
            if (req.url.path.endsWith('/api/auth/login')) {
              data = {
                'user': {'id': 'alice', 'username': 'alice'},
              };
            } else if (req.url.path.endsWith('/api/auth/me')) {
              data = {'id': 'alice', 'username': 'alice'};
            } else if (req.url.path.endsWith('/articles')) {
              data = [
                {
                  'id': 1,
                  'title': '来自网站的文章',
                  'author_username': 'alice',
                  'excerpt': '同一份数据',
                  'view_count': 42,
                  'content_format': 'markdown',
                },
              ];
            } else if (req.url.path.endsWith('/articles/1')) {
              data = {
                'id': 1,
                'title': '来自网站的文章',
                'content': '## 内容\n\n正文。',
                'content_format': 'markdown',
              };
            } else if (req.url.path.endsWith('/messages')) {
              data = List.generate(
                18,
                (i) => {
                  'id': i + 1,
                  'author': 'alice',
                  'content': '问候与灵感 $i',
                  'created_at':
                      '2026-09-${(27 - i).toString().padLeft(2, '0')}',
                  'like_count': 3,
                  'parent_id': null,
                },
              );
            } else if (req.url.path.endsWith('/api/user/profile')) {
              data = {'id': 'alice', 'username': 'alice', 'bio': '介绍'};
            } else if (req.url.path.endsWith('/api/growth/me')) {
              data = {
                'level': {
                  'level': 2,
                  'title': '微光相识',
                  'totalXp': 100,
                  'progressPercent': 33,
                },
                'today': {'tasks': []},
              };
            }
            return http.Response(
              jsonEncode({
                'success': true,
                'data': data,
                'pagination': {'total': 1, 'totalPages': 1},
              }),
              200,
              headers: {
                'set-cookie': 'tsukuyomi_session=test; HttpOnly',
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }),
        );
        final c = RoomController(
          storage: MemoryStorage(),
          site: site,
          chat: FakeChat(),
          voice: SilentVoice(),
        );
        await c.initialize();
        await c.login('alice', 'test');
        addTearDown(c.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: SitePage(controller: c, path: page),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (page == '/stage') {
          expect(
            find.text('来自网站的文章'),
            findsOneWidget,
            reason: tester
                .widgetList<Text>(find.byType(Text))
                .map((t) => t.data)
                .join('|'),
          );
        }
        if (page == '/plaza') {
          expect(find.text('问候与灵感 0'), findsOneWidget);
          expect(find.text('问候与灵感 8'), findsNothing);
          await tester.ensureVisible(find.text('下一页'));
          await tester.tap(find.text('下一页'));
          await tester.pumpAndSettle();
          expect(find.text('问候与灵感 8'), findsOneWidget);
          expect(find.text('问候与灵感 0'), findsNothing);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
