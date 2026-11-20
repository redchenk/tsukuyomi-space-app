import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/site/fushi_connect_page.dart';
import 'package:tsukuyomi_space_app/features/site/community_admin_page.dart';
import 'package:tsukuyomi_space_app/core/site_routes.dart';
import 'package:tsukuyomi_space_app/features/chatroom/chatroom_session.dart';
import 'package:tsukuyomi_space_app/features/chatroom/chatroom_page.dart';
import 'package:tsukuyomi_space_app/features/site/download_page.dart';
import 'package:tsukuyomi_space_app/features/site/play_apply_page.dart';
import 'package:tsukuyomi_space_app/features/site/site_page.dart';

import 'hub_page_test.dart' show HubSite, controller;

void main() {
  test('website utility and privileged routes resolve natively with strict Fushi callbacks', () {
    for (final route in [
      '/admin/account-deletions',
      '/admin/play-testing',
      '/download',
      '/apply',
      '/chatroom?channel=games',
      '/fushi/connect',
      '/fushi/astrbot/callback',
    ]) {
      expect(nativeSitePath(Uri.parse(route)), route);
    }
    final site = Uri.parse('https://example.test'), token = 'a' * 43;
    final callback = Uri(
      path: '/fushi/astrbot/callback',
      queryParameters: {'code': token, 'state': token, 'iss': site.origin},
    );
    expect(fushiConfirmation(callback, site), startsWith('/Fushi确认 '));
    for (final bad in [
      Uri.parse('$callback&code=$token'),
      Uri.parse('$callback&error=access_denied'),
      callback.replace(
        queryParameters: {
          ...callback.queryParameters,
          'iss': 'https://other.test',
        },
      ),
    ]) {
      expect(fushiConfirmation(bad, site), isNull);
    }
  });
  testWidgets(
    'signed-out admin screens never request or display applications',
    (tester) async {
      final site = HubSite((m, p, b) async => {'data': {}}),
          room = await controller(site);
      addTearDown(room.dispose);
      for (final path in ['/admin/play-testing', '/admin/account-deletions']) {
        await tester.pumpWidget(
          MaterialApp(
            home: CommunityAdminPage(room: room, path: path, onGo: (_) {}),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('请先在数据终端登录'), findsOneWidget);
      }
      expect(site.calls.where((s) => s.contains('/api/admin/')), isEmpty);
    },
  );
  testWidgets(
    'invitation preview and explicit confirmation use the same reviewed attempt',
    (tester) async {
      const email = 'fixture@example.test',
          action = 'https://example.test/join';
      final sends = <Map<String, dynamic>>[];
      final site = HubSite((method, path, body) async {
        final uri = Uri.parse(path);
        final data = switch (uri.path.split('/').last) {
          'play-testing' => {
            'items': [
              {'id': 7, 'email': email, 'status': 'pending'},
            ],
          },
          'invitation-settings' => {'actionUrl': action},
          'invitation-preview' => {
            'applicationId': 7,
            'email': email,
            'text': '示例邀请正文',
            'actionUrl': action,
            'configured': true,
            'version': 'v1',
            'attemptId': 'fixture-1',
          },
          'invite' => {
            'delivery': {'result': '仅本地模拟'},
          },
          _ => <String, dynamic>{},
        };
        if (method == 'POST') sends.add(Map.of(body!));
        return {'data': data};
      });
      final room = await controller(site);
      addTearDown(room.dispose);
      site.cookie = 'tsukuyomi_admin_session=fixture';
      await tester.pumpWidget(
        MaterialApp(
          home: CommunityAdminPage(
            room: room,
            path: '/admin/play-testing',
            onGo: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> click(Finder target) async {
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      await click(find.text('查看邀请邮件'));
      expect(find.text('示例邀请正文'), findsOneWidget);
      final send = find.widgetWithText(OutlinedButton, '确认发送邀请邮件');
      expect(tester.widget<OutlinedButton>(send).onPressed, isNull);
      expect(sends, isEmpty);
      await click(find.textContaining('我已将此邮箱加入'));
      await click(send);
      expect(sends.single, containsPair('attemptId', 'fixture-1'));
      expect(sends.single, containsPair('confirmTesterAdded', true));
      expect(find.text('仅本地模拟'), findsOneWidget);
    },
  );
  test(
    'changing channels ignores late snapshots and restores channel drafts',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      final room = await controller(
        HubSite((m, p, b) async {
          if (p.contains('/lobby/sync')) return pending.future;
          return {
            'data': {
              'cursor': '2',
              'packets': [
                {
                  'type': 'snapshot',
                  'messages': [
                    {'id': 2, 'content': 'new'},
                  ],
                },
              ],
            },
          };
        }),
      );
      addTearDown(room.dispose);
      final session = ChatroomSession(room, 'invalid');
      addTearDown(session.dispose);
      session.activate(true);
      session.draft.text = 'lobby draft';
      session.select('games');
      await Future<void>.delayed(Duration.zero);
      pending.complete({
        'data': {
          'cursor': '1',
          'packets': [
            {
              'type': 'snapshot',
              'messages': [
                {'id': 1},
              ],
            },
          ],
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(session.messages.keys, [2]);
      expect(session.draft.text, isEmpty);
      session.select('lobby');
      expect(session.draft.text, 'lobby draft');
    },
  );
  test(
    'retries reuse one request ID and sign-in partitions channel drafts',
    () async {
      final ids = <String>[];
      final room = await controller(
        HubSite((m, p, b) async {
          if (m == 'POST') {
            ids.add(b!['requestId'] as String);
            if (ids.length == 1) throw const ApiFailure('timeout');
            return {
              'data': {
                'message': {'id': 7},
                'growth': {
                  'award': {'awarded': true},
                },
              },
            };
          }
          return {'data': {}};
        }),
      );
      addTearDown(room.dispose);
      final session = ChatroomSession(room, null);
      addTearDown(session.dispose);
      session.draft.text = 'guest';
      await session.send();
      expect(ids, isEmpty);
      await room.login('alice', 'test');
      expect(session.draft.text, isEmpty);
      session.draft.text = 'hello';
      await session.send();
      expect(session.draft.text, 'hello');
      expect(session.feedback, contains('timeout'));
      await session.send();
      expect(ids, hasLength(2));
      expect(ids.toSet(), hasLength(1));
      expect(session.messages.keys, [7]);
      expect(session.rewarded, isTrue);
      expect(session.draft.text, isEmpty);
      session.draft.text = 'alice only';
      await room.login('bob', 'test');
      expect(session.draft.text, isEmpty);
      expect(session.messages, isEmpty);
    },
  );
  for (final width in [320.0, 1280.0]) {
    testWidgets(
      'public web additions fit at $width without submitting live data',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final site = HubSite(
          (m, p, b) async => {
            'success': true,
            'data': p == '/api/play-testing'
                ? {'registrationOpen': true, 'consentVersion': 'fixture'}
                : {
                    'cursor': '1',
                    'packets': [
                      {
                        'type': 'snapshot',
                        'messages': [
                          {
                            'id': 1,
                            'content': 'fixture hello',
                            'authorName': 'Fixture',
                          },
                        ],
                      },
                    ],
                  },
          },
        );
        final room = await controller(site);
        addTearDown(room.dispose);
        for (final name in [
          'assets/site/download-copy.json',
          'assets/site/app-releases.json',
          'assets/site/play-testing.json',
        ]) {
          rootBundle.evict(name);
        }
        for (final page in [
          DownloadPage(controller: room, onGo: (_) {}),
          PlayApplyPage(controller: room, onGo: (_) {}),
          ChatroomPage(controller: room, onGo: (_) {}),
        ]) {
          await tester.pumpWidget(MaterialApp(home: page));
          await tester.pumpAndSettle();
          if (page is DownloadPage) {
            await tester.pumpAndSettle();
            expect(find.text('Windows'), findsOneWidget);
            expect(find.text('macOS'), findsOneWidget);
          }
          if (page is PlayApplyPage) {
            expect(find.text('Google 账号邮箱'), findsOneWidget);
            expect(
              tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, '提交测试申请'),
                  )
                  .onPressed,
              isNull,
            );
          }
          if (page is ChatroomPage) {
            expect(find.textContaining('fixture hello'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        }
        expect(site.calls.any((s) => s.startsWith('POST')), isFalse);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'more stories appends one page and keeps the recommendation snapshot',
    (tester) async {
      final site = HubSite((m, p, b) async {
        if (!p.contains('/articles?')) return {'data': []};
        final second = Uri.parse(p).queryParameters['page'] == '2';
        return {
          'data': [
            {'id': second ? 2 : 1, 'title': second ? 'Story two' : 'Story one'},
          ],
          'pagination': {'page': second ? 2 : 1, 'totalPages': 2, 'total': 2},
          'recommendationSnapshot': '0123456789abcdef01234567',
        };
      });
      final room = await controller(site);
      addTearDown(room.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SitePage(controller: room, path: '/stage?sort=featured'),
        ),
      );
      await tester.pumpAndSettle();
      final more = find.byKey(const Key('stage-more'));
      await Scrollable.ensureVisible(tester.element(more), alignment: .5);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('Story one'), findsOneWidget);
      expect(find.text('Story two'), findsOneWidget);
      expect(
        site.calls.any((s) => s.contains('snapshot=0123456789abcdef01234567')),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
