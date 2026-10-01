import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image/image.dart' as image;
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/asset_library_page.dart';
import 'package:tsukuyomi_space_app/features/site/editor_page.dart';
import 'package:tsukuyomi_space_app/features/site/native_article_editor.dart';
import 'package:tsukuyomi_space_app/features/site/native_asset_service.dart';
import 'package:tsukuyomi_space_app/features/site/native_rich_text.dart';

import 'support/fakes.dart';

class _Site extends FakeSite implements SiteDataService {
  String role = 'user';
  final calls = <({String method, String path, Map<String, dynamic>? body})>[];
  Future<Map<String, dynamic>> Function(String, String, Map<String, dynamic>?)?
  handler;
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    calls.add((method: method, path: path, body: body));
    if (handler != null) return handler!(method, path, body);
    return {
      'success': true,
      'data': path == '/api/user/profile'
          ? {'role': role}
          : path == '/api/article-categories'
          ? [
              {'id': 1, 'name': '公告'},
              {'id': 2, 'name': '其他'},
              {'id': 3, 'name': '技术'},
            ]
          : [],
    };
  }
}

Future<RoomController> _room(_Site site, {bool loggedIn = true}) async {
  final c = RoomController(
    storage: MemoryStorage(),
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await c.initialize();
  if (loggedIn) await c.login('alice', 'password');
  return c;
}

AssetUploadFile _file(Uint8List bytes, {String name = 'notes.txt'}) =>
    AssetUploadFile(
      name: name,
      size: bytes.length,
      modified: 30,
      readRange: (start, end) async => Uint8List.sublistView(bytes, start, end),
    );

class _UploadServer {
  final parts = <Map<String, dynamic>>[];
  bool completed = false;
  int size = 0, created = 0, completeRequests = 0, deletes = 0;
  Map<String, dynamic> state() => {
    'id': 'upload-1',
    'size': size,
    'chunkBytes': attachmentChunkBytes,
    'parts': List.of(parts),
    'received': parts.fold<int>(0, (sum, part) => sum + (part['size'] as int)),
    'expiresAt': DateTime.now()
        .add(const Duration(days: 1))
        .millisecondsSinceEpoch,
    'completed': completed,
    'processing': false,
    if (completed)
      'asset': {
        'id': 'asset-1',
        'mime_type': 'text/plain',
        'markdown_url': '/api/assets/proxy/asset-1',
      },
  };
  Future<Map<String, dynamic>> request(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    if (method == 'POST' && path == '/api/assets/uploads') {
      size = body!['size'];
      created++;
    }
    if (method == 'POST' && path.endsWith('/complete')) {
      completeRequests++;
      completed = true;
      return {
        'success': true,
        'data': {'processing': true},
      };
    }
    if (method == 'DELETE') deletes++;
    return {'success': true, 'data': state()};
  }

  Future<Map<String, dynamic>> binary(
    String path,
    Uint8List bytes,
    String hash,
    AssetUploadCancellation cancel,
  ) async {
    expect(hash, sha256.convert(bytes).toString());
    expect(path, '/api/assets/uploads/upload-1/${parts.length}');
    parts.add({'hash': hash, 'size': bytes.length});
    return state();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'attachment Markdown matches image, audio, video and document contracts',
    () {
      for (final (mime, expected) in [
        ('image/png', '![name](/asset)'),
        ('audio/mpeg', '\n::media[name](/asset "audio")\n'),
        ('video/mp4', '\n::media[name](/asset "video")\n'),
        ('text/plain', '[name](/asset)'),
      ]) {
        expect(
          nativeAssetMarkdown({
            'id': 1,
            'mime_type': mime,
            'markdown_url': '/asset',
            'metadata': {'fileName': 'name'},
          }),
          expected,
        );
      }
      expect(nativeAssetUrl({'url': '/fallback'}, markdown: true), '/fallback');
      expect(
        nativeAssetMarkdown({
          'mime_type': 'image/png',
          'url': '/x',
          'metadata': {'alt': 'a]\nb'},
        }),
        '![a  b](/x)',
      );
    },
  );

  test(
    'uploader sends verified chunks and polls the 202 completion receipt',
    () async {
      final site = _Site(), server = _UploadServer();
      site.handler = server.request;
      final room = await _room(site);
      addTearDown(room.dispose);
      final service = NativeAssetService(room, binary: server.binary);
      final bytes = Uint8List(attachmentChunkBytes + 13)
        ..fillRange(0, attachmentChunkBytes + 13, 17);
      final asset = await service.upload(_file(bytes), sleep: (_) async {});
      expect(asset['id'], 'asset-1');
      expect(server.parts.map((part) => part['size']), [
        attachmentChunkBytes,
        13,
      ]);
      expect(server.created, 1);
      expect(server.completeRequests, 1);
      final create = site.calls.first;
      expect(create.body!['mimeType'], 'text/plain');
      expect(create.body!['storage'], 'auto');
      expect(create.body!['requestId'], matches(RegExp(r'^[a-f0-9-]{36}$')));
      expect(
        (room.storage as MemoryStorage).drafts.entries
            .where((entry) => entry.key.startsWith('asset-upload:'))
            .every((entry) => entry.value.isEmpty),
        isTrue,
      );
    },
  );

  test('paused upload resumes from an acknowledged checksum without resending bytes', () async {
    final site = _Site(), server = _UploadServer();
    site.handler = server.request;
    final room = await _room(site);
    addTearDown(room.dispose);
    final service = NativeAssetService(room, binary: server.binary),
        cancel = AssetUploadCancellation();
    final file = _file(Uint8List.fromList(utf8.encode('notes')));
    await expectLater(
      service.upload(
        file,
        cancellation: cancel,
        sleep: (_) async {},
        onProgress: (value, _) {
          if (value == .95) cancel.cancel();
        },
      ),
      throwsA(
        isA<ApiFailure>().having(
          (error) => error.message,
          'message',
          contains('暂停'),
        ),
      ),
    );
    expect(server.parts, hasLength(1));
    expect(server.completeRequests, 0);
    final asset = await service.upload(file, sleep: (_) async {});
    expect(asset['id'], 'asset-1');
    expect(server.created, 1);
    expect(server.parts, hasLength(1));
  });

  test(
    'resuming changed file content rejects and cancels the stale upload',
    () async {
      final site = _Site(), server = _UploadServer();
      site.handler = server.request;
      final room = await _room(site);
      addTearDown(room.dispose);
      final service = NativeAssetService(room, binary: server.binary),
          cancel = AssetUploadCancellation();
      final bytes = Uint8List(100000)..fillRange(0, 100000, 3);
      await expectLater(
        service.upload(
          _file(bytes),
          cancellation: cancel,
          sleep: (_) async {},
          onProgress: (value, _) {
            if (value == .95) cancel.cancel();
          },
        ),
        throwsA(isA<ApiFailure>()),
      );
      bytes[99999] = 4;
      await expectLater(
        service.upload(_file(bytes), sleep: (_) async {}),
        throwsA(
          isA<ApiFailure>().having((error) => error.status, 'status', 409),
        ),
      );
      expect(server.deletes, 1);
      expect(server.parts, hasLength(1));
    },
  );

  test('upload retries transient chunks with the same checksum and bounded backoff', () async {
    final site = _Site(), server = _UploadServer();
    site.handler = server.request;
    final room = await _room(site);
    addTearDown(room.dispose);
    var attempts = 0;
    final waits = <Duration>[];
    final service = NativeAssetService(
      room,
      binary: (path, bytes, hash, cancel) async {
        if (attempts++ < 2) throw const ApiFailure('busy', status: 503);
        return server.binary(path, bytes, hash, cancel);
      },
    );
    await service.upload(
      _file(Uint8List.fromList([1, 2])),
      sleep: (duration) async => waits.add(duration),
    );
    expect(attempts, 3);
    expect(waits.take(2), [
      const Duration(seconds: 1),
      const Duration(seconds: 2),
    ]);
    expect(server.parts, hasLength(1));
  });

  test(
    'invalid file and signed-out upload never create server sessions',
    () async {
      final site = _Site();
      final c = await _room(site, loggedIn: false);
      addTearDown(c.dispose);
      final service = NativeAssetService(c);
      await expectLater(
        service.upload(_file(Uint8List(0))),
        throwsA(isA<ApiFailure>()),
      );
      await expectLater(
        service.upload(_file(Uint8List(1), name: 'program.exe')),
        throwsA(isA<ApiFailure>()),
      );
      await expectLater(
        service.upload(_file(Uint8List(1))),
        throwsA(
          isA<ApiFailure>().having((error) => error.status, 'status', 401),
        ),
      );
      expect(site.calls, isEmpty);
    },
  );

  test('editor saves ordinary author HTML through owner API and clears local draft', () async {
    final site = _Site();
    final c = await _room(site);
    addTearDown(c.dispose);
    final editor = NativeArticleEditor(c, '/editor?id=7');
    addTearDown(editor.dispose);
    site.handler = (method, path, body) async => {
      'success': true,
      'data': path == '/api/user/profile'
          ? {'role': 'user'}
          : path == '/api/article-categories'
          ? [
              {'name': '公告'},
              {'name': '其他'},
              {'name': '技术'},
            ]
          : method == 'GET'
          ? {
              'id': 7,
              'title': '原标题',
              'category': '技术',
              'read_time': '3 min',
              'content': '<p>旧正文</p>',
              'content_format': 'html',
            }
          : {'id': 7},
    };
    await editor.initialize();
    expect(editor.moderator, isFalse);
    expect(
      editor.allowedCategories.any((item) => item['name'] == '公告'),
      isFalse,
    );
    expect(editor.fields['content_format'], 'html');
    editor.change('content', '<p>新正文</p>');
    editor.change('cover_image_asset_id', 'cover-1');
    editor.change('cover_image', '/api/assets/proxy/cover-1');
    final result = await editor.submit();
    expect(result, isNotNull);
    final write = site.calls.last;
    expect(write.method, 'PUT');
    expect(write.path, '/api/user/articles/7');
    expect(write.body!['content_format'], 'html');
    expect(write.body!['cover_image_asset_id'], 'cover-1');
    expect(editor.dirty, isFalse);
    expect(await c.storage.draft(editor.draftKey), '');
  });

  test('moderator editing uses moderation permissions including announcement and status', () async {
    final site = _Site();
    final room = await _room(site);
    addTearDown(room.dispose);
    site.handler = (method, path, body) async => {
      'success': true,
      'data': path == '/api/user/profile'
          ? {'role': 'super_admin'}
          : path == '/api/article-categories'
          ? [
              {'name': '公告'},
              {'name': '其他'},
            ]
          : method == 'GET'
          ? {
              'id': 9,
              'title': '公告标题',
              'category': '公告',
              'read_time': '5 min',
              'content': '正文',
              'content_format': 'markdown',
              'status': 'draft',
            }
          : null,
    };
    final editor = NativeArticleEditor(room, '/editor?id=9');
    addTearDown(editor.dispose);
    await editor.initialize();
    editor.change('status', 'published');
    await editor.submit();
    expect(
      site.calls.any(
        (call) =>
            call.path == '/api/moderation/articles/9' && call.method == 'GET',
      ),
      isTrue,
    );
    expect(site.calls.last.path, '/api/moderation/articles/9/save');
    expect(site.calls.last.method, 'POST');
    expect(site.calls.last.body!['status'], 'published');
    expect(editor.allowedCategories.first['name'], '公告');
  });

  test('new article submits the real published endpoint, without a fabricated approval API', () async {
    final site = _Site();
    final room = await _room(site);
    addTearDown(room.dispose);
    final editor = NativeArticleEditor(room, '/editor');
    addTearDown(editor.dispose);
    await editor.initialize();
    editor.change('title', '新文章');
    editor.change('content', '正文');
    await editor.submit();
    expect(site.calls.last.path, '/api/articles');
    expect(site.calls.last.method, 'POST');
    expect(editor.notice, '文章已发布');
  });

  test(
    'failed publish preserves the account-partitioned recoverable draft',
    () async {
      final site = _Site(), c = await _room(site);
      addTearDown(c.dispose);
      final editor = NativeArticleEditor(c, '/editor');
      await editor.initialize();
      editor.change('title', '未发布标题');
      editor.change('content', '未发布正文');
      site.handler = (_, path, body) async => throw const ApiFailure('offline');
      expect(await editor.submit(), isNull);
      expect(editor.dirty, isTrue);
      final saved = await c.storage.draft(editor.draftKey);
      expect(saved, contains('未发布正文'));
      editor.dispose();
      site.handler = null;
      final restored = NativeArticleEditor(c, '/editor');
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.fields['title'], '未发布标题');
      expect(restored.notice, '已恢复本机草稿');
    },
  );

  test('slow summary cannot replace newly typed content or excerpt', () async {
    final site = _Site(), c = await _room(site);
    addTearDown(c.dispose);
    final editor = NativeArticleEditor(c, '/editor');
    addTearDown(editor.dispose);
    await editor.initialize();
    editor.change('content', '原正文');
    final pending = Completer<Map<String, dynamic>>();
    site.handler = (_, path, body) => pending.future;
    final summary = editor.summarize();
    editor.change('excerpt', '手写摘要');
    pending.complete({
      'success': true,
      'data': {'excerpt': '过时摘要'},
    });
    await summary;
    expect(editor.fields['excerpt'], '手写摘要');
    expect(editor.summaryMessage, contains('已变化'));
  });

  test('account switching flushes its draft and never restores it into another account', () async {
    final site = _Site(), c = await _room(site);
    addTearDown(c.dispose);
    final editor = NativeArticleEditor(c, '/editor');
    addTearDown(editor.dispose);
    await editor.initialize();
    editor.change('title', 'Alice 的草稿');
    final oldKey = editor.draftKey;
    await c.logout();
    await c.login('bob', 'password');
    await editor.initialize();
    expect(await c.storage.draft(oldKey), contains('Alice 的草稿'));
    expect(editor.fields['title'], '');
    expect(editor.draftKey, contains(':bob:new'));
  });

  test('Markdown lists continue, reset tasks and leave empty items, respecting code fences', () {
    final formatter = NativeMarkdownListFormatter();
    String enter(String text) => formatter
        .formatEditUpdate(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
          TextEditingValue(
            text: '$text\n',
            selection: TextSelection.collapsed(offset: text.length + 1),
          ),
        )
        .text;
    expect(enter('- a'), '- a\n- ');
    expect(enter('2. a'), '2. a\n3. ');
    expect(enter('- [x] done'), '- [x] done\n- [ ] ');
    expect(enter('- '), '');
    expect(enter('```\n- code'), '```\n- code\n');
    expect(enter('> quote'), '> quote\n> ');
  });

  for (final width in [320.0, 1280.0]) {
    for (final gallery in [false, true]) {
      testWidgets(
        '${gallery ? 'gallery' : 'attachments'} fits width $width and uses real filters',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final site = _Site();
          final room = await _room(site);
          site.handler = (_, path, body) async => {
            'success': true,
            'data': path == '/api/user/profile'
                ? {'role': 'user'}
                : path == '/api/assets/uploads'
                ? []
                : {
                    'assets': [],
                    'pagination': {'page': 1, 'totalPages': 2, 'total': 24},
                  },
          };
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            room.dispose();
          });
          await tester.pumpWidget(
            MaterialApp(
              home: AssetLibraryPage(
                controller: room,
                path: gallery ? '/gallery/manage' : '/attachments',
                gallery: gallery,
                onGo: (_) {},
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final list = site.calls.firstWhere(
            (call) => call.path.contains('?page='),
          );
          expect(
            list.path,
            contains(
              gallery
                  ? 'limit=12'
                  : width < 760
                  ? 'limit=18'
                  : 'limit=36',
            ),
          );
          if (gallery) {
            expect(list.path, contains('scope=mine'));
          } else {
            expect(find.text('文档'), findsOneWidget);
            expect(find.text('全部用户'), findsNothing);
          }
        },
      );
    }
  }

  testWidgets(
    'gallery upload resizes to 2200px and sends the JPEG legacy contract',
    (tester) async {
      final site = _Site();
      final controller = await _room(site);
      final posted = Completer<void>();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      });
      site.handler = (method, path, body) async {
        if (method == 'POST' && path == '/api/assets') posted.complete();
        return {
          'success': true,
          'data': path == '/api/user/profile'
              ? {'role': 'user'}
              : method == 'POST'
              ? {'id': 'gallery-image'}
              : {
                  'assets': [],
                  'pagination': {'page': 1, 'totalPages': 1, 'total': 0},
                },
        };
      };
      final source = image.encodePng(image.Image(width: 2400, height: 1200));
      await tester.pumpWidget(
        MaterialApp(
          home: AssetLibraryPage(
            controller: controller,
            path: '/gallery/manage',
            gallery: true,
            onGo: (_) {},
            pickFile: () async => XFile.fromData(
              source,
              name: 'original.png',
              path: 'original.png',
              mimeType: 'image/png',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final upload = find.widgetWithText(FilledButton, '上传文件');
      await tester.ensureVisible(upload);
      await tester.tap(upload);
      // Pump fake-zone continuations between real file/codec/isolate events.
      // A single blocking receipt await cannot advance those continuations.
      for (var attempt = 0; attempt < 1000 && !posted.isCompleted; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(
        posted.isCompleted,
        isTrue,
        reason: 'Gallery must receive a real upload receipt',
      );
      await tester.pumpAndSettle();
      final request = site.calls.firstWhere(
        (call) => call.method == 'POST' && call.path == '/api/assets',
      );
      expect(request.body!['mimeType'], 'image/jpeg');
      expect(request.body!['collection'], 'gallery');
      expect(request.body!['fileName'], 'original.png');
      final dataUrl = request.body!['dataUrl'] as String;
      expect(dataUrl, startsWith('data:image/jpeg;base64,'));
      final jpeg = image.decodeJpg(base64Decode(dataUrl.split(',').last))!;
      expect(jpeg.width, 2200);
      expect(jpeg.height, 1100);
      expect(find.text('图片已加入图库'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Ctrl Shift C wraps the selected body in a safe code fence', (
    tester,
  ) async {
    final site = _Site(), room = await _room(site);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      room.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: EditorPage(controller: room, path: '/editor', onGo: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
    final body = find.byKey(const ValueKey('editor-content'));
    await tester.ensureVisible(body);
    const selection = 'before\n```\nafter';
    await tester.enterText(body, selection);
    final controller = tester.widget<TextField>(body).controller!;
    controller.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: selection.length,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.text, '````text\n$selection\n````\n\n');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'native editor publishes entered content and preserves Markdown preview',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final site = _Site(), room = await _room(site);
      String? destination;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        room.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: EditorPage(
            controller: room,
            path: '/editor',
            onGo: (path) => destination = path,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('editor-title')),
        '来自原生编辑器',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('editor-content')));
      await tester.enterText(
        find.byKey(const ValueKey('editor-content')),
        '## 标题\n\n正文',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final publishButton = find.widgetWithText(FilledButton, '发布文章');
      await tester.ensureVisible(publishButton);
      await tester.pumpAndSettle();
      expect(publishButton.hitTestable(), findsOneWidget);
      await tester.tap(publishButton);
      await tester.pumpAndSettle();
      expect(destination, '/stage');
      final publish = site.calls.last;
      expect(publish.method, 'POST');
      expect(publish.path, '/api/articles');
      expect(publish.body!['content'], '## 标题\n\n正文');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop editor starts with live preview and keeps it during formatting',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final room = await _room(_Site());
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        room.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: EditorPage(controller: room, path: '/editor', onGo: (_) {}),
        ),
      );
      await tester.pumpAndSettle();
      final preview = find.byKey(const Key('article-editor-preview'));
      final body = find.byKey(const ValueKey('editor-content'));
      expect(preview, findsOneWidget);
      expect(body, findsOneWidget);
      await tester.enterText(body, '## 中文预览\n\n实时正文');
      await tester.pump(const Duration(milliseconds: 100));
      final rich = find.descendant(
        of: preview,
        matching: find.byType(NativeRichText),
      );
      expect(tester.widget<NativeRichText>(rich).content, '');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(tester.widget<NativeRichText>(rich).content, contains('中文预览'));
      expect(tester.widget<NativeRichText>(rich).trackReading, false);
      expect(tester.widget<NativeRichText>(rich).headers, {
        'Cookie': room.site.cookie,
      });
      final input = tester.widget<TextField>(body).controller!;
      input.selection = const TextSelection(baseOffset: 0, extentOffset: 7);
      await tester.tap(find.widgetWithText(TextButton, '加粗'));
      await tester.pumpAndSettle();
      expect(preview, findsOneWidget);
      expect(body, findsOneWidget);
      expect(tester.widget<NativeRichText>(rich).content, input.text);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mobile preview is always available and flushes pending Chinese input',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final room = await _room(_Site());
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        room.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: EditorPage(controller: room, path: '/editor', onGo: (_) {}),
        ),
      );
      await tester.pumpAndSettle();
      final body = find.byKey(const ValueKey('editor-content'));
      await tester.enterText(body, '## 中文输入\n\n未等待的正文');
      await tester.tap(find.widgetWithText(ChoiceChip, '预览'));
      await tester.pump();
      expect(body, findsNothing);
      final rich = find.descendant(
        of: find.byKey(const Key('article-editor-preview')),
        matching: find.byType(NativeRichText),
      );
      expect(tester.widget<NativeRichText>(rich).content, contains('未等待的正文'));
      await tester.tap(find.widgetWithText(ChoiceChip, '撰写'));
      await tester.pump();
      expect(
        tester.widget<TextField>(body).controller!.text,
        '## 中文输入\n\n未等待的正文',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'platform paste and composing text update both the draft and preview',
    (tester) async {
      final room = await _room(_Site());
      final editor = NativeArticleEditor(room, '/editor');
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        editor.dispose();
        room.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: EditorPage(
            controller: room,
            path: '/editor',
            onGo: (_) {},
            editor: editor,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final input = tester
          .widget<TextField>(find.byKey(const ValueKey('editor-content')))
          .controller!;
      input.value = const TextEditingValue(
        text: '## 中文粘贴\n\n完整正文',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 3, end: 6),
      );
      await tester.pump();
      expect(editor.fields['content'], '## 中文粘贴\n\n完整正文');
      expect(input.value.composing, const TextRange(start: 3, end: 6));
      input.value = input.value.copyWith(composing: TextRange.empty);
      await tester.tap(find.widgetWithText(ChoiceChip, '预览'));
      await tester.pump();
      final rich = find.descendant(
        of: find.byKey(const Key('article-editor-preview')),
        matching: find.byType(NativeRichText),
      );
      expect(tester.widget<NativeRichText>(rich).content, '## 中文粘贴\n\n完整正文');
      await editor.saveDraft();
      expect(await room.storage.draft(editor.draftKey), contains('完整正文'));
      expect(tester.takeException(), isNull);
    },
  );
}
