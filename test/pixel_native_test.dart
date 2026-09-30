import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/pixel/pixel_document.dart';
import 'package:tsukuyomi_space_app/features/pixel/pixel_page.dart';
import 'package:tsukuyomi_space_app/features/pixel/pixel_session.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';

class PixelApi extends FakeSite implements SiteDataService {
  final calls = <(String, String, Map<String, dynamic>?)>[];
  Completer<Map<String, dynamic>>? pending;
  Map<String, dynamic> artwork = {
    ...PixelDocument().snapshot.toJson(),
    'id': 'a',
    'title': '月',
    'author_id': 'alice',
    'author': 'alice',
    'likes': 0,
    'viewer_liked': false,
  };
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    calls.add((method, path, body));
    if (pending != null && method == 'POST') return pending!.future;
    if (method == 'GET' &&
        (path.contains('/gallery?') || path.contains('/manage?'))) {
      return {
        'data': [artwork],
        'pagination': {'total': 25},
      };
    }
    if (method == 'POST' && path.endsWith('/like')) {
      artwork = {...artwork, 'viewer_liked': true, 'likes': 1};
      return {'data': artwork};
    }
    if (method == 'POST' || method == 'PUT') {
      artwork = {...artwork, ...?body};
      return {'data': artwork};
    }
    return {'data': artwork};
  }
}

void main() {
  test('192×108 indexed canvas preserves continuous strokes and one undo per stroke', () {
    final doc = PixelDocument();
    addTearDown(doc.dispose);
    expect((doc.width, doc.height), (192, 108));
    expect(doc.pixels, hasLength(20736));
    doc.beginStroke(2, 3);
    doc.continueStroke(20, 3);
    doc.endStroke();
    for (var x = 2; x <= 20; x++) {
      expect(doc.pixels[3 * 192 + x], 3);
    }
    expect(doc.paintedCount, 19);
    doc.undo();
    expect(doc.paintedCount, 0);
    doc.redo();
    expect(doc.paintedCount, 19);
  });
  test('fill stays inside connected boundary; eraser is transparent and reversible', () {
    final doc = PixelDocument();
    addTearDown(doc.dispose);
    doc.resize(32, 18);
    doc.beginStroke(4, 0);
    doc.continueStroke(4, 17);
    doc.endStroke();
    doc.chooseTool(PixelTool.fill);
    doc.chooseColor(5);
    doc.beginStroke(0, 0);
    expect(doc.pixels[0], 5);
    expect(doc.pixels[4], 3);
    expect(doc.pixels[5], -1);
    doc.chooseTool(PixelTool.eraser);
    doc.beginStroke(4, 8);
    doc.endStroke();
    expect(doc.pixels[8 * 32 + 4], -1);
    doc.undo();
    expect(doc.pixels[8 * 32 + 4], 3);
  });
  test('pressure brush clamps edges and fill never wraps between rows', () {
    final doc = PixelDocument();
    addTearDown(doc.dispose);
    doc.brushSize = 4;
    doc.beginStroke(0, 0, pen: true, pressure: 1);
    doc.endStroke();
    expect(doc.pixels.last, -1);
    expect(doc.paintedCount, 16);
    expect(doc.cellIndex(-1, 0), isNull);
    expect(doc.cellIndex(192, 0), isNull);
  });
  test('palette, background and dimensions participate in undo history', () {
    final doc = PixelDocument();
    addTearDown(doc.dispose);
    doc.setBackground('#172033');
    doc.resize(32, 18);
    doc.undo();
    expect((doc.width, doc.height), (192, 108));
    expect(doc.background, '#172033');
    doc.undo();
    expect(doc.background, '#ffffff');
    for (var i = 0; i < 52; i++) {
      doc.addColor('#${(0x100000 + i).toRadixString(16)}');
    }
    expect(doc.palette, hasLength(64));
    expect(() => doc.addColor('#fffffe'), throwsA(isA<ApiFailure>()));
  });
  test(
    'RGBA import quantizes channels, preserves transparency and is undoable',
    () {
      final doc = PixelDocument();
      addTearDown(doc.dispose);
      doc.resize(32, 18);
      final bytes = Uint8List(32 * 18 * 4);
      bytes.setRange(0, 8, [255, 10, 50, 255, 250, 0, 0, 10]);
      doc.importRgba(bytes);
      expect(doc.palette[doc.pixels.first], '#ff0040');
      expect(doc.pixels[1], -1);
      expect(doc.palette.length, lessThanOrEqualTo(44));
      doc.undo();
      expect(doc.paintedCount, 0);
    },
  );
  test(
    'malformed or hostile snapshots cannot corrupt palette-index rendering',
    () {
      final valid = PixelDocument().snapshot.toJson();
      expect(
        () => PixelSnapshot.fromJson({...valid, 'width': 100000}),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        () => PixelSnapshot.fromJson({
          ...valid,
          'pixels': [1],
        }),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        () => PixelSnapshot.fromJson({
          ...valid,
          'palette': ['red', 'blue'],
        }),
        throwsA(isA<ApiFailure>()),
      );
    },
  );
  test(
    'publish, update, like and gallery pagination use original API contracts',
    () async {
      final api = PixelApi();
      final c = RoomController(
        storage: MemoryStorage(),
        chat: FakeChat(),
        site: api,
        voice: SilentVoice(),
      );
      await c.initialize();
      c.account = const Account('alice', 'alice');
      final session = PixelSession(c);
      addTearDown(session.dispose);
      addTearDown(c.dispose);
      await session.loadGallery(nextPage: 2);
      expect(
        api.calls.last.$2,
        '/api/pixel-art/gallery?sort=latest&limit=12&offset=12',
      );
      expect(session.totalPages, 3);
      session.document.beginStroke(1, 1);
      session.document.endStroke();
      session.title = '月';
      session.description = '星光';
      expect(await session.publish(), true);
      final posted = api.calls.last;
      expect(posted.$1, 'POST');
      expect(posted.$2, '/api/pixel-art');
      expect(posted.$3!['pixels'], hasLength(20736));
      expect(posted.$3!['width'], 192);
      expect(posted.$3!['height'], 108);
      await session.editArtwork('a');
      session.title = '新月';
      await session.publish();
      expect(api.calls.last.$1, 'PUT');
      expect(api.calls.last.$2, '/api/pixel-art/a');
      await session.like(api.artwork);
      expect(api.calls.last.$2, '/api/pixel-art/a/like');
      final count = api.calls.length;
      await session.like(api.artwork);
      expect(api.calls.length, count);
    },
  );
  test(
    'draft restores artwork and details without using secret storage',
    () async {
      final storage = MemoryStorage();
      final c = RoomController(
        storage: storage,
        chat: FakeChat(),
        site: PixelApi(),
        voice: SilentVoice(),
      );
      await c.initialize();
      addTearDown(c.dispose);
      final first = PixelSession(c);
      first.document.moonExample();
      first.title = '本机草稿';
      await first.saveDraft();
      first.dispose();
      final restored = PixelSession(c);
      addTearDown(restored.dispose);
      await restored.restoreDraft();
      expect(restored.document.paintedCount, greaterThan(0));
      expect(restored.title, '本机草稿');
      expect(storage.secrets, isEmpty);
    },
  );
  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('pixel native tools and publish form fit width $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = RoomController(
        storage: MemoryStorage(),
        chat: FakeChat(),
        site: PixelApi(),
        voice: SilentVoice(),
      );
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: PixelPage(controller: c, onGo: (_) {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('画笔 B'), findsOneWidget);
      expect(find.text('导出 PNG'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
}
