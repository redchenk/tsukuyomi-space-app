import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/agent/agent_types.dart';
import '../../core/models.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../room/room_controller.dart';
import 'native_asset_service.dart';
import 'site_widgets.dart';

class NativeArticleEditor extends ChangeNotifier implements AgentArticleDraft {
  NativeArticleEditor(this.room, this.path, {NativeAssetService? service})
    : assets = service ?? NativeAssetService(room) {
    _scope = assets.scope;
    _baseline = Map.of(fields);
    room.addListener(_accountChanged);
    room.articleDrafts[draftKey] = this;
  }
  final RoomController room;
  final NativeAssetService assets;
  final String path;
  @override
  final fields = <String, dynamic>{
    'title': '',
    'category': '其他',
    'read_time': '5 min',
    'excerpt': '',
    'content': '',
    'content_format': 'markdown',
    'cover_image': null,
    'cover_image_asset_id': null,
    'status': 'published',
  };
  List<Map<String, dynamic>> categories = [];
  Map<String, dynamic> _baseline = {};
  bool loading = true,
      submitting = false,
      summarizing = false,
      moderator = false;
  String error = '', notice = '', summaryMessage = '', _scope = '';
  int _request = 0, _summary = 0, _draftRevision = 0;
  bool _disposed = false;
  Timer? _draftTimer;
  String get id => Uri.parse(path).queryParameters['id'] ?? '';
  @override
  String get draftKey =>
      'article-editor:${assets.scope}:${id.isEmpty ? 'new' : id}';
  @override
  String get revision =>
      sha256.convert(utf8.encode(jsonEncode(fields))).toString();

  @override
  void applyAgentDraft(String expectedRevision, Map<String, dynamic> changes) {
    if (_disposed || loading || submitting) {
      throw const ApiFailure('文章正在操作，请稍后重试');
    }
    if (expectedRevision != revision) {
      throw const ApiFailure('草稿已被修改，请重新读取并比较差异', status: 409);
    }
    if (changes.keys.any((key) => !fields.containsKey(key))) {
      throw const ApiFailure('文章字段无效');
    }
    for (final entry in changes.entries) {
      if (!{'cover_image', 'cover_image_asset_id'}.contains(entry.key) &&
          entry.value is! String) {
        throw const ApiFailure('文章字段必须是文本');
      }
    }
    fields.addAll(changes);
    _draftRevision++;
    _changed();
  }

  bool get dirty => jsonEncode(fields) != jsonEncode(_baseline);
  List<Map<String, dynamic>> get allowedCategories =>
      categories.where((item) => moderator || item['name'] != '公告').toList();
  String get articleReadPath =>
      '${moderator ? '/api/moderation/articles' : '/api/user/articles'}/${Uri.encodeComponent(id)}';
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _accountChanged() {
    if (_scope == assets.scope || _disposed) return;
    if (dirty) {
      final key = 'article-editor:$_scope:${id.isEmpty ? 'new' : id}';
      unawaited(
        room.storage
            .saveDraft(
              key,
              jsonEncode({
                'fields': Map.of(fields),
                'savedAt': DateTime.now().toUtc().toIso8601String(),
              }),
            )
            .catchError((_) {}),
      );
    }
    final oldKey = 'article-editor:$_scope:${id.isEmpty ? 'new' : id}';
    if (identical(room.articleDrafts[oldKey], this)) {
      room.articleDrafts.remove(oldKey);
    }
    _scope = assets.scope;
    room.articleDrafts[draftKey] = this;
    _request++;
    _summary++;
    _draftRevision++;
    _draftTimer?.cancel();
    fields.updateAll(
      (key, value) => switch (key) {
        'read_time' => '5 min',
        'category' => '其他',
        'content_format' => 'markdown',
        'status' => 'published',
        'cover_image' || 'cover_image_asset_id' => null,
        _ => '',
      },
    );
    _baseline = Map.of(fields);
    moderator = false;
    categories = [];
    notice = '';
    error = '';
    submitting = false;
    summarizing = false;
    initialize();
  }

  Future<void> initialize() async {
    final ticket = ++_request, scope = assets.scope;
    loading = true;
    error = '';
    _changed();
    bool current() => !_disposed && ticket == _request && scope == assets.scope;
    if (room.account == null || room.sessionExpired) {
      loading = false;
      _changed();
      return;
    }
    try {
      final results = await Future.wait([
        assets.request('GET', '/api/user/profile'),
        assets.request('GET', '/api/article-categories'),
      ]);
      if (!current()) return;
      final role = mapOf(results[0]['data'])['role'];
      moderator = role == 'admin' || role == 'super_admin';
      categories = rowsOf(results[1]['data']);
      if (id.isNotEmpty) {
        final response = await assets.request('GET', articleReadPath);
        if (!current()) return;
        final article = mapOf(response['data']);
        for (final key in fields.keys) {
          if (article.containsKey(key)) fields[key] = article[key];
        }
      }
      if (!allowedCategories.any(
        (item) => item['name'] == fields['category'],
      )) {
        fields['category'] =
            allowedCategories.any((item) => item['name'] == '其他')
            ? '其他'
            : allowedCategories.firstOrNull?['name'] ?? '';
      }
      _baseline = Map.of(fields);
      final key = draftKey, revision = _draftRevision;
      final saved = await room.storage.draft(key);
      if (!current() || revision != _draftRevision) return;
      if (saved.isNotEmpty) {
        try {
          final data = mapOf(jsonDecode(saved)), form = mapOf(data['fields']);
          for (final key in fields.keys) {
            if (form.containsKey(key)) fields[key] = form[key];
          }
          if (!moderator && fields['category'] == '公告') {
            fields['category'] = '其他';
          }
          notice = '已恢复本机草稿';
        } catch (_) {
          notice = '本机草稿无法读取，已保留站点内容';
        }
      }
    } catch (e) {
      if (current()) error = '$e';
    } finally {
      if (current()) {
        loading = false;
        _changed();
      }
    }
  }

  void change(String key, dynamic value) {
    if (_disposed || loading || submitting || !fields.containsKey(key)) return;
    fields[key] = value;
    _draftRevision++;
    _changed();
    _draftTimer?.cancel();
    final scope = assets.scope, revision = _draftRevision;
    _draftTimer = Timer(const Duration(milliseconds: 450), () {
      if (!_disposed && scope == assets.scope && revision == _draftRevision) {
        saveDraft();
      }
    });
  }

  @override
  Future<bool> saveDraft() async {
    final key = draftKey, scope = assets.scope, revision = _draftRevision;
    _draftTimer?.cancel();
    try {
      await room.storage.saveDraft(
        key,
        jsonEncode({
          'fields': Map.of(fields),
          'savedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      if (!_disposed && scope == assets.scope && revision == _draftRevision) {
        notice = '草稿已保存到本机';
        _changed();
      }
      return true;
    } catch (_) {
      if (!_disposed && scope == assets.scope) {
        error = '本机草稿保存失败，请重试';
        _changed();
      }
      return false;
    }
  }

  Future<void> discardDraft() async {
    final scope = assets.scope, key = draftKey;
    _draftTimer?.cancel();
    _draftRevision++;
    await room.storage.saveDraft(key, '');
    if (_disposed || scope != assets.scope) return;
    fields.addAll(_baseline);
    notice = '已恢复站点内容';
    _changed();
  }

  Future<void> summarize() async {
    if (summarizing || submitting || loading) return;
    final content = '${fields['content']}'.trim(),
        excerpt = '${fields['excerpt']}',
        format = fields['content_format'];
    if (content.isEmpty) {
      summaryMessage = '先写下正文再生成摘要';
      _changed();
      return;
    }
    final scope = assets.scope, ticket = ++_summary;
    summarizing = true;
    summaryMessage = '';
    _changed();
    try {
      final result = await assets.request('POST', '/api/articles/summarize', {
        'content': content,
        'content_format': format,
      });
      if (_disposed || scope != assets.scope || ticket != _summary) return;
      if (content != '${fields['content']}'.trim() ||
          excerpt != fields['excerpt'] ||
          format != fields['content_format']) {
        summaryMessage = '正文或摘要已变化，请重新生成';
        return;
      }
      change('excerpt', textOf(mapOf(result['data']), 'excerpt'));
      summaryMessage = '摘要已生成';
    } catch (e) {
      if (!_disposed && scope == assets.scope && ticket == _summary) {
        summaryMessage = '$e';
      }
    } finally {
      if (!_disposed && scope == assets.scope && ticket == _summary) {
        summarizing = false;
        _changed();
      }
    }
  }

  @override
  Future<Map<String, dynamic>?> submit() async {
    if (submitting || summarizing || loading) return null;
    if (room.account == null || room.sessionExpired) {
      error = '请先登录';
      _changed();
      return null;
    }
    if ([
      'title',
      'category',
      'read_time',
      'content',
    ].any((key) => '${fields[key] ?? ''}'.trim().isEmpty)) {
      error = '请填写标题、分类、阅读时长与正文';
      _changed();
      return null;
    }
    if (!allowedCategories.any((item) => item['name'] == fields['category'])) {
      error = '请选择有效的文章分类';
      _changed();
      return null;
    }
    final scope = assets.scope, key = draftKey;
    _draftTimer?.cancel();
    await saveDraft();
    if (_disposed || scope != assets.scope) return null;
    submitting = true;
    error = '';
    _changed();
    try {
      final body = {
        ...fields,
        'title': '${fields['title']}'.trim(),
        'content': '${fields['content']}'.trim(),
      };
      final endpoint = id.isEmpty
          ? '/api/articles'
          : moderator
          ? '$articleReadPath/save'
          : articleReadPath;
      final result = await assets.request(
        id.isEmpty || moderator ? 'POST' : 'PUT',
        endpoint,
        body,
      );
      if (_disposed || scope != assets.scope) return null;
      _baseline = Map.of(fields);
      await room.storage.saveDraft(key, '');
      if (_disposed || scope != assets.scope) return null;
      notice = id.isEmpty ? '文章已发布' : '文章已保存';
      _changed();
      return result;
    } catch (e) {
      if (!_disposed && scope == assets.scope) {
        error = '$e';
        _changed();
      }
      return null;
    } finally {
      if (!_disposed && scope == assets.scope) {
        submitting = false;
        _changed();
      }
    }
  }

  @override
  void dispose() {
    if (identical(room.articleDrafts[draftKey], this)) {
      room.articleDrafts.remove(draftKey);
    }
    _disposed = true;
    _request++;
    _summary++;
    _draftTimer?.cancel();
    room.removeListener(_accountChanged);
    super.dispose();
  }
}

const nativeMarkdownTemplates = {
  '表格': '| 项目 | 说明 |\n| :--- | :--- |\n| 月读空间 | 写下你的内容 |',
  '任务清单': '- [ ] 待完成的事项\n- [x] 已完成的事项',
  '提示框': '::: tip 小提示\n这里可以使用 **加粗**、列表和链接。\n:::',
  'GitHub 提示': '> [!IMPORTANT]\n> 请注意这条信息。',
  '折叠内容': '::: details 点击展开\n这里是可折叠的正文。\n:::',
  '代码块': '```javascript title="example.js"\nconst message = "Hello, Tsukuyomi!";\nconsole.log(message);\n```',
  '数学公式': '\$\$\nE = mc^2\n\$\$',
  '脚注': '需要说明的内容[^note]\n\n[^note]: 写下补充说明或资料来源。',
  '图片画廊': '::: gallery\n![图片说明](https://example.com/image-1.jpg)\n\n![图片说明](https://example.com/image-2.jpg)\n:::',
  '缩写释义': '*[SSR]: Server-Side Rendering\n\nSSR 可以让正文更早呈现。',
  '下标': 'H~2~O',
  '上标': 'x^2^',
};

class NativeMarkdownListFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!oldValue.selection.isCollapsed ||
        !newValue.composing.isCollapsed ||
        !oldValue.selection.isValid ||
        newValue.text.length != oldValue.text.length + 1) {
      return newValue;
    }
    final cursor = oldValue.selection.start;
    if (newValue.text != oldValue.text.replaceRange(cursor, cursor, '\n')) {
      return newValue;
    }
    final lineStart = cursor == 0
        ? 0
        : oldValue.text.lastIndexOf('\n', cursor - 1) + 1;
    String? fence;
    for (final previous in oldValue.text.substring(0, lineStart).split('\n')) {
      final match = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$').firstMatch(previous);
      if (match == null) continue;
      final delimiter = match.group(1)!;
      if (fence == null) {
        fence = delimiter;
      } else if (delimiter[0] == fence[0] &&
          delimiter.length >= fence.length &&
          match.group(2)!.trim().isEmpty) {
        fence = null;
      }
    }
    if (fence != null) return newValue;
    final line = oldValue.text.substring(lineStart, cursor);
    final match = RegExp(
      r'^(\s*)(?:([-+*])\s+(\[[ xX]\]\s+)?|(\d+)([.)])\s+|([>])\s+)(.*)$',
    ).firstMatch(line);
    if (match == null) return newValue;
    if (match.group(7)!.trim().isEmpty) {
      return TextEditingValue(
        text: oldValue.text.replaceRange(lineStart, cursor, ''),
        selection: TextSelection.collapsed(offset: lineStart),
      );
    }
    final prefix = match.group(2) != null
        ? '${match.group(2)} ${match.group(3) != null ? '[ ] ' : ''}'
        : match.group(4) != null
        ? '${int.parse(match.group(4)!) + 1}${match.group(5)} '
        : '${match.group(6)} ';
    final insertion = '\n${match.group(1)}$prefix';
    return TextEditingValue(
      text: oldValue.text.replaceRange(cursor, cursor, insertion),
      selection: TextSelection.collapsed(offset: cursor + insertion.length),
    );
  }
}
