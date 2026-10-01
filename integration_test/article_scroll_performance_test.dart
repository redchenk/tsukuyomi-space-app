import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tsukuyomi_space_app/features/site/site_widgets.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('long native article scroll benchmark', (tester) async {
    final content = List.generate(
      60,
      (i) =>
          '## Section $i\n\n'
          '${List.generate(10, (j) => '段落 $i/$j：使用相同的中文正文、代码与表格验证文章上下滚动。 The same article fixture measures native scroll frame times.').join('\n\n')}\n\n'
          '${i % 3 == 0 ? '```dart\nfinal section = $i;\nprint(section);\n```\n\n| Name | Value |\n| --- | --- |\n| section | $i |\n\n![fixture](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==)' : ''}',
    ).join('\n\n');
    final runs = <Map<String, dynamic>>[];
    for (var repetition = 0; repetition < 3; repetition++) {
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ArticleBody(
                  content: content,
                  format: 'markdown',
                  site: 'https://example.com',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Match the normal reading state with the desktop table of contents collapsed.
      final toc = find.text('文章目录');
      if (toc.evaluate().isNotEmpty) {
        await tester.tap(toc);
        await tester.pumpAndSettle();
      }
      scroll.jumpTo(1000);
      await tester.pump(const Duration(milliseconds: 200));
      final frames = <FrameTiming>[];
      void record(List<FrameTiming> batch) => frames.addAll(batch);
      SchedulerBinding.instance.addTimingsCallback(record);
      for (var step = 0; step < 180; step++) {
        final offset = 1000 + (step < 90 ? step : 180 - step) * 45.0;
        scroll.jumpTo(offset.clamp(0, scroll.position.maxScrollExtent));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 300));
      SchedulerBinding.instance.removeTimingsCallback(record);
      final ui =
          frames.map((f) => f.buildDuration.inMicroseconds / 1000).toList()
            ..sort();
      final raster =
          frames.map((f) => f.rasterDuration.inMicroseconds / 1000).toList()
            ..sort();
      double p95(List<double> values) =>
          values.isEmpty ? 0 : values[((values.length - 1) * .95).round()];
      final run = {
        'run': repetition + 1,
        'frames': frames.length,
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
      };
      runs.add(run);
      // ignore: avoid_print
      print('ARTICLE_BENCHMARK ${jsonEncode(run)}');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      scroll.dispose();
    }
    binding.reportData = {
      'label': const String.fromEnvironment(
        'BENCHMARK_LABEL',
        defaultValue: 'after',
      ),
      'scene': 'macOS Profile 1280x820; 60 headings, 600 paragraphs, 20 code blocks, 20 tables, 20 image fixtures; 180 scroll steps; three runs',
      'runs': runs,
    };
  }, timeout: const Timeout(Duration(minutes: 5)));
}
