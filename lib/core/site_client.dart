import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

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

class SiteClient implements SiteService, SiteDataService {
  SiteClient({http.Client? client, this.timeout = const Duration(seconds: 25)})
    : _client = client ?? http.Client();
  final http.Client _client;
  final Duration timeout;
  String? _cookie;
  final readerCookies = <String, String>{};
  void Function(String origin, String value)? onReaderCookie;
  int _revision = 0;
  void Function()? onUnauthorized;
  @override
  String? get cookie => _cookie;
  @override
  set cookie(String? value) {
    _cookie = value;
    _revision++;
  }

  @override
  void dispose() => _client.close();

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
    final revision = _revision;
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
            if (cookie != null || readerCookies.containsKey(base.origin))
              'Cookie': [
                ?cookie,
                if (readerCookies.containsKey(base.origin))
                  readerCookies[base.origin]!,
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
      })().timeout(timeout);
      // A late response must never replace another account's cookie or data.
      if (revision != _revision) {
        throw const ApiFailure('账号已切换，请重试', status: 409);
      }
      if (response.statusCode == 401) onUnauthorized?.call();
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
      final session = RegExp(r'(?:^|,\s*)tsukuyomi_session=([^;,\s]*)')
          .firstMatch(response.headers['set-cookie'] ?? '');
      if (session != null) {
        _cookie = session.group(1)!.isEmpty
            ? null
            : 'tsukuyomi_session=${session.group(1)}';
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
    return Account('${user['id']}', '${user['username']}');
  }

  Future<Account> authenticate(
    String site,
    Map<String, dynamic> body, {
    String path = '/api/auth/login',
  }) async {
    cookie = null;
    final account = _account(await _data(site, 'POST', path, body));
    if (cookie == null) throw const ApiFailure('站点未返回会话，请检查服务地址');
    return account;
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
    }
    return grouped.values
        .where((r) => r['assistant'] is String)
        .map(
          (r) => ChatTurn(
            id: r['id'],
            user: r['user'] as String? ?? '',
            assistant: r['assistant'],
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
      'memoryEnabled': true,
      if (turn.user.isEmpty) 'opener': true,
    });
  }
}
