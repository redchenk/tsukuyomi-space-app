import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/site_search.dart';

import 'support/fakes.dart';

class SearchFake extends FakeSite implements SiteDataService {
  final calls = <Uri>[], replies = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) {
    calls.add(Uri.parse(path));
    final reply = Completer<Map<String, dynamic>>();
    replies.add(reply);
    return reply.future;
  }
}

void main() {
  test('search aliases use every term and never expose backend pages', () {
    expect(
      searchSitePages('wiki 角色', authenticated: false).single.key,
      '/wiki',
    );
    expect(searchSitePages('admin', authenticated: true), isEmpty);
    expect(searchSitePages('terminal', authenticated: true), isEmpty);
    expect(searchSitePages('profile', authenticated: false), isEmpty);
    expect(searchSitePages('profile', authenticated: true).single.key, '/user');
  });
  testWidgets(
    'public search debounces and discards stale results before native navigation',
    (tester) async {
      final site = SearchFake();
      final c = RoomController(
        storage: MemoryStorage(),
        chat: FakeChat(),
        site: site,
        voice: SilentVoice(),
      );
      await c.initialize();
      addTearDown(c.dispose);
      final paths = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showSiteSearch(context, c, paths.add),
                child: const Text('打开搜索'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '第一篇');
      await tester.pump(const Duration(milliseconds: 150));
      expect(site.calls, isEmpty);
      await tester.enterText(find.byType(TextField), '第二篇');
      await tester.pump(const Duration(milliseconds: 301));
      expect(site.calls.single.queryParameters, {
        'search': '第二篇',
        'limit': '4',
      });
      await tester.enterText(find.byType(TextField), '最终文章');
      site.replies.first.complete({
        'success': true,
        'data': {
          'articles': [
            {'id': 1, 'title': '过时结果'},
          ],
        },
      });
      await tester.pump(const Duration(milliseconds: 301));
      expect(find.text('过时结果'), findsNothing);
      site.replies.last.complete({
        'success': true,
        'data': {
          'articles': [
            {'id': 7, 'title': '最终公开文章'},
          ],
        },
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('最终公开文章'));
      await tester.pumpAndSettle();
      expect(paths, ['/articles/7']);
      expect(find.text('想找些什么？'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
