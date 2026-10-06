import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../room/room_controller.dart';
import '../site/site_widgets.dart' show mapOf, rowsOf;

class GameSession extends ChangeNotifier {
  GameSession(this.controller, {DateTime Function()? now})
    : now = now ?? DateTime.now {
    _scope = accountScope;
    controller.addListener(_accountChanged);
  }
  final RoomController controller;
  final DateTime Function() now;
  int score = 0, best = 0, rank = 0, page = 1, totalPages = 1;
  int _pending = 0, _submitted = 0, _refresh = 0, _preferencesRevision = 0;
  DateTime? _savedAt;
  bool loading = false, saving = false, muted = false, touchControls = false;
  double volume = 1;
  String error = '', saveError = '';
  List<Map<String, dynamic>> entries = [];
  late String _scope;
  bool _disposed = false;
  Timer? _saveTimer;
  Future<void> _storageQueue = Future.value();
  String get accountScope =>
      '${endpointUri(controller.settings.siteUrl).origin}:${controller.sessionExpired ? 'guest' : controller.account?.id ?? 'guest'}';
  bool get authenticated =>
      controller.account != null && !controller.sessionExpired;
  String get _bestKey => 'kaguya-best:$_scope';
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    final revision = _preferencesRevision;
    try {
      final prefs = await controller.storage.draft('kaguya-settings');
      if (!_disposed && revision == _preferencesRevision && prefs.isNotEmpty) {
        final data = mapOf(jsonDecode(prefs));
        muted = data['muted'] == true;
        touchControls = data['touchControls'] == true;
        volume =
            (data['volume'] is num ? (data['volume'] as num).toDouble() : 1.0)
                .clamp(0, 1);
      }
    } catch (_) {
      // Preferences must never prevent the bundled game from running.
    }
    await _restoreBest();
    _changed();
    await refreshLeaderboard();
  }

  Future<void> _restoreBest() async {
    final owner = _scope;
    try {
      final stored = await controller.storage.draft(_bestKey);
      if (!_disposed && owner == _scope) {
        best = (int.tryParse(stored) ?? 0).clamp(best, 9007199254740991);
      }
    } catch (_) {}
  }

  void _accountChanged() {
    if (_scope == accountScope) return;
    _saveTimer?.cancel();
    _scope = accountScope;
    _refresh++;
    _pending = _submitted = score = best = rank = 0;
    page = totalPages = 1;
    _savedAt = null;
    saving = false;
    entries = [];
    error = saveError = '';
    unawaited(_restoreBest().then((_) => refreshLeaderboard()));
    _changed();
  }

  void configure({double? gain, bool? mute, bool? controls}) {
    _preferencesRevision++;
    if (gain != null) volume = gain.clamp(0, 1);
    if (mute != null) muted = mute;
    if (controls != null) touchControls = controls;
    final value = jsonEncode({
      'volume': volume,
      'muted': muted,
      'touchControls': touchControls,
    });
    _persist('kaguya-settings', value);
    _changed();
  }

  void _persist(String key, String value) {
    _storageQueue = _storageQueue.then((_) async {
      try {
        await controller.storage.saveDraft(key, value);
      } catch (_) {}
    });
  }

  void updateScore(int value) {
    if (_disposed || value < 0 || value > 9007199254740991) return;
    final changed = score != value;
    score = value;
    if (value > best) {
      best = value;
      _persist(_bestKey, '$best');
    }
    if (value > _pending) _pending = value;
    if (authenticated && _pending > _submitted) {
      final elapsed = _savedAt == null
          ? const Duration(seconds: 15)
          : now().difference(_savedAt!);
      final threshold =
          (_submitted < 100 && value >= 100) || value - _submitted >= 250;
      if (threshold && elapsed >= const Duration(seconds: 15)) {
        unawaited(flushScore());
      } else {
        _schedule(
          const Duration(seconds: 15) - elapsed < Duration.zero
              ? const Duration(seconds: 15)
              : const Duration(seconds: 15) - elapsed,
        );
      }
    }
    if (changed) _changed();
  }

  void _schedule(Duration delay) {
    if (_disposed ||
        _saveTimer?.isActive == true ||
        saving ||
        !authenticated ||
        _pending <= _submitted) {
      return;
    }
    _saveTimer = Timer(delay, () => unawaited(flushScore()));
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final api = controller.site;
    if (api is! SiteDataService) throw const ApiFailure('站点接口不可用');
    final owner = _scope;
    final data = await (api as SiteDataService)
        .request(controller.settings.siteUrl, method, path, body)
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw const ApiFailure('游戏积分请求超时，请重试'),
        );
    if (_disposed || owner != _scope) throw const ApiFailure('账号已切换');
    return mapOf(data['data']);
  }

  Future<void> refreshLeaderboard({int? targetPage}) async {
    final ticket = ++_refresh;
    final requested = (targetPage ?? page).clamp(1, 100000);
    loading = true;
    error = '';
    _changed();
    try {
      final data = await _request(
        'GET',
        '/api/growth/game/leaderboard?page=$requested&limit=50',
      );
      if (ticket != _refresh || _disposed) return;
      entries = rowsOf(data['entries']);
      page = (data['page'] as num? ?? requested).toInt();
      totalPages = (data['totalPages'] as num? ?? 1).toInt().clamp(1, 100000);
      _applyCurrent(mapOf(data['current']));
    } catch (e) {
      if (ticket == _refresh && !_disposed) {
        error = e is ApiFailure ? e.message : '积分榜暂时无法加载';
      }
    } finally {
      if (ticket == _refresh && !_disposed) {
        loading = false;
        _changed();
      }
    }
  }

  void _applyCurrent(Map<String, dynamic> current) {
    final remote = (current['score'] as num? ?? 0).toInt();
    if (remote > best) {
      best = remote;
      _persist(_bestKey, '$best');
    }
    rank = (current['rank'] as num? ?? 0).toInt();
  }

  Future<void> flushScore() async {
    if (_disposed || !authenticated || saving || _pending <= _submitted) return;
    _saveTimer?.cancel();
    final owner = _scope, pending = _pending;
    saving = true;
    _savedAt = now();
    _changed();
    try {
      final data = await _request('POST', '/api/growth/game/score', {
        'score': pending,
      });
      if (owner != _scope || _disposed) return;
      _submitted = pending;
      _applyCurrent(mapOf(data['current']));
      saveError = '';
    } catch (e) {
      if (owner == _scope && !_disposed) {
        saveError = e is ApiFailure ? e.message : '成绩暂未同步';
      }
    } finally {
      if (owner == _scope && !_disposed) {
        saving = false;
        if (_pending > _submitted) _schedule(const Duration(seconds: 15));
        _changed();
      }
    }
  }

  @override
  void dispose() {
    unawaited(flushScore());
    _disposed = true;
    _saveTimer?.cancel();
    controller.removeListener(_accountChanged);
    super.dispose();
  }
}
