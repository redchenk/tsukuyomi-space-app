import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import 'room_controller.dart';

class MusicLibrary extends ChangeNotifier with WidgetsBindingObserver {
  MusicLibrary(this.c, {required this.useLocal, required this.playTracks}) {
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_accountChanged);
    _owner = identity;
    _restoring = _restoreCookie();
  }
  final RoomController c;
  final VoidCallback useLocal;
  final Future<void> Function(Map<String, dynamic>, List<Map<String, dynamic>>)
  playTracks;
  Map<String, dynamic>? profile, qr, playlist;
  List<Map<String, dynamic>> results = [], playlists = [];
  String query = '', view = 'search', error = '', qrStatus = '';
  bool enabled = true,
      busy = false,
      more = false,
      _open = false,
      _disposed = false;
  int offset = 0, total = 0, _epoch = 0, _browse = 0;
  Timer? _timer;
  late String _owner;
  Future<void> _writes = Future.value();
  Future<void> _restoring = Future.value();
  String get identity =>
      '${c.scope}:${c.sessionExpired}:${c.site is SiteClient ? (c.site as SiteClient).sessionRevision : c.site.cookie}';
  String get _key =>
      'music-session:${endpointUri(c.settings.siteUrl).origin}:${c.sessionExpired ? 'guest' : c.account?.id ?? 'guest'}';
  bool get _visible =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _restoreCookie() async {
    final api = c.site;
    if (api is! SiteClient) return;
    final owner = _owner, key = _key, site = c.settings.siteUrl;
    api.setMusicSession(site, null);
    api.onMusicCookie = (origin, value) {
      if (_disposed || owner != _owner || origin != endpointUri(site).origin) {
        return;
      }
      _writes = _writes.then((_) async {
        try {
          await c.storage.writeSecret(key, value);
        } catch (_) {}
      });
    };
    try {
      await _writes;
      final value = await c.storage.readSecret(key);
      if (!_disposed && owner == _owner) api.setMusicSession(site, value);
    } catch (_) {}
  }

  void _accountChanged() {
    if (identity == _owner) return;
    _owner = identity;
    _epoch++;
    _browse++;
    _timer?.cancel();
    profile = qr = playlist = null;
    results = [];
    playlists = [];
    busy = false;
    error = '';
    qrStatus = '';
    useLocal();
    changed();
    _restoring = _restoreCookie();
    if (_open) unawaited(refresh());
  }

  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    await _restoring;
    final owner = _owner, epoch = _epoch;
    final api = c.site;
    if (api is! SiteDataService) throw const ApiFailure('站点接口不可用');
    final data = await (api as SiteDataService)
        .request(c.settings.siteUrl, method, '/api/music$path', body)
        .timeout(const Duration(seconds: 15));
    if (_disposed ||
        owner != _owner ||
        (path.startsWith('/qr') && epoch != _epoch)) {
      throw const ApiFailure('账号已切换，请重试');
    }
    return data;
  }

  void failed(Object failure) {
    error = failure is ApiFailure ? failure.message : '音乐服务暂时不可用，可以继续听网站曲目';
    if (failure is ApiFailure && failure.status == 401) {
      profile = null;
      results = [];
      playlists = [];
      useLocal();
    }
    changed();
  }

  void setOpen(bool value) {
    _open = value;
    _timer?.cancel();
    if (value) {
      unawaited(refresh());
      _schedule();
    } else {
      cancelQr();
      _browse++;
    }
  }

  Future<void> refresh() async {
    final epoch = _epoch;
    try {
      final data = await request('/status');
      if (!_open || epoch != _epoch) return;
      if (profile?['id'] != (data['profile'] as Map?)?['id']) {
        results = [];
        playlists = [];
        playlist = null;
        _browse++;
      }
      profile = data['profile'] is Map
          ? Map<String, dynamic>.from(data['profile'])
          : null;
      enabled = data['enabled'] == true;
      if (profile == null) useLocal();
      changed();
    } catch (e) {
      if (_open && epoch == _epoch) failed(e);
    }
  }

  void _schedule([int seconds = 3]) {
    _timer?.cancel();
    if (_open && qr != null && _visible && !_disposed) {
      _timer = Timer(Duration(seconds: seconds), () => unawaited(poll()));
    }
  }

  Future<void> login() async {
    if (busy) return;
    _timer?.cancel();
    _epoch++;
    busy = true;
    error = '';
    qr = null;
    qrStatus = '';
    final epoch = _epoch;
    changed();
    try {
      final data = await request('/qr', method: 'POST', body: {});
      if (epoch != _epoch || !_open) return;
      final url = Uri.tryParse('${data['url']}');
      if (url == null ||
          url.scheme != 'https' ||
          url.host != 'music.163.com' ||
          url.path != '/login') {
        throw const ApiFailure('扫码地址无效');
      }
      qr = data;
      qrStatus = 'waiting';
      _schedule();
    } catch (e) {
      if (epoch == _epoch) failed(e);
    } finally {
      if (epoch == _epoch) {
        busy = false;
        changed();
      }
    }
  }

  Future<void> poll() async {
    if (!_open || qr == null || !_visible) return;
    if (DateTime.now().millisecondsSinceEpoch >=
        (qr!['expiresAt'] as num? ?? 0)) {
      qrStatus = 'expired';
      changed();
      return;
    }
    final epoch = _epoch;
    try {
      final data = await request(
        '/qr/check',
        method: 'POST',
        body: {'qrId': qr!['qrId']},
      );
      if (epoch != _epoch || !_open || !_visible) return;
      qrStatus = '${data['status']}';
      error = '';
      if (qrStatus == 'authorized') {
        profile = Map<String, dynamic>.from(data['profile'] as Map);
        qr = null;
        _timer?.cancel();
        unawaited(browse('playlists'));
      } else if (qrStatus != 'expired') {
        _schedule();
      }
      changed();
    } catch (e) {
      if (epoch == _epoch && _open && _visible) {
        failed(e);
        _schedule(6);
      }
    }
  }

  void cancelQr() {
    if (c.site is SiteClient) (c.site as SiteClient).cancelMusicRequests();
    _epoch++;
    _timer?.cancel();
    qr = null;
    qrStatus = '';
    busy = false;
    changed();
  }

  Future<void> logout() async {
    cancelQr();
    busy = true;
    final epoch = _epoch;
    changed();
    try {
      await request('/logout', method: 'POST', body: {});
      if (epoch != _epoch) return;
      profile = playlist = null;
      results = [];
      playlists = [];
      useLocal();
    } catch (e) {
      if (epoch == _epoch) failed(e);
    } finally {
      if (epoch == _epoch) {
        busy = false;
        changed();
      }
    }
  }

  Future<void> browse(
    String nextView, {
    int page = 0,
    Map<String, dynamic>? selectedPlaylist,
  }) async {
    if (busy || profile == null) return;
    if (nextView == 'search' && (query.trim().isEmpty || query.length > 100)) {
      error = '请输入 1–100 个字的歌名或歌手';
      changed();
      return;
    }
    final epoch = ++_browse;
    busy = true;
    error = '';
    changed();
    try {
      final path = nextView == 'playlists'
          ? '/playlists'
          : nextView == 'playlist'
          ? '/playlists/${Uri.encodeComponent('${selectedPlaylist?['id'] ?? playlist?['id']}')}'
          : '/search?q=${Uri.encodeQueryComponent(query.trim())}';
      final data = await request(
        '$path${path.contains('?') ? '&' : '?'}offset=${page.clamp(0, 10000)}',
      );
      if (epoch != _browse) return;
      view = nextView;
      playlist = selectedPlaylist ?? playlist;
      offset = page;
      results = _rows(data['tracks']);
      playlists = _rows(data['playlists']);
      total = (data['total'] as num? ?? 0).toInt();
      more = data['more'] == true || offset + results.length < total;
    } catch (e) {
      if (epoch == _browse) failed(e);
    } finally {
      if (epoch == _browse) {
        busy = false;
        changed();
      }
    }
  }

  Future<void> play(Map<String, dynamic> track) async {
    error = '';
    changed();
    try {
      await playTracks(track, List.of(results));
    } catch (e) {
      failed(e);
    }
  }

  static List<Map<String, dynamic>> _rows(dynamic value) => value is List
      ? value.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
      : [];
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _timer?.cancel();
    if (_visible) _schedule();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _browse++;
    _timer?.cancel();
    c.removeListener(_accountChanged);
    WidgetsBinding.instance.removeObserver(this);
    if (c.site is SiteClient) (c.site as SiteClient).onMusicCookie = null;
    super.dispose();
  }
}
