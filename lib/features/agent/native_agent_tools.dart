import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:file_selector/file_selector.dart';

import '../../core/agent/agent_types.dart';
import '../../core/agent/agent_tools.dart';
import '../../core/models.dart';
import '../../core/room_tools.dart';
import '../room/room_controller.dart';
import '../site/native_article_editor.dart';
import '../site/native_asset_service.dart';

class NativeAgentTools {
  NativeAgentTools(this.room);
  final RoomController room;
  final _owned = <NativeArticleEditor>[];
  final _undo = <String, ({Map<String, dynamic> fields, String after})>{};
  final _mcp = RoomTools();
  final _uploads = <AssetUploadCancellation>[];
  ToolGateway? gateway;
  Directory? _snapshotDirectory;
  File? _snapshot;
  String _snapshotRequest = '';
  int _epoch = 0;
  void cancel() {
    _epoch++;
    _mcp.cancel();
    final directory = _snapshotDirectory;
    _snapshotDirectory = null;
    _snapshot = null;
    if (directory != null) {
      unawaited(directory.delete(recursive: true).catchError((_) => directory));
    }
    for (final upload in _uploads) {
      upload.cancel();
    }
  }

  void dispose() {
    cancel();
    for (final editor in _owned) {
      editor.dispose();
    }
    _owned.clear();
  }

  Future<Map<String, dynamic>> _previewUpload(Map<String, dynamic> args) async {
    final epoch = _epoch;
    final path = await gateway!.resolvePath(
      args['path'] as String,
      write: false,
    );
    final original = await AssetUploadFile.fromXFile(XFile(path));
    if (original.size > maxAttachmentBytes || original.mime.isEmpty) {
      throw const ApiFailure('附件类型或大小不符合站点限制');
    }
    final prior = _snapshotDirectory;
    if (prior != null && await prior.exists()) {
      await prior.delete(recursive: true);
    }
    final directory = await Directory.systemTemp.createTemp(
      'tsukuyomi-agent-upload-',
    );
    try {
      final snapshot = await File(path)
          .copy('${directory.path}/${original.name}');
      final size = await snapshot.length();
      if (size > maxAttachmentBytes) throw const ApiFailure('附件在预览期间发生变化，请重试');
      final checksum = await sha256.bind(snapshot.openRead()).first;
      if (epoch != _epoch) throw const ApiFailure('附件操作已取消');
      _snapshotDirectory = directory;
      _snapshot = snapshot;
      _snapshotRequest = args['path'] as String;
      return {
        ...args,
        'name': original.name,
        'size': size,
        'mime': original.mime,
        'sha256': checksum.toString(),
        'previewPath': snapshot.path,
        if (original.mime.startsWith('text/') ||
            original.mime == 'application/json')
          'preview': utf8.decode(
            await snapshot
                .openRead(0, size.clamp(0, 65536))
                .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk)),
            allowMalformed: true,
          ),
      };
    } catch (_) {
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<AgentArticleDraft> _draft(String id) async {
    if (room.account == null || room.sessionExpired || room.verifyingSession) {
      throw const ApiFailure('请登录后操作文章');
    }
    if (id.contains('/') || id.length > 128) throw const ApiFailure('文章 ID 无效');
    final scope =
        '${endpointUri(room.settings.siteUrl).origin}:${room.account!.id}';
    final key = 'article-editor:$scope:${id.isEmpty ? 'new' : id}';
    final active = room.articleDrafts[key];
    if (active != null) return active;
    final editor = NativeArticleEditor(
      room,
      '/editor${id.isEmpty ? '' : '?id=${Uri.encodeComponent(id)}'}',
    );
    _owned.add(editor);
    await editor.initialize();
    if (scope !=
            '${endpointUri(room.settings.siteUrl).origin}:${room.account?.id}' ||
        room.sessionExpired) {
      throw const ApiFailure('账号或站点已切换，文章操作已停止');
    }
    if (editor.error.isNotEmpty) throw ApiFailure(editor.error);
    return editor;
  }

  Future<List<AgentTool>> discover() async {
    const id = {'type': 'string', 'maxLength': 128};
    const revision = {'type': 'string'};
    final result = <AgentTool>[
      AgentTool(
        'article_read',
        'Read the current native article draft, its fields and revision.',
        {'id': id},
        [],
        (args) async {
          final draft = await _draft(args['id'] as String? ?? '');
          return {'revision': draft.revision, 'fields': Map.of(draft.fields)};
        },
      ),
      AgentTool(
        'article_patch',
        'Apply article fields only if the revision matches; saves a local draft.',
        {
          'id': id,
          'revision': revision,
          'changes': {
            'type': 'object',
            'additionalProperties': false,
            'properties': {
              for (final key in [
                'title',
                'category',
                'read_time',
                'excerpt',
                'content',
                'content_format',
                'status',
              ])
                key: {'type': 'string', 'maxLength': 65536},
              'cover_image': {
                'type': ['string', 'null'],
                'maxLength': 65536,
              },
              'cover_image_asset_id': {
                'type': ['string', 'integer', 'null'],
              },
            },
          },
        },
        ['revision', 'changes'],
        (args) async {
          final draft = await _draft(args['id'] as String? ?? '');
          final before = Map<String, dynamic>.of(draft.fields);
          draft.applyAgentDraft(
            args['revision'] as String,
            Map<String, dynamic>.from(args['changes'] as Map),
          );
          if (!await draft.saveDraft()) throw const ApiFailure('草稿保存失败');
          _undo[draft.draftKey] = (fields: before, after: draft.revision);
          gateway!.emit(
            AgentEvent(
              'diff',
              '文章草稿',
              data: {
                'before': jsonEncode(before),
                'after': jsonEncode(draft.fields),
                'articleId': args['id'] as String? ?? '',
                'revision': draft.revision,
              },
            ),
          );
          return {'revision': draft.revision, 'savedLocally': true};
        },
      ),
      AgentTool(
        'article_undo',
        'Undo the last Agent draft edit if no subsequent edit has occurred.',
        {'id': id},
        [],
        (args) async {
          final draft = await _draft(args['id'] as String? ?? '');
          final undo = _undo[draft.draftKey];
          if (undo == null) throw const ApiFailure('没有可撤销的 Agent 修改');
          draft.applyAgentDraft(undo.after, undo.fields);
          await draft.saveDraft();
          _undo.remove(draft.draftKey);
          return {'revision': draft.revision};
        },
      ),
      AgentTool(
        'article_publish',
        'Publish/save an article after preview and explicit user confirmation.',
        {'id': id, 'revision': revision},
        ['revision'],
        (args) async {
          final draft = await _draft(args['id'] as String? ?? '');
          if (draft.revision != args['revision']) {
            throw const ApiFailure('草稿已修改，请重新预览后发布', status: 409);
          }
          final published = await draft.submit();
          if (published == null) {
            throw ApiFailure(
              draft is NativeArticleEditor && draft.error.isNotEmpty
                  ? draft.error
                  : '文章未发布，请检查草稿内容',
            );
          }
          return published;
        },
        confirm: true,
        approvalDetails: (args) async {
          final draft = await _draft(args['id'] as String? ?? '');
          if (draft.revision != args['revision']) {
            throw const ApiFailure('草稿已修改，请重新读取');
          }
          return {...args, 'preview': Map<String, dynamic>.of(draft.fields)};
        },
      ),
      AgentTool(
        'attachment_upload',
        'Upload an immutable workspace attachment snapshot after content confirmation.',
        {
          'path': {'type': 'string'},
        },
        ['path'],
        (args) async {
          final snapshot = _snapshot,
              directory = _snapshotDirectory,
              epoch = _epoch;
          if (snapshot == null || _snapshotRequest != args['path']) {
            throw const ApiFailure('请重新预览附件');
          }
          final cancel = AssetUploadCancellation();
          _uploads.add(cancel);
          try {
            final file = await AssetUploadFile.fromXFile(XFile(snapshot.path));
            if (epoch != _epoch) throw const ApiFailure('附件操作已取消');
            return await NativeAssetService(room)
                .upload(file, cancellation: cancel);
          } finally {
            _uploads.remove(cancel);
            if (directory != null && await directory.exists()) {
              await directory.delete(recursive: true);
            }
            if (identical(_snapshotDirectory, directory)) {
              _snapshotDirectory = null;
              _snapshot = null;
            }
          }
        },
        confirm: true,
        approvalDetails: _previewUpload,
      ),
    ];
    if (room.settings.flag('mcpEnabled')) {
      final listed = await _mcp.call(
        room.settings,
        'tools/list',
        cookie: room.site.cookie,
      );
      final tools = listed is Map ? listed['tools'] as List? ?? [] : [];
      for (final raw in tools.whereType<Map>()) {
        final name = raw['name'] as String;
        if (!_mcp.allowed(room.settings, name) ||
            !RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(name)) {
          continue;
        }
        final schema = Map<String, dynamic>.from(
          raw['inputSchema'] as Map? ?? {},
        );
        result.add(
          AgentTool(
            'mcp_$name',
            raw['description'] as String? ?? name,
            Map<String, dynamic>.from(schema['properties'] as Map? ?? {}),
            List<String>.from(schema['required'] as List? ?? []),
            (args) async {
              var text = await _mcp.tool(
                room.settings,
                name,
                args,
                cookie: room.site.cookie,
              );
              for (final secret in [
                room.settings.apiKey,
                room.settings.mcpKey,
                room.site.cookie ?? '',
              ]) {
                if (secret.isNotEmpty) {
                  text = text.replaceAll(secret, '[redacted]');
                }
              }
              return text;
            },
            confirm: true,
            approvalReason: '执行外部 MCP 工具前，请确认工具与参数',
          ),
        );
      }
    }
    return result;
  }
}
