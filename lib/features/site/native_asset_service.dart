import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../../core/site_repository.dart';
import '../room/room_controller.dart';

const attachmentMimeTypes = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'webm': 'video/webm',
  'mov': 'video/quicktime',
  'mp3': 'audio/mpeg',
  'flac': 'audio/flac',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'm4a': 'audio/mp4',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'markdown': 'text/markdown',
};
const maxAttachmentBytes = 100 * 1024 * 1024;
const attachmentChunkBytes = 4 * 1024 * 1024;

class AssetUploadFile {
  const AssetUploadFile({
    required this.name,
    required this.size,
    required this.modified,
    required this.readRange,
  });
  final String name;
  final int size, modified;
  final Future<Uint8List> Function(int start, int end) readRange;
  String get mime =>
      attachmentMimeTypes[name.split('.').last.toLowerCase()] ?? '';

  static Future<AssetUploadFile> fromXFile(XFile file) async {
    var modified = 0;
    try {
      modified = (await file.lastModified()).millisecondsSinceEpoch;
    } catch (_) {
      // Virtual picker files have bytes and length, but may have no disk path.
    }
    return AssetUploadFile(
      name: file.name.isNotEmpty
          ? file.name
          : 'upload.${attachmentMimeTypes.entries.firstWhere((entry) => entry.value == file.mimeType, orElse: () => const MapEntry('bin', '')).key}',
      size: await file.length(),
      modified: modified,
      readRange: (start, end) async {
        final builder = BytesBuilder(copy: false);
        await for (final bytes in file.openRead(start, end)) {
          builder.add(bytes);
        }
        return builder.takeBytes();
      },
    );
  }
}

class AssetUploadCancellation {
  final _cancelled = Completer<void>();
  bool get cancelled => _cancelled.isCompleted;
  Future<void> get signal => _cancelled.future;
  void cancel() {
    if (!cancelled) _cancelled.complete();
  }

  void check() {
    if (cancelled) throw const ApiFailure('上传已暂停，24 小时内重新选择同一文件可继续');
  }

  Future<void> delay(Duration duration) async {
    await Future.any([Future<void>.delayed(duration), signal]);
    check();
  }
}

typedef AssetBinaryRequest = Future<Map<String, dynamic>> Function(
  String path,
  Uint8List body,
  String checksum,
  AssetUploadCancellation cancel,
);

/// Implements the original site's durable, checksum-verified 4 MB uploader.
/// Only upload references are stored locally; file contents stay on disk.
class NativeAssetService {
  NativeAssetService(this.controller, {AssetBinaryRequest? binary, this.client})
    : _binaryOverride = binary {
    repository = SiteRepository(
      api: controller.site as SiteDataService,
      storage: controller.storage,
      site: () => controller.settings.siteUrl,
      accountId: () => controller.account?.id,
    );
  }
  final RoomController controller;
  final http.Client? client;
  final AssetBinaryRequest? _binaryOverride;
  late final SiteRepository repository;
  String get scope => repository.scope;

  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final owner = scope;
    final result = await repository.api.request(
      controller.settings.siteUrl,
      method,
      path,
      body,
    );
    if (owner != scope) throw const ApiFailure('账号已切换，请重试', status: 409);
    return result;
  }

  Future<bool> moderator() async {
    if (controller.account == null || controller.sessionExpired) return false;
    final result = await request('GET', '/api/user/profile');
    final role = (result['data'] as Map?)?['role'];
    return role == 'admin' || role == 'super_admin';
  }

  Future<Map<String, dynamic>> _put(
    String path,
    Uint8List bytes,
    String checksum,
    AssetUploadCancellation cancel,
  ) async {
    if (_binaryOverride != null) {
      return _binaryOverride(path, bytes, checksum, cancel);
    }
    final owner = scope, cookie = controller.site.cookie;
    final base = endpointUri(controller.settings.siteUrl),
        target = endpointUri(controller.settings.siteUrl).resolve(path);
    if (target.origin != base.origin ||
        !target.path.startsWith('/api/assets/uploads/')) {
      throw const ApiFailure('无效的附件上传地址');
    }
    final httpClient = client ?? http.Client();
    try {
      cancel.check();
      final req =
          http.AbortableRequest('PUT', target, abortTrigger: cancel.signal)
            ..followRedirects = false
            ..headers.addAll({
              'Content-Type': 'application/octet-stream',
              'Accept': 'application/json',
              'Origin': base.origin,
              'X-Requested-With': 'XMLHttpRequest',
              'X-Upload-SHA256': checksum,
              'Cookie': ?cookie,
            })
            ..bodyBytes = bytes;
      final response = await http.Response.fromStream(
        await httpClient.send(req),
      ).timeout(const Duration(minutes: 3));
      if (owner != scope || cookie != controller.site.cookie) {
        throw const ApiFailure('账号已切换，请重试', status: 409);
      }
      if (response.statusCode == 401) controller.expireSession();
      Map<String, dynamic> result;
      try {
        result = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(response.bodyBytes)) as Map,
        );
      } catch (_) {
        throw ApiFailure(
          '上传响应异常（HTTP ${response.statusCode}）',
          status: response.statusCode,
        );
      }
      if (response.statusCode >= 300 || result['success'] != true) {
        throw ApiFailure(
          '${result['message'] ?? '上传失败'}',
          status: response.statusCode,
        );
      }
      return Map<String, dynamic>.from(result['data'] as Map? ?? {});
    } finally {
      if (client == null) httpClient.close();
    }
  }

  Future<Map<String, dynamic>> upload(
    AssetUploadFile file, {
    String storage = 'auto',
    AssetUploadCancellation? cancellation,
    void Function(double? progress, String phase)? onProgress,
    Future<void> Function(Duration duration)? sleep,
  }) async {
    if (file.size <= 0) throw const ApiFailure('文件内容为空');
    if (file.size > maxAttachmentBytes) {
      throw const ApiFailure('单个文件不能超过 100 MB', status: 413);
    }
    if (file.mime.isEmpty) {
      throw const ApiFailure('请选择图片、音视频、PDF、TXT 或 Markdown');
    }
    if (controller.account == null || controller.sessionExpired) {
      throw const ApiFailure('请先登录后上传附件', status: 401);
    }
    final cancel = cancellation ?? AssetUploadCancellation(), owner = scope;
    void check() {
      cancel.check();
      if (owner != scope) throw const ApiFailure('账号已切换，请重试', status: 409);
    }

    Future<void> wait(Duration duration) async {
      await (sleep?.call(duration) ?? cancel.delay(duration));
      check();
    }

    Future<Map<String, dynamic>> retry(
      Future<Map<String, dynamic>> Function() work,
    ) async {
      for (var attempt = 0; ; attempt++) {
        check();
        try {
          final result = await work();
          check();
          return result;
        } catch (e) {
          check();
          final status = e is ApiFailure ? e.status : null;
          if (attempt >= 5 ||
              (status != null &&
                  status < 500 &&
                  ![408, 422, 429].contains(status))) {
            rethrow;
          }
          onProgress?.call(null, '连接不稳定，正在重试（${attempt + 1}/5）…');
          await wait(Duration(milliseconds: min(1000 * (1 << attempt), 16000)));
        }
      }
    }

    Future<Map<String, dynamic>> json(
      String method,
      String path, [
      Map<String, dynamic>? body,
    ]) => retry(() async {
      final result = await request(method, path, body);
      return Map<String, dynamic>.from(result['data'] as Map? ?? {});
    });
    onProgress?.call(0, '正在检查文件…');
    final prefix = await file.readRange(0, min(65536, file.size));
    check();
    final fingerprint = sha256.convert([
      ...utf8.encode(
        jsonEncode([file.name, file.size, file.modified, storage]),
      ),
      ...prefix,
    ]).toString();
    final key = 'asset-upload:$owner:$fingerprint';
    Map<String, dynamic> saved = {};
    try {
      final value = await controller.storage.draft(key);
      if (value.isNotEmpty) {
        saved = Map<String, dynamic>.from(jsonDecode(value) as Map);
      }
    } catch (_) {
      /* Upload can proceed without a local reference. */
    }
    if ((saved['expiresAt'] as num? ?? 0) <=
        DateTime.now().millisecondsSinceEpoch) {
      saved = {
        'requestId': _uuid(),
        'expiresAt': DateTime.now()
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch,
      };
    }
    Future<void> remember() async {
      try {
        await controller.storage.saveDraft(key, jsonEncode(saved));
      } catch (_) {}
    }

    Future<void> forget() async {
      try {
        await controller.storage.saveDraft(key, '');
      } catch (_) {}
    }

    check();
    await remember();
    Map<String, dynamic>? state;
    if (saved['id'] != null) {
      try {
        state = await json('GET', '/api/assets/uploads/${saved['id']}');
      } on ApiFailure catch (e) {
        if (![404, 410].contains(e.status)) rethrow;
        saved = {
          'requestId': _uuid(),
          'expiresAt': DateTime.now()
              .add(const Duration(days: 1))
              .millisecondsSinceEpoch,
        };
        await remember();
      }
    }
    state ??= await json('POST', '/api/assets/uploads', {
      'requestId': saved['requestId'],
      'size': file.size,
      'fileName': file.name,
      'mimeType': file.mime,
      'alt': file.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
      'storage': storage,
    });
    saved = {...saved, 'id': state['id'], 'expiresAt': state['expiresAt']};
    await remember();
    check();
    final path = '/api/assets/uploads/${Uri.encodeComponent('${state['id']}')}';
    try {
      if (state['size'] != file.size ||
          state['chunkBytes'] != attachmentChunkBytes) {
        throw const ApiFailure('上传记录不匹配，请重新选择文件', status: 409);
      }
      final parts = state['parts'] as List? ?? [];
      for (
        var index = 0;
        index < (file.size / attachmentChunkBytes).ceil();
        index++
      ) {
        check();
        final start = index * attachmentChunkBytes,
            end = min((index + 1) * attachmentChunkBytes, file.size);
        final chunk = await file.readRange(start, end);
        check();
        final hash = sha256.convert(chunk).toString();
        if (index < parts.length && parts[index] is Map) {
          if ((parts[index] as Map)['hash'] != hash) {
            throw const ApiFailure('文件已改变，请重新选择文件上传', status: 409);
          }
        } else {
          await retry(() => _put('$path/$index', chunk, hash, cancel));
        }
        onProgress?.call(end / file.size * .95, '正在上传…');
      }
      onProgress?.call(.96, '文件已接收，正在保存…');
      final deadline = DateTime.now().add(const Duration(minutes: 12));
      var starts = 0;
      while (DateTime.now().isBefore(deadline)) {
        check();
        state = await json('GET', path);
        if (state['completed'] == true && state['asset'] is Map) {
          await forget();
          onProgress?.call(1, '附件已上传');
          return Map<String, dynamic>.from(state['asset'] as Map);
        }
        if (state['processing'] != true) {
          if (starts++ >= 3) {
            throw ApiFailure('${state['error'] ?? '保存附件失败，重新选择同一文件可重试'}');
          }
          await json('POST', '$path/complete');
        }
        await wait(const Duration(seconds: 3));
      }
      throw const ApiFailure('文件仍在保存，请稍后刷新附件库；重新选择同一文件可继续检查');
    } on ApiFailure catch (e) {
      if ([400, 409, 413, 415].contains(e.status) &&
          owner == scope &&
          !cancel.cancelled) {
        try {
          await request('DELETE', path);
          await forget();
        } catch (_) {}
      }
      rethrow;
    }
  }
}

String _uuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  // Keep construction independent of platform UUID plugins.
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String nativeAssetName(Map asset) {
  final metadata = asset['metadata'] is Map ? asset['metadata'] as Map : {};
  return '${metadata['title'] ?? metadata['fileName'] ?? metadata['alt'] ?? asset['storage_key']?.toString().split('/').last ?? asset['id'] ?? '附件'}';
}

String nativeAssetUrl(
  Map asset, {
  bool markdown = false,
  bool preview = false,
}) =>
    '${(markdown
            ? asset['markdown_url']
            : preview
            ? asset['preview_url']
            : null) ?? asset['access_url'] ?? asset['display_url'] ?? asset['url'] ?? ''}';

String nativeAssetMarkdown(Map asset) {
  final metadata = asset['metadata'] is Map ? asset['metadata'] as Map : {};
  final name = '${metadata['alt'] ?? nativeAssetName(asset)}'.replaceAll(
    RegExp(r'[\]\r\n]'),
    ' ',
  );
  final url = nativeAssetUrl(asset, markdown: true),
      mime = '${asset['mime_type'] ?? ''}';
  if (mime.startsWith('image/')) return '![$name]($url)';
  if (mime.startsWith('video/')) return '\n::media[$name]($url "video")\n';
  if (mime.startsWith('audio/')) return '\n::media[$name]($url "audio")\n';
  return '[$name]($url)';
}
