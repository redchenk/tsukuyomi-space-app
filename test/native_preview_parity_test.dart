import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as im;
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/editor_page.dart';
import 'package:tsukuyomi_space_app/features/site/native_rich_text.dart';
import 'package:tsukuyomi_space_app/features/site/site_search.dart';
import 'package:tsukuyomi_space_app/features/site/site_widgets.dart';

import 'support/fakes.dart';
import 'support/site_capture_fonts.dart';

const sample = '''## 月下记录

这是 **加粗**、*斜体*、[站内链接](/stage) 与 `inline code`。
下一行保持换行。

> 引用一段温柔的月光。

| 功能 | 状态 |
| :--- | ---: |
| 实时预览 | 已启用 |
| 中文输入 | 正常 |

:::tip 提示
==重点=={.tip} 支持丰富内容。
:::

```js title="moon.js"
const greeting = "月读空间";
console.log(greeting);
```

- [x] 完成预览
- [ ] 继续创作

:::details 延伸阅读
隐藏的 **内容**。
:::

公式：\$E=mc^2\$。脚注[^moon]。

[^moon]: 月亮的注释。''';

String avatar(int seed) {
  final image = im.Image(width: 64, height: 64);
  for (var y = 0; y < 64; y++) {
    for (var x = 0; x < 64; x++) {
      final moon =
          (x - 29) * (x - 29) + (y - 32) * (y - 32) < 440 &&
          (x - 41) * (x - 41) + (y - 24) * (y - 24) > 380;
      image.setPixelRgba(
        x,
        y,
        moon ? 245 : 60 + seed,
        moon ? 224 : 45,
        moon ? 168 : 104 + seed,
        255,
      );
    }
  }
  return 'data:image/png;base64,${base64Encode(im.encodePng(image))}';
}

class PreviewSite extends FakeSite implements SiteDataService {
  @override
  Future<Account> login(String site, String username, String password) async {
    await super.login(site, username, password);
    return Account(username, username, nickname: '月下旅人', avatar: avatar(5));
  }

  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async => {'success': true, 'data': []};
}

Future<RoomController> makeRoom() async {
  final room = RoomController(
    storage: MemoryStorage(),
    site: PreviewSite(),
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await room.initialize();
  await room.login('alice', 'fixture');
  return room;
}

Future<void> screenshot(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('preview-capture')),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('artifacts/ui-parity-v066/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  test('auth/me retain avatar; profile-only avatar changes preserve verified role and account hints', () async {
    final picture = avatar(0);
    final storage = MemoryStorage();
    final site = SiteClient(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'success': true,
            'data': {
              'user': {
                'id': 'alice',
                'username': 'alice',
                'nickname': 'Alice',
                'role': 'admin',
                'avatar': picture,
              },
            },
          }),
          200,
          headers: {
            'content-type': 'application/json',
            'set-cookie': 'tsukuyomi_session=fixture; Path=/; HttpOnly',
          },
        ),
      ),
    );
    final room = RoomController(
      storage: storage,
      site: site,
      chat: FakeChat(),
      voice: SilentVoice(),
    );
    addTearDown(room.dispose);
    await room.initialize();
    await room.login('alice', 'fixture');
    expect(room.account!.avatar, picture);
    expect((await site.me(room.settings.siteUrl)).avatar, picture);
    final replacement = avatar(90);
    await room.updateAccountProfile({
      'id': 'alice',
      'username': 'alice',
      'avatar': replacement,
      'role': 'super_admin',
    });
    expect(room.account!.avatar, replacement);
    expect(room.account!.role, 'admin');
    expect(room.account!.nickname, 'Alice');
    expect(
      jsonDecode(
        storage.drafts.values.firstWhere(
          (v) => v.startsWith('{') && v.contains('"avatar"'),
        ),
      )['avatar'],
      replacement,
    );
    await room.updateAccountProfile({
      'id': 'bob',
      'username': 'bob',
      'avatar': picture,
    });
    expect(room.account!.avatar, replacement);
    await room.updateAccountProfile({
      'id': 'alice',
      'username': 'alice',
      'avatar': '',
    });
    expect(room.account!.avatar, '');
  });

  for (final width in [360.0, 390.0, 768.0, 1280.0, 1920.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'nav avatar decodes and follows profile, logout and account switch at $width/$dark',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final room = await makeRoom();
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            room.dispose();
          });
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              home: SiteControllerScope(
                controller: room,
                child: Scaffold(
                  body: AnimatedBuilder(
                    animation: room,
                    builder: (_, _) => SiteHeader(
                      title: '文章编辑',
                      username: room.sessionExpired
                          ? null
                          : room.account?.displayName,
                      onGo: (_) {},
                      onLogin: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final picture = find.byKey(
              const ValueKey('nav-account-avatar:alice'),
            );
            await precacheImage(
              tester
                  .widget<Image>(
                    find.descendant(of: picture, matching: find.byType(Image)),
                  )
                  .image,
              tester.element(picture),
            );
          });
          await tester.pumpAndSettle();
          final picture = find.byKey(
            const ValueKey('nav-account-avatar:alice'),
          );
          expect(picture, findsOneWidget);
          expect(tester.widget<SiteAvatar>(picture).size, 28);
          expect(
            tester
                .widget<RawImage>(
                  find.descendant(of: picture, matching: find.byType(RawImage)),
                )
                .image,
            isNotNull,
          );
          final replacement = avatar(90);
          await room.updateAccountProfile({
            'id': 'alice',
            'username': 'alice',
            'avatar': replacement,
          });
          await tester.pump();
          expect(tester.widget<SiteAvatar>(picture).value, replacement);
          await room.logout();
          await tester.pumpAndSettle();
          expect(picture, findsNothing);
          await room.login('bob', 'fixture');
          await tester.pumpAndSettle();
          expect(picture, findsNothing);
          expect(
            find.byKey(const ValueKey('nav-account-avatar:bob')),
            findsOneWidget,
          );
          room.expireSession();
          await tester.pumpAndSettle();
          expect(find.byType(SiteAvatar), findsNothing);
          await room.login('bob', 'fixture');
          await tester.pumpAndSettle();
          await room.configure(
            room.settings.copyWith(siteUrl: 'https://other.example'),
          );
          await tester.pumpAndSettle();
          expect(find.byType(SiteAvatar), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'Markdown editor and reader capture shared typography, avatar and Chinese composition',
    (tester) async {
      final capture = const bool.fromEnvironment('CAPTURE_UI');
      if (capture) {
        await tester.runAsync(() async {
          await loadSiteCaptureFonts();
          await (FontLoader('monospace')..addFont(
                Future.value(
                  ByteData.sublistView(
                    await File('/System/Library/Fonts/Menlo.ttc').readAsBytes(),
                  ),
                ),
              ))
              .load();
        });
      }
      for (final width in [390.0, 1280.0]) {
        for (final dark in [true, false]) {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          final room = await makeRoom();
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              home: SiteControllerScope(
                controller: room,
                child: RepaintBoundary(
                  key: const Key('preview-capture'),
                  child: EditorPage(
                    controller: room,
                    path: '/editor',
                    onGo: (_) {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final picture = find.byKey(
            const ValueKey('nav-account-avatar:alice'),
          );
          final pictureProvider = tester
              .widget<Image>(
                find.descendant(of: picture, matching: find.byType(Image)),
              )
              .image;
          await tester.runAsync(() async {
            await precacheImage(
              pictureProvider,
              tester.element(find.byType(EditorPage)),
            );
          });
          await tester.pumpAndSettle();
          final input = find.byKey(const ValueKey('editor-content'));
          await tester.enterText(input, sample);
          FocusManager.instance.primaryFocus?.unfocus();
          if (width < 760) {
            await tester.tap(find.widgetWithText(ChoiceChip, '预览'));
          }
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 40));
          });
          await tester.pumpAndSettle();
          final preview = find.byKey(const Key('article-editor-preview'));
          await tester.ensureVisible(preview);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<NativeRichText>(
                  find.descendant(
                    of: preview,
                    matching: find.byType(NativeRichText),
                  ),
                )
                .content,
            sample,
          );
          expect(find.byType(NativeCodeBlock), findsOneWidget);
          final accountPicture = find.byKey(
            const ValueKey('nav-account-avatar:alice'),
          );
          expect(
            tester
                .widget<RawImage>(
                  find.descendant(
                    of: accountPicture,
                    matching: find.byType(RawImage),
                  ),
                )
                .image,
            isNotNull,
          );
          expect(tester.takeException(), isNull);
          if (capture) {
            await screenshot(
              tester,
              'native-editor-${width.toInt()}-${dark ? 'dark' : 'light'}',
            );
          }
          await tester.pumpWidget(const SizedBox());
          room.dispose();
        }
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}
