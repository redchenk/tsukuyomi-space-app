import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'room_events.dart';

abstract interface class SiteService {
  String? get cookie;
  set cookie(String? value);
  Future<Account> login(String site, String username, String password);
  Future<Account> me(String site);
  Future<void> logout(String site);
  Future<List<ChatTurn>> history(String site);
  Future<void> saveTurn(String site, ChatTurn turn);
  void dispose();
}

abstract interface class SiteDataService {
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]);
}

class SiteClient implements SiteService, SiteDataService, SiteRoomEventService {
  SiteClient({http.Client? client, this.timeout = const Duration(seconds: 25)})
    : _client = client ?? http.Client();
  final http.Client _client;
  final Duration timeout;
  String? _cookie;
  String? _cookieOrigin;
  final readerCookies = <String, String>{};
  final visitorCookies = <String, String>{};
  void Function(String origin, String value)? onReaderCookie;
  void Function(String origin, String? value)? onVisitorCookie;
  void Function(String origin, String? value)? onSessionCookie;
  int _revision = 0, _musicEpoch = 0;
  String? _musicCookie, _musicOrigin;
  void Function(String origin, String? value)? onMusicCookie;
  void cancelMusicRequests() {
    _musicEpoch++;
  }

  void setMusicSession(String site, String? value) {
    _musicEpoch++;
    _musicOrigin = endpointUri(site).origin;
    _musicCookie =
        value != null &&
            RegExp(r'^tsukuyomi_music=[a-f0-9]{64}$').hasMatch(value)
        ? value
        : null;
  }

  /// Identity epoch, including logout/relogin even when the account ID is the same.
  int get sessionRevision => _revision;
  bool _disposed = false;
  void Function()? onUnauthorized;
  @override
  String? get cookie => _cookie;
  @override
  set cookie(String? value) {
    _cookie = value;
    if (value == null) _cookieOrigin = null;
    _revision++;
  }

  /// Restore a persisted or OAuth session together with the site that issued it.
  void setSessionCookie(String site, String? value) {
    _cookie = value;
    _cookieOrigin = value == null ? null : endpointUri(site).origin;
    _revision++;
  }

  String? _cookieFor(String origin) {
    if (_cookie == null) return null;
    // Legacy callers can supply a cookie before their first request. Once its
    // owner is known it must never be sent to another service.
    _cookieOrigin ??= origin;
    if (_cookieOrigin != origin) {
      throw const ApiFailure('登录会话与站点不匹配，请重新登录', status: 409);
    }
    return _cookie;
  }

  @override
  void dispose() {
    _disposed = true;
    _client.close();
  }

  @override
  Stream<RoomServerEvent> roomEvents(String site) async* {
    if (_disposed) return;
    final base = endpointUri(site), revision = _revision;
    final sessionCookie = _cookieFor(base.origin);
    final abort = Completer<void>();
    final request =
        http.AbortableRequest(
            'GET',
            base.resolve('/api/room/memory/events'),
            abortTrigger: abort.future,
          )
          ..followRedirects = false
          ..headers.addAll({
            'Accept': 'text/event-stream',
            'Origin': base.origin,
            'Cache-Control': 'no-cache',
            'Cookie': ?sessionCookie,
          });
    try {
      final response = await _client.send(request).timeout(timeout);
      if (response.statusCode == 401 && !_disposed && revision == _revision) {
        onUnauthorized?.call();
      }
      if (response.statusCode != 200 ||
          !(response.headers['content-type'] ?? '').startsWith(
            'text/event-stream',
          )) {
        throw ApiFailure('实时连接暂不可用', status: response.statusCode);
      }
      await for (final event in decodeRoomEvents(
        response.stream.timeout(const Duration(seconds: 55)),
      )) {
        if (revision != _revision) return;
        yield event;
      }
    } catch (_) {
      // Closing the app or replacing the session can close the socket before
      // stream cancellation finishes. That connection no longer has an owner.
      if (!_disposed && revision == _revision) rethrow;
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final base = endpointUri(site);
    final target = base.resolve(path);
    if (target.origin != base.origin || !target.path.startsWith('/api/')) {
      throw const ApiFailure('无效的站点接口地址');
    }
    final revision = _revision, musicEpoch = _musicEpoch;
    final musicRequest = target.path.startsWith('/api/music/');
    final musicLoginRequest = target.path.startsWith('/api/music/qr');
    final sessionCookie = _cookieFor(base.origin);
    final abort = Completer<void>();
    final req =
        http.AbortableRequest(method, target, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers.addAll({
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Origin': base.origin,
            'X-Requested-With': 'XMLHttpRequest',
            'Cache-Control': 'no-cache',
            if (sessionCookie != null ||
                readerCookies.containsKey(base.origin) ||
                visitorCookies.containsKey(base.origin) ||
                (musicRequest &&
                    _musicOrigin == base.origin &&
                    _musicCookie != null))
              'Cookie': [
                ?sessionCookie,
                if (musicRequest && _musicOrigin == base.origin) ?_musicCookie,
                if (readerCookies.containsKey(base.origin))
                  readerCookies[base.origin]!,
                if (visitorCookies.containsKey(base.origin))
                  visitorCookies[base.origin]!,
              ].join('; '),
          });
    if (body != null) req.body = jsonEncode(body);
    try {
      final response = await (() async {
        final stream = await _client.send(req);
        final bytes = <int>[];
        await for (final chunk in stream.stream) {
          bytes.addAll(chunk);
          if (bytes.length > 12 * 1024 * 1024) {
            throw const ApiFailure('站点响应过大');
          }
        }
        return http.Response.bytes(
          bytes,
          stream.statusCode,
          headers: stream.headers,
        );
      })().timeout(musicRequest ? const Duration(seconds: 15) : timeout);
      // Visitor identity belongs to the browser installation, independently of
      // login. Preserve a late visitor Set-Cookie even if its account changed.
      final visitor = RegExp(r'(?:^|,\s*)tsukuyomi_visitor=([^;,\s]*)')
          .firstMatch(response.headers['set-cookie'] ?? '');
      if (visitor != null) {
        final id = visitor.group(1)!;
        if (id.isEmpty || RegExp(r'^[A-Za-z0-9_-]{20,128}$').hasMatch(id)) {
          final value = id.isEmpty ? null : 'tsukuyomi_visitor=$id';
          if (value == null) {
            visitorCookies.remove(base.origin);
          } else {
            visitorCookies[base.origin] = value;
          }
          onVisitorCookie?.call(base.origin, value);
        }
      }
      // A late response must never replace another account's cookie or data.
      if (revision != _revision ||
          (musicLoginRequest && musicEpoch != _musicEpoch)) {
        throw const ApiFailure('账号已切换，请重试', status: 409);
      }
      if (response.statusCode == 401 &&
          !target.path.startsWith('/api/admin/') &&
          !musicRequest &&
          !{
            '/api/auth/login',
            '/api/auth/register',
            '/api/auth/password/reset',
          }.contains(target.path)) {
        onUnauthorized?.call();
      }
      if (musicRequest) {
        final token = RegExp(r'(?:^|,\s*)tsukuyomi_music=([a-f0-9]*)(?:;|$)')
            .firstMatch(response.headers['set-cookie'] ?? '');
        if (token != null &&
            (token.group(1)!.isEmpty || token.group(1)!.length == 64)) {
          _musicCookie = token.group(1)!.isEmpty
              ? null
              : 'tsukuyomi_music=${token.group(1)}';
          _musicOrigin = base.origin;
          onMusicCookie?.call(base.origin, _musicCookie);
        }
      }
      Map<String, dynamic> json;
      try {
        json = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(response.bodyBytes)) as Map,
        );
      } catch (_) {
        throw ApiFailure(
          '站点响应异常（HTTP ${response.statusCode}）',
          status: response.statusCode,
        );
      }
      if (response.statusCode >= 300 || json['success'] != true) {
        throw ApiFailure(
          json['message'] is String ? json['message'] : '站点请求失败',
          status: response.statusCode,
        );
      }
      final setCookie = response.headers['set-cookie'] ?? '';
      final sessions = RegExp(
        r'(?:^|,\s*)(tsukuyomi_session|tsukuyomi_admin_session)=([^;,\s]*)',
      ).allMatches(setCookie);
      if (sessions.isNotEmpty) {
        final saved = <String, String>{};
        for (final part in (_cookie ?? '').split(';')) {
          final pair = part.trim().split('=');
          if (pair.length == 2 &&
              {
                'tsukuyomi_session',
                'tsukuyomi_admin_session',
              }.contains(pair[0])) {
            saved[pair[0]] = pair[1];
          }
        }
        for (final session in sessions) {
          final name = session.group(1)!;
          final value = session.group(2)!;
          if (value.isEmpty) {
            saved.remove(name);
          } else {
            saved[name] = value;
          }
        }
        final nextCookie = saved.isEmpty
            ? null
            : saved.entries
                  .map((entry) => '${entry.key}=${entry.value}')
                  .join('; ');
        _cookie = nextCookie;
        _cookieOrigin = nextCookie == null ? null : base.origin;
        onSessionCookie?.call(base.origin, _cookie);
      }
      final reader = RegExp(r'(?:^|,\s*)tsukuyomi_reader=([^;,\s]+)')
          .firstMatch(response.headers['set-cookie'] ?? '');
      if (reader != null) {
        final value = 'tsukuyomi_reader=${reader.group(1)}';
        readerCookies[base.origin] = value;
        onReaderCookie?.call(base.origin, value);
      }
      return json;
    } on TimeoutException {
      throw const ApiFailure('连接超时，请检查网络后重试');
    } on http.ClientException {
      throw const ApiFailure('无法连接月读空间，已保留本机内容');
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<dynamic> _data(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async => (await request(site, method, path, body))['data'];
  Account _account(dynamic data) {
    final user = data['user'] ?? data;
    return Account(
      '${user['id']}',
      '${user['username']}',
      role: '${user['role'] ?? 'user'}',
      scope: user['scope'] == 'admin' ? 'admin' : 'user',
      nickname: '${user['nickname'] ?? ''}',
      avatar: '${user['avatar'] ?? ''}',
    );
  }

  Future<Account> authenticate(
    String site,
    Map<String, dynamic> body, {
    String path = '/api/auth/login',
  }) async {
    final previousCookie = cookie, previousOrigin = _cookieOrigin;
    cookie = null;
    try {
      final account = _account(await _data(site, 'POST', path, body));
      if (cookie == null) throw const ApiFailure('站点未返回会话，请检查服务地址');
      return account;
    } catch (_) {
      cookie = previousCookie;
      _cookieOrigin = previousOrigin;
      rethrow;
    }
  }

  @override
  Future<Account> login(String site, String username, String password) =>
      authenticate(site, {'username': username, 'password': password});
  @override
  Future<Account> me(String site) async =>
      _account(await _data(site, 'GET', '/api/auth/me'));
  @override
  Future<void> logout(String site) async {
    await _data(site, 'POST', '/api/auth/logout');
    cookie = null;
  }

  @override
  Future<List<ChatTurn>> history(String site) async {
    final rows = await _data(site, 'GET', '/api/room/chat?limit=100') as List;
    final grouped = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final id = '${row['turnId'] ?? row['id']}';
      (grouped[id] ??= {
        'id': id,
        'createdAt': row['createdAt'],
      })['${row['role']}'] = row['content'];
      if (row['image'] is Map) grouped[id]!['image'] = row['image'];
    }
    return grouped.values
        .where((r) => r['assistant'] is String)
        .map(
          (r) => ChatTurn(
            id: r['id'],
            user: r['user'] as String? ?? '',
            assistant: r['assistant'],
            image: r['image'] is Map
                ? Map<String, dynamic>.from(r['image'])
                : null,
            createdAt:
                DateTime.tryParse('${r['createdAt'] ?? ''}') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ),
        )
        .toList();
  }

  @override
  Future<void> saveTurn(String site, ChatTurn turn) async {
    await _data(site, 'POST', '/api/room/chat/turn', {
      'turnId': turn.id,
      'userMessage': turn.user,
      'assistantMessage': turn.assistant,
      'memoryEnabled': turn.memorySource != 'local' && turn.memoryEnabled,
      if (turn.memorySource == 'local') 'memorySource': 'local',
      if (turn.image?['id'] != null) 'imageId': turn.image!['id'],
      if (turn.user.isEmpty) 'opener': true,
    });
  }
}
