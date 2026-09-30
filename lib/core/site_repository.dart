import 'dart:convert';

import 'models.dart';
import 'site_client.dart';
import 'storage.dart';

class SiteDocument {
  const SiteDocument(this.payload, {this.cached = false, this.notice = ''});
  final Map<String, dynamic> payload;
  final bool cached;
  final String notice;
  dynamic get data => payload['data'];
}

/// Website contracts, with disk snapshots partitioned by origin AND account.
/// Mutations are never blindly retried: plaza posts are not idempotent on the server.
class SiteRepository {
  SiteRepository({
    required this.api,
    required this.storage,
    required this.site,
    required this.accountId,
  });
  final SiteDataService api;
  final RoomStorage storage;
  final String Function() site;
  final String? Function() accountId;
  int? get _sessionRevision =>
      api is SiteClient ? (api as SiteClient).sessionRevision : null;
  String get scope => '${endpointUri(site()).origin}:${accountId() ?? 'guest'}';
  final Map<String, Future<SiteDocument>> _inFlight = {};
  Future<SiteDocument?> cached(String path, {bool private = false}) async {
    if (private && accountId() == null) return null;
    final owner = scope;
    try {
      final saved = await storage.draft('site-cache:$owner:$path');
      if (saved.isEmpty || scope != owner) return null;
      return SiteDocument(
        Map<String, dynamic>.from(jsonDecode(saved) as Map),
        cached: true,
        notice: '正在同步，显示上次保存的内容',
      );
    } catch (_) {
      return null;
    }
  }

  Future<SiteDocument> read(String path, {bool private = false}) {
    final key = '$scope:${_sessionRevision ?? ''}:$path';
    return _inFlight.putIfAbsent(
      key,
      () => _read(path, private: private).whenComplete(() {
        _inFlight.remove(key);
      }),
    );
  }

  Future<SiteDocument> _read(String path, {required bool private}) async {
    final owner = scope, origin = site();
    final revision = _sessionRevision;
    void requireOwner() {
      if (scope != owner || revision != _sessionRevision) {
        throw const ApiFailure('登录身份或站点已切换，请重新加载', status: 409);
      }
    }

    final key = 'site-cache:$owner:$path';
    if (private && accountId() == null) {
      throw const ApiFailure('请先登录', status: 401);
    }
    try {
      // Use the same live-content routes as the website to avoid stale CDN data.
      var live = path;
      if (RegExp(r'^/api/(articles|messages)([/?]|$)').hasMatch(path)) {
        live =
            '/api/live/${DateTime.now().microsecondsSinceEpoch}${path.substring(4)}';
      }
      Map<String, dynamic>? data;
      for (var attempt = 0; attempt < 2; attempt++) {
        // A retry must not use the old URL with a newly restored session.
        requireOwner();
        try {
          data = await api.request(origin, 'GET', live);
          break;
        } on ApiFailure catch (e) {
          if (attempt > 0 || (e.status != null && e.status! < 500)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
      requireOwner();
      await storage.saveDraft(key, jsonEncode(data));
      requireOwner();
      return SiteDocument(data!);
    } on ApiFailure catch (e) {
      if (scope != owner ||
          revision != _sessionRevision ||
          e.status == 404 ||
          e.status == 409 ||
          e.status == 403) {
        rethrow;
      }
      final saved = await storage.draft(key);
      requireOwner();
      if (saved.isEmpty) rethrow;
      return SiteDocument(
        Map<String, dynamic>.from(jsonDecode(saved) as Map),
        cached: true,
        notice: e.status == 401 ? '登录已过期，当前显示上次同步内容' : '网络暂不可用，当前显示离线缓存',
      );
    }
  }

  Future<Map<String, dynamic>> write(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (accountId() == null) throw const ApiFailure('请先登录', status: 401);
    final owner = scope;
    final result = await api.request(site(), method, path, body);
    if (scope != owner) throw const ApiFailure('账号已切换，请重新加载', status: 409);
    return result;
  }
}
