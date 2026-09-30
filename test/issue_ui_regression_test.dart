import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/site_page.dart';
import 'package:tsukuyomi_space_app/live2d/character_stage.dart';

import 'support/fakes.dart';

class _CountingModel extends Live2DModel {
  int ticks = 0;
  @override
  List<LiveMesh> get meshes => [];
  @override
  List<ui.Image> get textures => [];
  @override
  Rect get bounds => const Rect.fromLTRB(0, -10, 10, 0);
  @override
  List<String> get expressions => [];
  @override
  double get updateMilliseconds => 0;
  @override
  void tick(
    double seconds,
    double delta, {
    double mouth = 0,
    double lookX = 0,
    double lookY = 0,
    String expression = 'neutral',
  }) {
    ticks++;
  }
}

Finder _fullscreen(Finder matching) =>
    find.descendant(of: find.byType(Dialog), matching: matching);

Future<void> _scrollMenuTo(WidgetTester tester, String label) async {
  final item = find.text(label);
  await tester.scrollUntilVisible(
    item.hitTestable(),
    160,
    scrollable: find
        .ancestor(of: item, matching: find.byType(Scrollable))
        .first,
    maxScrolls: 12,
  );
  await tester.pump();
  expect(item.hitTestable(), findsOneWidget);
}

Future<void> _finishTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  for (final action in ['点赞', '收藏']) {
    testWidgets(
      'issue #4: late article $action response after leaving does not reload or throw',
      (tester) async {
        final delayedWrite = Completer<http.Response>();
        var articleReads = 0, writes = 0;
        final site = SiteClient(
          client: MockClient((request) async {
            final path = request.url.path.replaceFirst(
              RegExp(r'/api/live/\d+'),
              '/api',
            );
            if (request.method == 'POST' &&
                (path == '/api/user/article-likes/1' ||
                    path == '/api/user/bookmarks/1')) {
              writes++;
              return delayedWrite.future;
            }
            dynamic data = [];
            if (path == '/api/auth/login') {
              data = {
                'user': {'id': 'alice', 'username': 'alice'},
              };
            } else if (path == '/api/auth/me') {
              data = {'id': 'alice', 'username': 'alice'};
            } else if (path == '/api/articles/1') {
              articleReads++;
              data = {
                'id': 1,
                'title': '延迟点赞回归文章',
                'content': '正文。',
                'content_format': 'markdown',
              };
            } else if (path.endsWith('/status')) {
              data = {'liked': false, 'bookmarked': false};
            }
            return http.Response(
              jsonEncode({'success': true, 'data': data}),
              200,
              headers: {
                'content-type': 'application/json; charset=utf-8',
                if (path == '/api/auth/login')
                  'set-cookie': 'tsukuyomi_session=test; HttpOnly',
              },
            );
          }),
        );
        final controller = RoomController(
          storage: MemoryStorage(),
          site: site,
          chat: FakeChat(),
          voice: SilentVoice(),
        );
        await controller.initialize();
        await controller.login('alice', 'password');
        addTearDown(controller.dispose);
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('主舞台')),
          ),
        );
        navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) =>
                SitePage(controller: controller, path: '/articles/1'),
          ),
        );
        await tester.pumpAndSettle();
        final initialReads = articleReads;
        final button = find.widgetWithText(OutlinedButton, action);
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pump();
        expect(writes, 1);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.text('主舞台'), findsOneWidget);
        delayedWrite.complete(http.Response('{"success":true,"data":{}}', 200));
        await tester.pumpAndSettle();
        expect(articleReads, initialReads);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'issue #5: fullscreen opened while loading switches to the loaded model',
    (tester) async {
      final loading = Completer<Live2DModel>();
      final voice = SilentVoice();
      addTearDown(voice.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CharacterStage(
              voice: voice,
              modelLoader: () => loading.future,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('全屏角色舞台'));
      await tester.pumpAndSettle();
      expect(_fullscreen(find.text('Live2D 载入中…')), findsOneWidget);
      expect(_fullscreen(find.text('角色预览')), findsOneWidget);
      final model = _CountingModel();
      loading.complete(model);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(_fullscreen(find.text('Live2D 载入中…')), findsNothing);
      expect(_fullscreen(find.text('角色预览')), findsNothing);
      expect(_fullscreen(find.text('正在听你说')), findsOneWidget);
      expect(
        tester
            .widget<PopupMenuButton<String>>(
              _fullscreen(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is PopupMenuButton<String> &&
                      widget.tooltip == '动作',
                ),
              ),
            )
            .enabled,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'issue #5: fullscreen pause and resume update the button and model ticking',
    (tester) async {
      final model = _CountingModel(), voice = SilentVoice();
      addTearDown(voice.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CharacterStage(voice: voice, modelLoader: () async => model),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.tap(find.byTooltip('全屏角色舞台'));
      await _finishTransition(tester);
      await tester.tap(_fullscreen(find.byTooltip('动作')));
      await _finishTransition(tester);
      await _scrollMenuTo(tester, '暂停动作');
      await tester.tap(find.text('暂停动作'));
      await _finishTransition(tester);
      final pausedTicks = model.ticks;
      await tester.pump(const Duration(seconds: 1));
      expect(model.ticks, pausedTicks);
      await tester.tap(_fullscreen(find.byTooltip('动作')));
      await _finishTransition(tester);
      expect(find.text('继续动作'), findsOneWidget);
      expect(find.text('暂停动作'), findsNothing);
      await _scrollMenuTo(tester, '继续动作');
      await tester.tap(find.text('继续动作'));
      await _finishTransition(tester);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(model.ticks, greaterThan(pausedTicks));
      await tester.tap(_fullscreen(find.byTooltip('退出全屏舞台')));
      await _finishTransition(tester);
      await tester.tap(find.byTooltip('动作'));
      await _finishTransition(tester);
      expect(find.text('暂停动作'), findsOneWidget);
      expect(find.text('继续动作'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
