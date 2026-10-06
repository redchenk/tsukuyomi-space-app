import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/season_theme.dart';
import 'package:tsukuyomi_space_app/core/site_theme.dart';

import 'support/fakes.dart';

class _SlowStorage extends MemoryStorage {
  final read = Completer<String>();
  @override
  Future<String> draft(String scope) => read.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('local month boundaries and opposite hemispheres match the website', () {
    for (var month = 1; month <= 12; month++) {
      final north = calendarSeason(DateTime(2026, month));
      expect(
        north,
        month >= 3 && month <= 5
            ? SiteSeason.spring
            : month >= 6 && month <= 8
            ? SiteSeason.summer
            : month >= 9 && month <= 11
            ? SiteSeason.autumn
            : SiteSeason.winter,
      );
      expect(
        calendarSeason(DateTime(2026, month), south: true),
        SiteSeason.values[(north.index + 2) % 4],
      );
    }
  });
  test('06:00/18:00 room lighting is independent of light/dark preference', () {
    expect(roomDaytime(DateTime(2026, 10, 6, 5, 59)), false);
    expect(roomDaytime(DateTime(2026, 10, 6, 6)), true);
    expect(roomDaytime(DateTime(2026, 10, 6, 17, 59)), true);
    expect(roomDaytime(DateTime(2026, 10, 6, 18)), false);
    expect(
      nextRoomLightingDelay(DateTime(2026, 10, 6, 18)),
      const Duration(hours: 12),
    );
  });
  test(
    'restores manual selection but a delayed read cannot replace new choice',
    () async {
      final storage = _SlowStorage();
      final season = SeasonThemeController(
        storage,
        now: () => DateTime(2026, 10, 6),
      );
      addTearDown(season.dispose);
      expect(season.season, SiteSeason.autumn);
      final read = season.restore();
      await season.select('summer', southern: true);
      storage.read.complete(jsonEncode({'mode': 'winter'}));
      await read;
      expect(season.season, SiteSeason.summer);
      final restart = SeasonThemeController(
        storage,
        now: () => DateTime(2026, 10, 6),
      );
      addTearDown(restart.dispose);
      // A separate non-delayed store verifies real persisted preferences.
      final fresh = SeasonThemeController(
        MemoryStorage()
          ..drafts[SeasonThemeController.storageKey] =
              storage.drafts[SeasonThemeController.storageKey]!,
        now: () => DateTime(2026, 10, 6),
      );
      addTearDown(fresh.dispose);
      await fresh.restore();
      expect(fresh.season, SiteSeason.summer);
      expect(fresh.south, true);
    },
  );
  test(
    'automatic theme refreshes after midnight/resume without periodic polling',
    () {
      var now = DateTime(2026, 8, 31, 23, 59);
      final season = SeasonThemeController(MemoryStorage(), now: () => now);
      addTearDown(season.dispose);
      expect(season.season, SiteSeason.summer);
      now = DateTime(2026, 9, 1);
      season.refresh();
      expect(season.season, SiteSeason.autumn);
    },
  );
  test('exact website seasonal tokens and semantic status colors', () {
    const light = SitePalette(false, season: SiteSeason.autumn),
        dark = SitePalette(true, season: SiteSeason.winter);
    expect(light.background, const Color(0xfffbf7f1));
    expect(light.primary, const Color(0xff97562b));
    expect(dark.primary, const Color(0xff4f6897));
    expect(dark.accent, const Color(0xffb4c9f4));
    for (final season in SiteSeason.values) {
      expect(
        SitePalette(false, season: season).success,
        const SitePalette(false).success,
      );
      expect(
        siteTheme(
          true,
          season: season,
        ).extension<SiteSeasonColors>()!.palette.season,
        season,
      );
    }
  });
}
