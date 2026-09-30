import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/locale_controller.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/site_guide.dart';

import 'support/fakes.dart';

const guideSettings = RoomSettings(
  demo: false,
  llmUrl: 'https://api.openai.com/v1',
  model: 'guide-model',
  apiKey: 'private-key',
);
RoomController guideRoom() => RoomController(
  storage: MemoryStorage(),
  chat: FakeChat(),
  site: FakeSite(),
  voice: SilentVoice(),
);
http.Response guideReply(dynamic data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('all original guide locales, destinations, safe prompts and nine sprite sequences exist', () {
    for (final lang in ['zh', 'ja', 'en']) {
      final copy = SiteGuideReference.copy(lang);
      expect(copy['suggestions'] as List, hasLength(4));
      expect(copy['title'], isNotEmpty);
      final prompt = SiteGuideReference.systemPrompt(lang, 'articleDetail');
      expect(
        prompt,
        contains('Never reveal or ask for API keys, passwords, cookies'),
      );
      expect(prompt, contains('Never claim that you performed an action'));
      expect(prompt, contains('route: articleDetail'));
      expect(prompt, contains('/growth'));
      expect(prompt, contains('/attachments'));
    }
    expect(
      SiteGuideReference.guides('/gallery/manage').first['key'],
      'gallery',
    );
    expect(SiteGuideReference.guides('/users/Alice').first['key'], 'growth');
    expect(
      SiteGuideReference.guides('/user?tab=profile').first['key'],
      'growth',
    );
    expect(
      SiteGuideReference.routeName('/friend-links/apply'),
      'friendLinkApply',
    );
    expect(
      SiteGuideReference.routeName('/wiki/characters/yachiyo'),
      'wikiCharacter',
    );
    final sequences = SiteGuideReference.data['sequences'] as Map;
    expect(sequences, hasLength(9));
    expect(sequences['idle']['frames'], [0, 1, 2, 3, 4, 5]);
    expect(sequences['waving']['frames'], [24, 25, 26, 27]);
    expect(sequences['review']['frames'], [64, 65, 66, 67, 68, 69]);
    expect(
      File('assets/images/site-pet-yachiyo-sprites.webp').existsSync(),
      isTrue,
    );
    expect(
      File('assets/images/site-pet-yachiyo-idle.webp').existsSync(),
      isTrue,
    );
  });

  test('guide uses exact non-streaming provider contracts without site cookies on direct requests', () async {
    final requests = <http.Request>[];
    final service = SiteGuideService(
      clientFactory: () => MockClient((r) async {
        requests.add(r);
        return guideReply({'output_text': 'Open /editor.'});
      }),
    );
    addTearDown(service.dispose);
    final reply = await service.ask(
      settings: guideSettings,
      question: '  How do I publish?  ',
      language: 'en',
      routeName: 'stage',
      siteCookie: 'tsukuyomi_session=private-session',
      history: [
        {'role': 'system', 'content': 'user-injected system'},
        for (var i = 0; i < 10; i++)
          {'role': i.isEven ? 'user' : 'assistant', 'content': 'message$i'},
      ],
    );
    expect(reply, 'Open /editor.');
    final request = requests.single, body = jsonDecode(request.body) as Map;
    expect(request.url.toString(), 'https://api.openai.com/v1/responses');
    expect(request.headers['Authorization'], 'Bearer private-key');
    expect(request.headers.containsKey('Cookie'), isFalse);
    expect(request.followRedirects, isFalse);
    expect(body['max_output_tokens'], 900);
    expect(body['input'] as List, hasLength(9));
    expect(body['input'].first['content'], 'message2');
    expect(body['input'].last['content'], 'How do I publish?');
    expect(body['instructions'], contains('Always answer in English.'));
    expect(body.toString(), isNot(contains('user-injected system')));
    expect(body.containsKey('stream'), isFalse);
    expect(
      siteGuideRequestBody(
        guideSettings.copyWith(llmUrl: 'http://localhost:11434'),
        Uri.parse('http://localhost:11434/api/chat'),
        'system',
        [],
        'question',
      ),
      containsPair('stream', false),
    );
    final anthropic = siteGuideRequestBody(
      guideSettings.copyWith(model: 'claude'),
      Uri.parse('https://api.anthropic.com/v1/messages'),
      'system',
      [],
      'question',
    );
    expect(anthropic['max_tokens'], 900);
    expect(anthropic['temperature'], .25);
    expect(anthropic['system'], 'system');
    expect(
      siteGuideRequestBody(
        guideSettings.copyWith(model: 'kimi-k2'),
        Uri.parse('https://api.moonshot.cn/v1/chat/completions'),
        'system',
        [],
        'question',
      )['temperature'],
      1,
    );
    expect(
      siteGuideHeaders(
        guideSettings,
        Uri.parse('http://localhost:11434/api/chat'),
      ).containsKey('Authorization'),
      isFalse,
    );
    expect(
      siteGuideHeaders(
        guideSettings,
        Uri.parse('https://api.anthropic.com/v1/messages'),
      )['x-api-key'],
      'private-key',
    );
    expect(
      siteGuideHeaders(
        guideSettings,
        Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
      )['X-OpenRouter-Title'],
      'Tsukuyomi Space Guide',
    );
  });

  test('proxy uses original /api/chat, clamps questions and history, and redacts failed messages', () async {
    final requests = <http.Request>[];
    final service = SiteGuideService(
      clientFactory: () => MockClient((r) async {
        requests.add(r);
        return requests.length == 1
            ? guideReply({
                'success': true,
                'data': {'reply': '前往 /growth。'},
              })
            : guideReply({
                'success': false,
                'message': 'upstream rejected private-key',
              });
      }),
    );
    addTearDown(service.dispose);
    final s = guideSettings.copyWith(options: {'llmProxy': true});
    await service.ask(
      settings: s,
      question: 'a' * 900,
      history: [
        {'role': 'user', 'content': 'b' * 2500},
      ],
      siteCookie: 'tsukuyomi_session=signed',
    );
    final body = jsonDecode(requests.single.body);
    expect(requests.single.url.path, '/api/chat');
    expect(requests.single.headers['Cookie'], 'tsukuyomi_session=signed');
    expect(requests.single.headers.containsKey('Authorization'), isFalse);
    expect(body['message'].length, 800);
    expect(body['conversation'].single['content'].length, 2400);
    expect(body['apiUrl'], 'https://api.openai.com/v1/responses');
    expect(
      body['systemPrompt'],
      contains('Only explain how to use public site features.'),
    );
    await expectLater(
      service.ask(settings: s, question: 'again'),
      throwsA(
        isA<ApiFailure>().having(
          (e) => e.message,
          'redacted message',
          allOf(contains('[redacted]'), isNot(contains('private-key'))),
        ),
      ),
    );
  });

  test('timeout is bounded even if a transport ignores close and native local status needs no API key', () async {
    final service = SiteGuideService(
      timeout: const Duration(milliseconds: 5),
      clientFactory: () => MockClient((_) => Completer<http.Response>().future),
    );
    addTearDown(service.dispose);
    await expectLater(
      service.ask(settings: guideSettings, question: 'hello', language: 'ja'),
      throwsA(
        isA<ApiFailure>().having(
          (e) => e.message,
          'timeout',
          contains('タイムアウト'),
        ),
      ),
    );
    final local = guideSettings.copyWith(llmUrl: '127.0.0.1:11434', apiKey: '');
    expect(SiteGuideModelStatus.read(local).configured, isTrue);
    expect(SiteGuideModelStatus.read(local).local, isTrue);
    expect(
      siteGuideEndpoint(local.llmUrl).toString(),
      'http://localhost:11434/api/chat',
    );
    expect(
      SiteGuideModelStatus.read(guideSettings.copyWith(apiKey: '')).configured,
      isFalse,
    );
    expect(
      SiteGuideModelStatus.read(local.copyWith(demo: true)).configured,
      isFalse,
    );
  });

  test('closing or changing account cancels guide independently and drops a late private reply', () async {
    final response = Completer<http.Response>();
    final room = guideRoom()..settings = guideSettings;
    final service = SiteGuideService(
      clientFactory: () => MockClient((_) => response.future),
    );
    final guide = SiteGuideController(room, service: service);
    addTearDown(room.dispose);
    addTearDown(guide.dispose);
    final pending = guide.ask('账号一的问题');
    await Future<void>.delayed(Duration.zero);
    expect(guide.asking, isTrue);
    room.account = const Account('other', 'Other');
    room.notifyListeners();
    await pending;
    response.complete(guideReply({'output_text': '账号一的私有回答'}));
    await Future<void>.delayed(Duration.zero);
    expect(guide.messages, isEmpty);
    expect(guide.asking, isFalse);
    expect(guide.error, '');
    expect(room.chat, isA<FakeChat>());
  });

  testWidgets(
    'guide quick help remains usable offline at width 320 and obeys the Japanese locale',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final room = guideRoom(),
          locale = LocaleController(MemoryStorage()),
          routes = <String>[];
      await locale.setLanguage('ja');
      addTearDown(room.dispose);
      addTearDown(locale.dispose);
      await tester.pumpWidget(
        SiteLocaleScope(
          controller: locale,
          child: MaterialApp(
            home: Scaffold(
              body: SiteGuideButton(
                controller: room,
                path: '/gallery',
                onGo: routes.add,
                showPet: false,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(find.text('ヤチヨガイド'), findsOneWidget);
      expect(find.text('クイックヘルプ'), findsOneWidget);
      expect(find.byKey(const Key('site-guide-question')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('ギャラリーと添付'));
      await tester.tap(find.text('ギャラリーと添付'));
      await tester.pumpAndSettle();
      expect(routes, ['/gallery/manage']);
      expect(find.text('ヤチヨガイド'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'guide sends actual native question and renders model answer, with history on reopen',
    (tester) async {
      final room = guideRoom()..settings = guideSettings;
      final service = SiteGuideService(
        clientFactory: () => MockClient(
          (_) async => guideReply({'output_text': '请打开 [等级成长](/growth)。'}),
        ),
      );
      final guide = SiteGuideController(room, service: service);
      final routes = <String>[];
      addTearDown(room.dispose);
      addTearDown(guide.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showSiteGuide(
                  context,
                  room,
                  '/hub',
                  routes.add,
                  guide: guide,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('site-guide-question')));
      await tester.enterText(
        find.byKey(const Key('site-guide-question')),
        '等级任务在哪？',
      );
      // The send button reflects the controller after the field's next frame.
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('site-guide-send')));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('site-guide-send')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('site-guide-send')));
      await tester.pumpAndSettle();
      expect(guide.messages, hasLength(2));
      expect(guide.messages.last['content'], contains('/growth'));
      expect(
        find.textContaining('等级任务在哪？', findRichText: true),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byTooltip('关闭向导'));
      await tester.tap(find.byTooltip('关闭向导'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(guide.messages, hasLength(2));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
