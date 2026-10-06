import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'storage.dart';

enum SiteSeason { spring, summer, autumn, winter }

SiteSeason calendarSeason(DateTime date, {bool south = false}) {
  final north = switch (date.month) {
    >= 3 && <= 5 => SiteSeason.spring,
    >= 6 && <= 8 => SiteSeason.summer,
    >= 9 && <= 11 => SiteSeason.autumn,
    _ => SiteSeason.winter,
  };
  return south ? SiteSeason.values[(north.index + 2) % 4] : north;
}

bool roomDaytime(DateTime date) => date.hour >= 6 && date.hour < 18;

Duration nextRoomLightingDelay(DateTime date) {
  final next = date.hour < 6
      ? DateTime(date.year, date.month, date.day, 6)
      : date.hour < 18
      ? DateTime(date.year, date.month, date.day, 18)
      : DateTime(date.year, date.month, date.day + 1, 6);
  return next.difference(date);
}

/// One device preference and calendar timer, independent of login and UI mode.
class SeasonThemeController extends ChangeNotifier with WidgetsBindingObserver {
  SeasonThemeController(this.storage, {DateTime Function()? now})
    : now = now ?? DateTime.now {
    _date = this.now();
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }
  static const storageKey = 'tsukuyomi_season_theme_v1';
  final RoomStorage storage;
  final DateTime Function() now;
  late DateTime _date;
  String mode = 'auto';
  bool south = false, _disposed = false;
  int _revision = 0;
  Timer? _timer;
  Future<void> _writes = Future.value();
  SiteSeason get season => mode == 'auto'
      ? calendarSeason(_date, south: south)
      : SiteSeason.values.byName(mode);

  void refresh() {
    _timer?.cancel();
    if (_disposed) return;
    final previous = season;
    _date = now();
    if (previous != season) notifyListeners();
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    final next = DateTime(_date.year, _date.month, _date.day + 1);
    _timer = Timer(
      Duration(
        milliseconds: next
            .difference(_date)
            .inMilliseconds
            .clamp(1000, 86400000),
      ),
      refresh,
    );
  }

  Future<void> restore() async {
    final revision = _revision;
    try {
      final saved = jsonDecode(await storage.draft(storageKey));
      if (_disposed || revision != _revision || saved is! Map) return;
      mode =
          [
            'auto',
            ...SiteSeason.values.map((s) => s.name),
          ].contains(saved['mode'])
          ? saved['mode'] as String
          : 'auto';
      south = saved['hemisphere'] == 'south';
      refresh();
      notifyListeners();
    } catch (_) {
      /* Missing preferences use the local calendar. */
    }
  }

  Future<bool> select(String value, {bool? southern}) {
    if (_disposed ||
        !['auto', ...SiteSeason.values.map((s) => s.name)].contains(value)) {
      return Future.value(false);
    }
    _revision++;
    mode = value;
    south = southern ?? south;
    final json = jsonEncode({
      'version': 1,
      'mode': mode,
      'hemisphere': south ? 'south' : 'north',
    });
    refresh();
    notifyListeners();
    final saved = _writes.then((_) async {
      try {
        await storage.saveDraft(storageKey, json);
        return true;
      } catch (_) {
        return false;
      }
    });
    _writes = saved.then((_) {});
    return saved;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => refresh();
  @override
  void didChangeMetrics() => refresh();
  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class SiteSeasonScope extends InheritedNotifier<SeasonThemeController> {
  const SiteSeasonScope({
    super.key,
    required SeasonThemeController controller,
    required super.child,
  }) : super(notifier: controller);
  static SeasonThemeController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SiteSeasonScope>()?.notifier;
}

class SeasonalArt {
  const SeasonalArt(this.season);
  final SiteSeason season;
  String get _folder => 'assets/images/seasons/${season.name}-v1';
  String background(bool dark) => season == SiteSeason.spring
      ? 'assets/images/sakura/${dark ? 'moonlit-shrine' : 'moonwhite-lake'}.webp'
      : '$_folder/background-${dark ? 'dark' : 'light'}.webp';
  String get hero => season == SiteSeason.spring
      ? 'assets/images/sakura/yachiyo-lake.webp'
      : '$_folder/hero-scene.webp';
  String get article => season == SiteSeason.spring
      ? 'assets/images/sakura/moonlit-shrine.webp'
      : '$_folder/${season == SiteSeason.summer ? 'sparkler-cover' : 'article-cover'}.webp';
  String get gallery => season == SiteSeason.spring
      ? 'assets/images/sakura/yachiyo-portrait.webp'
      : background(false);
  String get pixel => season == SiteSeason.spring
      ? 'assets/images/sakura/sakura-station.webp'
      : '$_folder/pixel-workshop.webp';
  String room(bool day) =>
      'assets/images/room/lakeside-v1/${season.name}-${day ? 'day' : 'night'}.webp';
}
