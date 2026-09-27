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

class SiteClient implements SiteService {
  SiteClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  @override
  String? cookie;
  @override
  void dispose() => _client.close();
  Future<dynamic> _request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final base = endpointUri(site);
    final request = http.Request(method, base.resolve(path))
      ..followRedirects = false;
    request.headers.addAll({
      'Accept': 'application/json', 'Content-Type': 'application/json',
      // Compatibility with the existing site's trusted-write middleware.
      'Origin': base.origin,
      'X-Requested-With': 'XMLHttpRequest',
      'Cookie': ?cookie,
    });
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(await _client.send(request))
        .timeout(const Duration(seconds: 25));
    Map<String, dynamic> json;
    try {
      json =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ApiFailure(
        '站点返回了非 JSON 响应（HTTP ${response.statusCode}）',
        status: response.statusCode,
      );
    }
    if (response.statusCode >= 300 || json['success'] != true) {
      throw ApiFailure(
        json['message'] is String ? json['message'] as String : '站点请求失败',
        status: response.statusCode,
      );
    }
    final session = RegExp(r'(?:^|,\s*)tsukuyomi_session=([^;,\s]+)')
        .firstMatch(response.headers['set-cookie'] ?? '');
    if (session != null) cookie = 'tsukuyomi_session=${session.group(1)}';
    return json['data'];
  }

  Account _account(dynamic data) {
    final user = data['user'] ?? data;
    return Account(user['id'] as String, user['username'] as String);
  }

  @override
  Future<Account> login(String site, String username, String password) async {
    cookie = null;
    final account = _account(
      await _request(site, 'POST', '/api/auth/login', {
        'username': username,
        'password': password,
      }),
    );
    if (cookie == null) throw const ApiFailure('站点未返回会话，请检查服务地址');
    return account;
  }

  @override
  Future<Account> me(String site) async =>
      _account(await _request(site, 'GET', '/api/auth/me'));
  @override
  Future<void> logout(String site) async {
    await _request(site, 'POST', '/api/auth/logout');
    cookie = null;
  }

  @override
  Future<List<ChatTurn>> history(String site) async {
    final rows =
        await _request(site, 'GET', '/api/room/chat?limit=100') as List;
    final grouped = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final id = row['turnId'] as String;
      (grouped[id] ??= {
        'id': id,
        'createdAt': row['createdAt'],
      })[row['role'] as String] = row['content'];
    }
    return grouped.values
        .where((r) => r['user'] is String && r['assistant'] is String)
        .map(
          (r) => ChatTurn(
            id: r['id'] as String,
            user: r['user'] as String,
            assistant: r['assistant'] as String,
            createdAt:
                DateTime.tryParse(r['createdAt'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ),
        )
        .toList();
  }

  @override
  Future<void> saveTurn(String site, ChatTurn turn) async {
    await _request(site, 'POST', '/api/room/chat/turn', {
      'turnId': turn.id,
      'userMessage': turn.user,
      'assistantMessage': turn.assistant,
      'memoryEnabled': true,
    });
  }
}
