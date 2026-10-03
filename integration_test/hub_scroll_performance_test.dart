import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/hub_page.dart';
import 'package:tsukuyomi_space_app/features/site/hub_pixel_preview.dart';

import '../test/support/fakes.dart';

class _HubBenchmarkSite extends FakeSite implements SiteDataService {
  final preview = <String, dynamic>{
    'article': {'id': 1, 'title': '月下创作', 'excerpt': '相同内容与图片的中枢滚动基准'},
    'gallery': {'id': 2, 'created_at': '2026-10-02T00:00:00Z'},
    'pixel': {
      'id': 3,
      'title': '完整像素画预览',
      'width': 96,
      'height': 54,
      'palette': ['#20243c', '#aef2ff', '#7b8cf6', '#ff9aba', '#f1d98e'],
      'pixels_base64': base64Encode(List.generate(96 * 54, (i) => i % 5 + 1)),
    },
    'messages': List.generate(
      3,
      (i) => {'id': i, 'author': '月下访客 $i', 'content': '今天也在月读空间留下问候。'},
    ),
    'stats': {
      'todayViews': 31,
      'totalViews': 1234,
      'users': 17,
      'articles': 2,
      'messages': 4,
      'uptime': 90000,
    },
  };

  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async => {
    'success': true,
    'data': path == '/api/settings'
        ? {'visitPopupTitle': '中枢滚动基准', 'visitPopupContent': '固定公告内容'}
        : preview,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('native Hub scroll benchmark', (tester) async {
    final runs = <Map<String, dynamic>>[];
    const busy = bool.fromEnvironment('BENCHMARK_BUSY');
    double p95(List<double> values) {
      values.sort();
      return values.isEmpty ? 0 : values[((values.length - 1) * .95).round()];
    }

    for (var repetition = 0; repetition < 3; repetition++) {
      final room = RoomController(
        storage: MemoryStorage()..value = const RoomSettings(demo: false),
        site: _HubBenchmarkSite(),
        chat: FakeChat(),
        voice: SilentVoice(),
      );
      await room.initialize();
      // First viewport paint/decode is measured separately from warmed scroll.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      final coldFrames = <FrameTiming>[];
      void recordCold(List<FrameTiming> batch) => coldFrames.addAll(batch);
      SchedulerBinding.instance.addTimingsCallback(recordCold);
      final cold = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          home: HubPage(controller: room, onGo: (_) {}),
        ),
      );
      await tester.pumpAndSettle();
      cold.stop();
      await tester.pump(const Duration(milliseconds: 300));
      SchedulerBinding.instance.removeTimingsCallback(recordCold);
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      // Warm the exact image/preview scene before measuring scroll, including
      // the bottom of the page. Initial image decode is not a scroll frame.
      scroll.jumpTo(scroll.maxScrollExtent);
      await tester.pumpAndSettle();
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      final frames = <FrameTiming>[];
      void record(List<FrameTiming> batch) => frames.addAll(batch);
      SchedulerBinding.instance.addTimingsCallback(record);
      var notifications = 0, previewWidgetChanges = 0;
      final previewElement = find.byType(HubPixelPreview).evaluate().single;
      var lastPreviewWidget = previewElement.widget;
      void observePreview() {
        if (!identical(lastPreviewWidget, previewElement.widget)) {
          previewWidgetChanges++;
          lastPreviewWidget = previewElement.widget;
        }
      }

      final timer = busy
          ? Timer.periodic(const Duration(milliseconds: 32), (_) {
              observePreview();
              notifications++;
              room.workspace.changed();
            })
          : null;
      final sample = Stopwatch()..start();
      final gestures = <Map<String, dynamic>>[];
      var distance = 0.0, previousOffset = scroll.pixels;
      void trackOffset() {
        distance += (scroll.pixels - previousOffset).abs();
        previousOffset = scroll.pixels;
      }

      scroll.addListener(trackOffset);
      for (var swipe = 0; swipe < 12; swipe++) {
        final gestureStart = sample.elapsedMilliseconds;
        final startOffset = scroll.pixels;
        // Exercise real pointer input and native ballistic scrolling.
        await tester.fling(
          find.byType(Scrollable).first,
          Offset(0, swipe.isEven ? -500 : 500),
          2200,
        );
        if (busy) {
          for (
            var frame = 0;
            frame < 120 && scroll.isScrollingNotifier.value;
            frame++
          ) {
            await tester.pump(const Duration(milliseconds: 16));
          }
        } else {
          await tester.pumpAndSettle(const Duration(milliseconds: 16));
        }
        gestures.add({
          'from': startOffset,
          'to': scroll.pixels,
          'duration_ms': sample.elapsedMilliseconds - gestureStart,
        });
      }
      await tester.pump(const Duration(milliseconds: 300));
      sample.stop();
      timer?.cancel();
      scroll.removeListener(trackOffset);
      observePreview();
      SchedulerBinding.instance.removeTimingsCallback(record);
      final ui =
          frames.map((f) => f.buildDuration.inMicroseconds / 1000).toList()
            ..sort();
      final raster =
          frames.map((f) => f.rasterDuration.inMicroseconds / 1000).toList()
            ..sort();
      expect(frames.length, greaterThan(100));
      final run = {
        'run': repetition + 1,
        'frames': frames.length,
        'sample_duration_ms': sample.elapsedMilliseconds,
        'scroll_distance_px': distance,
        'scroll_extent_px': scroll.maxScrollExtent,
        'gestures': gestures,
        'workspace_notifications': notifications,
        'preview_widget_changes': previewWidgetChanges,
        'cold_settle_ms': cold.elapsedMilliseconds,
        'cold_frames': coldFrames.length,
        'cold_ui_p95_ms': p95(
          coldFrames.map((f) => f.buildDuration.inMicroseconds / 1000).toList(),
        ),
        'cold_raster_p95_ms': p95(
          coldFrames
              .map((f) => f.rasterDuration.inMicroseconds / 1000)
              .toList(),
        ),
        'ui_p95_ms': p95(ui),
        'raster_p95_ms': p95(raster),
        'frames_over_16_7_ms': frames
            .where(
              (f) =>
                  f.buildDuration.inMicroseconds > 16667 ||
                  f.rasterDuration.inMicroseconds > 16667,
            )
            .length,
        'rss_bytes': ProcessInfo.currentRss,
        'image_cache_bytes':
            PaintingBinding.instance.imageCache.currentSizeBytes,
        'logical_width':
            tester.view.physicalSize.width / tester.view.devicePixelRatio,
        'logical_height':
            tester.view.physicalSize.height / tester.view.devicePixelRatio,
        'device_pixel_ratio': tester.view.devicePixelRatio,
      };
      runs.add(run);
      // ignore: avoid_print
      print('HUB_BENCHMARK ${jsonEncode(run)}');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      room.dispose();
    }
    binding.reportData = {
      'label': const String.fromEnvironment(
        'BENCHMARK_LABEL',
        defaultValue: 'after',
      ),
      'workspace_notification_interval_ms': busy ? 32 : null,
      'scene': 'macOS profile; native Hub hero, 3 cards, dense 96x54 pixel artwork, 3 greetings; 12 alternating pointer flings (500 px at 2200 px/s) with native ballistic scrolling; three runs',
      'runs': runs,
    };
  }, timeout: const Timeout(Duration(minutes: 5)));
}
