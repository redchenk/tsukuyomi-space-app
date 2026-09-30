import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../room/room_controller.dart';
import '../site/site_widgets.dart' show mapOf, rowsOf;
import 'pixel_document.dart';

class PixelSession extends ChangeNotifier {
  PixelSession(this.controller) {
    _scope = _accountScope;
    controller.addListener(_accountChanged);
    document.addListener(_documentChanged);
  }
  final RoomController controller;
  final document = PixelDocument();
  String title = '', description = '', sort = 'latest', error = '', notice = '';
  String? editingId;
  List<Map<String, dynamic>> artworks = [];
  bool loading = false, working = false, ownOnly = false;
  int page = 1, total = 0, _request = 0;
  int get totalPages => (total / 12).ceil().clamp(1, 100000);
  bool _disposed = false, _restoring = false;
  late String _scope;
  String get _accountScope =>
      '${endpointUri(controller.settings.siteUrl).origin}:${controller.sessionExpired ? 'guest' : controller.account?.id ?? 'guest'}';
  Timer? _draftTimer;
  Future<void> _saveQueue = Future.value();
  String get draftKey => 'pixel-draft:$_scope';
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize(String path) async {
    await restoreDraft();
    if (_disposed) return;
    await loadGallery();
    final edit = Uri.parse(path).queryParameters['edit'];
    if (edit != null && edit.isNotEmpty) await editArtwork(edit);
  }

  void _accountChanged() {
    if (_scope == _accountScope) return;
    unawaited(saveDraft());
    final wasGuest = _scope.endsWith(':guest');
    _scope = _accountScope;
    _request++;
    working = false;
    artworks = [];
    editingId = null;
    ownOnly = false;
    error = '';
    notice = '';
    if (!wasGuest) {
      _restoring = true;
      document.load(
        PixelSnapshot(
          width: 192,
          height: 108,
          pixels: List.filled(192 * 108, -1),
          palette: pixelPresetPalette,
          background: '#ffffff',
        ),
      );
      title = '';
      description = '';
      _restoring = false;
      unawaited(restoreDraft());
    } else {
      unawaited(saveDraft());
    }
    unawaited(loadGallery());
    _changed();
  }

  void _documentChanged() {
    if (!_restoring) {
      _draftTimer?.cancel();
      _draftTimer = Timer(
        const Duration(milliseconds: 350),
        () => unawaited(saveDraft()),
      );
    }
    _changed();
  }

  void updateDetails(String nextTitle, String nextDescription) {
    title = nextTitle;
    description = nextDescription;
    _documentChanged();
  }

  Future<void> restoreDraft() async {
    final owner = _scope, revision = document.revision;
    try {
      final raw = await controller.storage.draft(draftKey);
      if (_disposed ||
          owner != _scope ||
          document.revision != revision ||
          raw.isEmpty) {
        return;
      }
      final data = mapOf(jsonDecode(raw));
      final saved = PixelSnapshot.fromJson(mapOf(data['snapshot']));
      _restoring = true;
      document.load(saved);
      title = '${data['title'] ?? ''}';
      description = '${data['description'] ?? ''}';
      document.brushSize =
          (data['brushSize'] is int ? data['brushSize'] as int : 1).clamp(1, 6);
      editingId = data['editingId'] as String?;
      notice = '已恢复本机画稿';
      _changed();
    } catch (_) {
      if (!_disposed && owner == _scope) notice = '画稿无法读取，可以重新绘制';
    } finally {
      _restoring = false;
    }
  }

  Future<void> saveDraft() {
    _draftTimer?.cancel();
    final key = draftKey;
    final value = jsonEncode({
      'snapshot': document.snapshot.toJson(),
      'title': title,
      'description': description,
      'brushSize': document.brushSize,
      'editingId': editingId,
    });
    _saveQueue = _saveQueue.then((_) async {
      try {
        await controller.storage.saveDraft(key, value);
      } catch (_) {
        if (!_disposed && key == draftKey) {
          notice = '画稿暂未保存，请重试';
          _changed();
        }
      }
    });
    return _saveQueue;
  }

  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final api = controller.site;
    if (api is! SiteDataService) throw const ApiFailure('站点接口不可用');
    if (method != 'GET' &&
        (controller.account == null || controller.sessionExpired)) {
      throw const ApiFailure('请先登录后继续');
    }
    final owner = _scope;
    final result = await (api as SiteDataService).request(
      controller.settings.siteUrl,
      method,
      path,
      body,
    );
    if (_disposed || owner != _scope) throw const ApiFailure('账号已切换，请重试');
    return result;
  }

  Future<void> loadGallery({int? nextPage}) async {
    final ticket = ++_request;
    loading = true;
    error = '';
    _changed();
    final target = (nextPage ?? page).clamp(1, 100000);
    try {
      final result = await request(
        'GET',
        '/api/pixel-art/${ownOnly ? 'manage' : 'gallery'}?sort=$sort&limit=12&offset=${(target - 1) * 12}',
      );
      if (ticket != _request) return;
      artworks = rowsOf(result['data']);
      page = target;
      total =
          (mapOf(result['pagination'])['total'] as num?)?.toInt() ??
          artworks.length;
    } catch (e) {
      if (ticket == _request) error = e is ApiFailure ? e.message : '作品暂时无法读取';
    } finally {
      if (ticket == _request && !_disposed) {
        loading = false;
        _changed();
      }
    }
  }

  Future<Map<String, dynamic>> fullArtwork(String id) async => mapOf(
    (await request('GET', '/api/pixel-art/${Uri.encodeComponent(id)}'))['data'],
  );
  Future<void> editArtwork(String id) async {
    if (controller.account == null || controller.sessionExpired) {
      error = '请登录后编辑作品';
      _changed();
      return;
    }
    await _write(() async {
      final value = mapOf(
        (await request(
          'GET',
          '/api/pixel-art/manage/${Uri.encodeComponent(id)}',
        ))['data'],
      );
      final snapshot = PixelSnapshot.fromJson(value);
      document.load(snapshot);
      editingId = id;
      title = '${value['title'] ?? ''}';
      description = '${value['description'] ?? ''}';
      await saveDraft();
      notice = '已载入作品，可以继续编辑';
    });
  }

  Future<bool> publish() async {
    if (title.trim().isEmpty) {
      error = '请给作品取一个名字';
      _changed();
      return false;
    }
    if (document.paintedCount == 0) {
      error = '画布还是空的，先落下一点月光吧';
      _changed();
      return false;
    }
    var success = false;
    await _write(() async {
      final result = await request(
        editingId == null ? 'POST' : 'PUT',
        '/api/pixel-art${editingId == null ? '' : '/${Uri.encodeComponent(editingId!)}'}',
        {
          ...document.snapshot.toJson(),
          'size': document.width,
          'title': title.trim(),
          'description': description.trim(),
        },
      );
      final value = mapOf(result['data']);
      _upsert(value);
      if (editingId != null) {
        editingId = '${value['id'] ?? editingId}';
        notice = '像素画已更新';
      } else {
        title = '';
        description = '';
        notice = '像素画已分享';
      }
      await saveDraft();
      success = true;
    });
    return success;
  }

  Future<void> like(Map<String, dynamic> artwork) async {
    if (artwork['viewer_liked'] == true || artwork['viewer_liked'] == 1) {
      notice = '已经点过赞了';
      _changed();
      return;
    }
    await _write(() async {
      final result = await request(
        'POST',
        '/api/pixel-art/${Uri.encodeComponent('${artwork['id']}')}/like',
      );
      _upsert(mapOf(result['data']));
      notice = '已点赞';
    });
  }

  Future<void> deleteArtwork(String id) async => _write(() async {
    await request('DELETE', '/api/pixel-art/${Uri.encodeComponent(id)}');
    artworks.removeWhere((item) => '${item['id']}' == id);
    total = (total - 1).clamp(0, 10000000);
    if (editingId == id) editingId = null;
    notice = '作品已删除';
    await saveDraft();
  });
  void _upsert(Map<String, dynamic> value) {
    if (value['id'] == null) return;
    final index = artworks.indexWhere((v) => v['id'] == value['id']);
    if (index < 0) {
      artworks = [value, ...artworks];
      total++;
    } else {
      artworks[index] = {...artworks[index], ...value};
    }
  }

  Future<void> _write(Future<void> Function() action) async {
    if (working) return;
    final owner = _scope;
    working = true;
    error = '';
    notice = '';
    _changed();
    try {
      await action();
    } catch (e) {
      if (!_disposed && owner == _scope) {
        error = e is ApiFailure ? e.message : '操作失败，请重试';
      }
    } finally {
      if (!_disposed && owner == _scope) {
        working = false;
        _changed();
      }
    }
  }

  @override
  void dispose() {
    unawaited(saveDraft());
    _disposed = true;
    _request++;
    _draftTimer?.cancel();
    controller.removeListener(_accountChanged);
    document.removeListener(_documentChanged);
    document.dispose();
    super.dispose();
  }
}
