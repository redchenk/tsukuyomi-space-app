import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/pixel/pixel_document.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/main.dart';

import 'support/fakes.dart';

const _origin = 'https://native-visual.example';
const _cookie = 'tsukuyomi_session=visual.local.session';
const _account = Account('visual-admin', '月下旅人', role: 'admin');
const _routes = [
  '/login',
  '/wiki',
  '/friend-links',
  '/gallery',
  '/editor',
  '/pixel',
  '/user',
  '/admin',
];
const _pictures = {
  '/fixtures/iroha.png': 'assets/images/wiki_entries_characters_iroha.png',
  '/fixtures/terukoto.png':
      'assets/images/wiki_entries_characters_terukoto.png',
};
Iterable<NetworkImage> get _pictureKeys sync* {
  for (final path in _pictures.keys) {
    yield NetworkImage('$_origin$path');
    yield NetworkImage('$_origin$path', headers: const {'Cookie': _cookie});
  }
}

const _categories = [
  {'id': 1, 'name': '公告'},
  {'id': 2, 'name': '其他'},
  {'id': 3, 'name': '月下故事'},
];

class _VisualSite extends FakeSite implements SiteDataService {
  final unhandled = <String>[];
  final _pixel = _pixelSnapshot();

  static Map<String, dynamic> _pixelSnapshot() {
    final pixels = List<int>.filled(32 * 18, -1);
    for (var y = 2; y < 16; y++) {
      for (var x = 9; x < 23; x++) {
        final dx = x - 16, dy = y - 9;
        if (dx * dx + dy * dy < 48 &&
            (x - 20) * (x - 20) + (y - 6) * (y - 6) >= 36) {
          pixels[y * 32 + x] = 1;
        }
      }
    }
    return PixelSnapshot(
      width: 32,
      height: 18,
      pixels: pixels,
      palette: const ['#15213a', '#ffe7a2', '#d5c4ff'],
      background: '#15213a',
    ).toJson();
  }

  Map<String, dynamic> get _profile => {
    'id': _account.id,
    'username': _account.username,
    'role': _account.role,
    'email': 'traveler@example.com',
    'bio': '把月光、故事与日常，收藏在这一方小小的空间。',
    'avatar': '/fixtures/iroha.png',
    'created_at': '2026-06-01T10:00:00Z',
    'has_real_email': true,
    'oauth_accounts': [],
  };

  Map<String, dynamic> _asset(int id, String title, String picture) => {
    'id': id,
    'title': title,
    'mime_type': 'image/png',
    'size': 245760,
    'preview_url': picture,
    'access_url': picture,
    'markdown_url': picture,
    'owner_id': _account.id,
    'owner_username': _account.username,
    'owner_avatar_url': '$_origin/fixtures/iroha.png',
    'created_at': '2026-09-29T11:30:00Z',
    'metadata': {'fileName': '$title.png', 'alt': title},
  };

  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (site != _origin) {
      throw StateError('Visual fixture received an external origin: $site');
    }
    final uri = Uri.parse(path);
    final assets = [
      _asset(7, '月读空间 · 伊吕波', '/fixtures/iroha.png'),
      _asset(8, '与你相遇的季节', '/fixtures/terukoto.png'),
    ];
    final data = switch (uri.path) {
      '/api/settings' => {
        'siteTitle': '月读空间',
        'visitPopupEnabled': false,
        'sakuraEffect': false,
        'scanlineEffect': false,
      },
      '/api/user/notifications/unread-count' => {'count': 3},
      '/api/stats/view' => {'todayViews': 31, 'totalViews': 1234},
      '/api/user/profile' || '/api/moderation/me' => _profile,
      '/api/article-categories' ||
      '/api/moderation/article-categories' => _categories,
      '/api/growth/public' => [
        {'userId': _account.id, 'level': 3},
      ],
      '/api/growth/me' => {
        'summary': {'level': 3, 'title': '月下同行'},
        'level': {
          'level': 3,
          'title': '月下同行',
          'totalXp': 125,
          'progressPercent': 45,
        },
        'streak': {'current': 5, 'longest': 8},
      },
      '/api/friend-links' => [
        {
          'id': 1,
          'name': '月之书架',
          'url': 'https://moon-library.example',
          'description': '收集动画、音乐和那些让人心动的瞬间。',
          'avatar_url': '/fixtures/iroha.png',
          'screenshot_url': '/fixtures/iroha.png',
          'has_backlink': true,
          'monitor_status': 'online',
          'response_time_ms': 123,
          'last_checked_at': '2026-09-30T08:00:00Z',
        },
        {
          'id': 2,
          'name': '星海来信',
          'url': 'https://star-letters.example',
          'description': '在星海里写下日常，也期待与你交换故事。',
          'avatar_url': '/fixtures/terukoto.png',
          'screenshot_url': '/fixtures/terukoto.png',
          'has_backlink': true,
          'monitor_status': 'online',
          'response_time_ms': 86,
          'last_checked_at': '2026-09-30T08:00:00Z',
        },
      ],
      '/api/assets/gallery' || '/api/assets/gallery/public' => {
        'assets': uri.queryParameters['limit'] == '1'
            ? [assets[uri.queryParameters['random'] == '1' ? 1 : 0]]
            : assets,
        'pagination': {'page': 1, 'totalPages': 1, 'total': assets.length},
      },
      '/api/pixel-art/gallery' => [
        {
          ..._pixel,
          'id': 'visual-moon',
          'title': '一弯新月',
          'description': '今晚也有月光陪伴。',
          'author_id': _account.id,
          'author': _account.username,
          'likes': 12,
          'viewer_liked': false,
          'created_at': '2026-09-29T12:00:00Z',
        },
      ],
      '/api/moderation/summary' => {
        'articles': {'all': 2},
        'messages': {'all': 8},
        'gallery': {'all': 2},
        'attachments': {'all': 3},
        'pendingMessages': 1,
      },
      '/api/moderation/articles' => {
        'items': [
          {
            'id': 42,
            'title': '在月读空间，记录与你相遇的故事',
            'status': 'published',
            'category': '月下故事',
            'created_at': '2026-09-29T12:00:00Z',
          },
          {
            'id': 43,
            'title': '九月的月下日记',
            'status': 'draft',
            'category': '其他',
            'created_at': '2026-09-28T12:00:00Z',
          },
        ],
        'pagination': {'page': 1, 'totalPages': 1, 'total': 2},
      },
      _ => null,
    };
    if (data == null) {
      unhandled.add('$method $path');
      throw StateError('Missing visual fixture: $method $path');
    }
    return {
      'success': true,
      'data': data,
      if (uri.path == '/api/pixel-art/gallery') 'pagination': {'total': 1},
    };
  }
}

Future<void> _loadSystemFonts() async {
  final override = const String.fromEnvironment('QA_SANS_FONT');
  final sans = override.isNotEmpty
      ? File(override)
      : Directory('/System/Library/AssetsV2/com_apple_MobileAsset_Font8')
            .listSync(recursive: true)
            .whereType<File>()
            .firstWhere((file) => file.path.endsWith('/PingFang.ttc'));
  final bytes = ByteData.sublistView(await sans.readAsBytes());
  for (final family in ['Roboto', 'PingFang SC']) {
    await (FontLoader(family)..addFont(Future.value(bytes))).load();
  }
  final serif = File(
    const String.fromEnvironment(
      'QA_SERIF_FONT',
      defaultValue: '/System/Library/Fonts/Supplemental/Songti.ttc',
    ),
  );
  await (FontLoader(
        'Songti SC',
      )..addFont(Future.value(ByteData.sublistView(await serif.readAsBytes()))))
      .load();
  await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
        rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
      ))
      .load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}

// Resolve mock image URLs entirely from existing bundled artwork. This also
// preserves the actual Image.network layout without requesting any server.
Future<void> _cacheFixtureImages() async {
  for (final entry in _pictures.entries) {
    final bytes = await rootBundle.load(entry.value);
    final codec = await ui.instantiateImageCodec(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        // NetworkImage cache keys include headers. Gallery images carry the
        // session cookie, while profile and friend-link images do not.
        for (final key in _pictureKeys.where(
          (key) => key.url == '$_origin${entry.key}',
        )) {
          PaintingBinding.instance.imageCache.evict(key);
          PaintingBinding.instance.imageCache.putIfAbsent(
            key,
            () => OneFrameImageStreamCompleter(
              Future.value(ImageInfo(image: frame.image.clone())),
            ),
          );
        }
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
  await Future<void>.delayed(Duration.zero);
}

void main() {
  // Local visual review only; no golden baselines or native media/model loads.
  // flutter test test/site_full_visual_capture_test.dart --dart-define=CAPTURE_UI=true
  testWidgets(
    'capture native site routes with system fonts at desktop and mobile sizes',
    (tester) async {
      await tester.runAsync(_loadSystemFonts);
      addTearDown(() {
        for (final key in _pictureKeys) {
          PaintingBinding.instance.imageCache.evict(key);
        }
      });
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final size in [const Size(1280, 900), const Size(390, 844)]) {
        tester.view.physicalSize = size;
        final form = size.width > 860 ? 'desktop' : 'mobile';
        for (final path in _routes) {
          final site = _VisualSite();
          final storage = MemoryStorage()
            ..value = const RoomSettings(siteUrl: _origin);
          final room = RoomController(
            storage: storage,
            site: site,
            chat: FakeChat(),
            voice: SilentVoice(),
          );
          try {
            await room.initialize();
            if (path != '/login') {
              room.account = _account;
              site.userId = _account.id;
              site.cookie = _cookie;
            }
            // The wiki can evict earlier images from Flutter's bounded cache.
            // Each route starts with freshly decoded local mock images.
            await tester.runAsync(_cacheFixtureImages);
            await tester.pumpWidget(
              RepaintBoundary(
                key: const Key('site-capture'),
                child: TsukuyomiApp(
                  controller: room,
                  initialPath: path,
                  loadNative: false,
                ),
              ),
            );
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 350)),
            );
            await tester.pumpAndSettle(
              const Duration(milliseconds: 50),
              EnginePhase.sendSemanticsUpdate,
              const Duration(seconds: 60),
            );
            expect(tester.takeException(), isNull, reason: '$path ($form)');
            expect(site.unhandled, isEmpty, reason: '$path ($form)');
            if (const ['/gallery', '/friend-links', '/user'].contains(path)) {
              final fixtureImages = find.byWidgetPredicate((widget) {
                if (widget is! Image || widget.image is! NetworkImage) {
                  return false;
                }
                return (widget.image as NetworkImage).url.startsWith(
                  '$_origin/fixtures/',
                );
              });
              expect(
                find.descendant(
                  of: fixtureImages,
                  matching: find.byWidgetPredicate(
                    (widget) => widget is RawImage && widget.image != null,
                  ),
                ),
                findsWidgets,
                reason: '$path ($form) must capture loaded images',
              );
            }
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('site-capture')),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 1);
              try {
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final output = File(
                  'artifacts/native-site-parity/${path.substring(1)}-$form.png',
                );
                await output.parent.create(recursive: true);
                await output.writeAsBytes(
                  bytes!.buffer.asUint8List(
                    bytes.offsetInBytes,
                    bytes.lengthInBytes,
                  ),
                );
              } finally {
                image.dispose();
              }
            });
            expect(tester.takeException(), isNull, reason: '$path ($form)');
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            room.dispose();
          }
        }
      }
    },
    skip: !const bool.fromEnvironment('CAPTURE_UI'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
