import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/models.dart';
import '../../core/room_archive.dart';
import '../../core/room_context.dart';
import '../../core/room_protocol.dart';
import '../../core/room_reference.dart';
import '../../core/room_memory.dart';
import '../../core/room_memory_source.dart';
import '../../core/room_tools.dart';
import '../../core/site_client.dart';
import 'room_controller.dart';

class RoomWorkspace extends ChangeNotifier {
  RoomWorkspace(this.c) {
    archive = RoomArchive(
      storage: c.storage,
      site: c.site is SiteDataService ? c.site as SiteDataService : null,
      siteUrl: () => c.settings.siteUrl,
      scope: () => c.scope,
      owner: () => c.account?.id ?? '',
      online: () => online,
    );
    archive.addListener(changed);
  }
  final RoomController c;
  late final RoomArchive archive;
  final tools = RoomTools();
  Map<String, dynamic> world = {}, profile = {};
  Map<String, dynamic>? sharedWorld;
  Map<String, dynamic> get currentWorld => sharedWorld ?? world;
  List<Map<String, dynamic>> localMemories = [];
  List<Map<String, dynamic>> guestMemories = [];
  String memorySource = 'cloud',
      _sourceFingerprint = '',
      memoryChoiceError = '',
      memoryChoiceProgress = '';
  bool memoryChoiceVisible = false,
      memoryChoicePending = false,
      memoryChoiceLoading = false,
      memoryDraftPending = false;
  Map<String, dynamic>? memoryDraft;
  int? cloudMemoryCount;
  int memoryContentLimit = 12000, _sourceRequest = 0;
  final Map<String, Future<void>> _memoryWrites = {};
  bool get usesLocalMemory => c.account == null || memorySource == 'local';
  bool get cloudMemoryAvailable => !usesLocalMemory && !c.sessionExpired;
  String get _origin => endpointUri(c.settings.siteUrl).origin;
  String get localMemoryKey => c.account == null
      ? (c.settings.demo ? 'demo' : '$_origin:guest')
      : '$_origin:user-local:${c.account!.id}';
  String get memoryIdentity => '$localMemoryKey|$memorySource';
  String get _choiceKey =>
      '$_origin:roomMemorySource:${c.account?.id ?? 'guest'}';
  String get _guestMemoryKey => c.settings.demo ? 'demo' : '$_origin:guest';
  String get memoryLocationText => c.account == null
      ? '访客记忆仅保存在此设备。'
      : usesLocalMemory
      ? '本地记忆仅供当前账号在此设备使用，云端原有记忆保留。'
      : '当前账号的私有云端记忆，可跨设备使用。本地原件仍保留。';
  String note = '', worldStatus = '', status = '';
  int _epoch = 0;
  bool _disposed = false;
  bool get online => !c.settings.demo && c.account != null && !c.sessionExpired;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    final epoch = ++_epoch, scope = c.scope;
    await RoomReference.load();
    final saved = await c.storage.draft('$scope.room-workspace');
    if (epoch != _epoch || _disposed) return;
    final data = saved.isEmpty
        ? <String, dynamic>{}
        : jsonMap(jsonDecode(saved));
    profile = jsonMap(data['profile']);
    note = '${data['note'] ?? ''}';
    world = jsonMap(data['world']);
    final sourceSaved = c.account == null
        ? ''
        : await c.storage.draft(_choiceKey);
    if (epoch != _epoch || _disposed) return;
    final source = sourceSaved.isEmpty
        ? <String, dynamic>{}
        : jsonMap(jsonDecode(sourceSaved));
    memorySource = c.account == null || source['mode'] == 'local'
        ? 'local'
        : 'cloud';
    _sourceFingerprint = '${source['fingerprint'] ?? ''}';
    localMemories = await _readLocalMemories(
      localMemoryKey,
      legacy: c.account == null || !c.settings.demo
          ? jsonRows(data['memories'])
          : [],
    );
    if (epoch != _epoch || _disposed) return;
    _sourceRequest++;
    memoryChoicePending = memoryChoiceLoading = memoryChoiceVisible = false;
    memoryDraftPending = false;
    memoryDraft = null;
    memoryChoiceError = memoryChoiceProgress = '';
    cloudMemoryCount = null;
    guestMemories = [];
    await archive.load();
    if (epoch != _epoch || _disposed) return;
    changed();
    if (c.account != null) unawaited(refreshMemoryChoice());
  }

  Future<List<Map<String, dynamic>>> _readLocalMemories(
    String key, {
    List<Map<String, dynamic>>? legacy,
  }) async {
    await (_memoryWrites[key] ?? Future<void>.value()).catchError((_) {});
    final saved = await c.storage.draft('$key.room-memories');
    if (saved.isNotEmpty) return jsonRows(jsonDecode(saved));
    if (legacy != null) return legacy;
    final oldKey = key.contains(':user-local:')
        ? key.replaceFirst(':user-local:', ':')
        : key;
    final old = await c.storage.draft('$oldKey.room-workspace');
    return old.isEmpty ? [] : jsonRows(jsonMap(jsonDecode(old))['memories']);
  }

  Future<void> _persistMemories(String key, List<Map<String, dynamic>> rows) {
    final value = jsonEncode(rows);
    final write = (_memoryWrites[key] ?? Future<void>.value())
        .catchError((_) {})
        .then((_) => c.storage.saveDraft('$key.room-memories', value));
    _memoryWrites[key] = write;
    return write;
  }

  void _requireMemoryIdentity(String identity) {
    if (_disposed || identity != memoryIdentity) {
      throw const ApiFailure('登录身份或记忆来源已变化，请重新操作', status: 409);
    }
  }

  Future<void> refreshMemoryChoice({bool force = false}) async {
    if (c.account == null || _disposed) {
      memoryChoiceVisible = false;
      return;
    }
    final request = ++_sourceRequest, identity = memoryIdentity;
    memoryChoiceLoading = true;
    changed();
    var loaded = false;
    try {
      final rows = await _readLocalMemories(_guestMemoryKey);
      _requireMemoryIdentity(identity);
      if (request != _sourceRequest) return;
      guestMemories = rows;
      final fingerprint = guestRoomMemoryFingerprint(rows);
      memoryChoiceError = '';
      memoryChoiceVisible =
          force || (rows.isNotEmpty && fingerprint != _sourceFingerprint);
      loaded = true;
      memoryChoiceLoading = false;
      changed();
      if (!memoryChoiceVisible || c.sessionExpired) return;
      final result = await this
          .request('GET', '/api/room/memory/status')
          .timeout(const Duration(seconds: 8));
      _requireMemoryIdentity(identity);
      if (request != _sourceRequest) return;
      final data = jsonMap(result['data']);
      cloudMemoryCount = (data['count'] as num?)?.toInt();
      final limit = data['maxContentLength'];
      memoryContentLimit = limit is num && limit.isFinite && limit >= 4000
          ? limit.toInt().clamp(4000, 100000)
          : 12000;
    } catch (e) {
      if (!loaded &&
          !_disposed &&
          identity == memoryIdentity &&
          request == _sourceRequest) {
        memoryChoiceVisible = true;
        memoryChoiceError = '读取记忆状态失败：$e。原数据仍保留，请重试。';
      }
    } finally {
      if (!_disposed &&
          identity == memoryIdentity &&
          request == _sourceRequest) {
        memoryChoiceLoading = false;
        changed();
      }
    }
  }

  Future<void> chooseMemorySource(String choice) async {
    if (memoryChoicePending || c.account == null) return;
    if (memoryDraftPending) {
      memoryChoiceError = '请先保存或取消正在编辑的记忆，再切换来源。';
      changed();
      throw ApiFailure(memoryChoiceError);
    }
    if (!['local', 'merge', 'cloud'].contains(choice)) {
      throw const ApiFailure('记忆来源无效');
    }
    final identity = memoryIdentity,
        accountId = c.account!.id,
        localKey = localMemoryKey,
        choiceKey = _choiceKey;
    memoryChoicePending = true;
    memoryChoiceError = memoryChoiceProgress = '';
    changed();
    try {
      final guest = await _readLocalMemories(_guestMemoryKey);
      _requireMemoryIdentity(identity);
      final fingerprint = guestRoomMemoryFingerprint(guest);
      final local = await _readLocalMemories(localKey);
      _requireMemoryIdentity(identity);
      if (choice == 'local') {
        final copied = [
          for (final row in guest)
            {...row, 'id': 'user-local:$accountId:import:${row['id']}'},
        ];
        final current = localKey == localMemoryKey ? localMemories : local;
        final ids = current.map((row) => row['id']).toSet();
        final combined = [
          ...current,
          ...copied.where((row) => !ids.contains(row['id'])),
        ];
        localMemories = combined;
        await _persistMemories(localKey, combined);
        _requireMemoryIdentity(identity);
      } else if (choice == 'merge') {
        if (c.sessionExpired) {
          throw const ApiFailure('请重新登录后合并云端记忆', status: 401);
        }
        final prefix = 'user-local:$accountId:import:';
        final copiedIds = local
            .map((row) => '${row['id']}')
            .where((id) => id.startsWith(prefix))
            .map((id) => id.substring(prefix.length))
            .toSet();
        final rows = [
          ...guest.where((row) => !copiedIds.contains(row['id'])),
          ...local,
        ];
        final batches = roomMemoryImportBatches(
          rows,
          maxContentLength: memoryContentLimit,
        );
        for (var index = 0; index < batches.length; index++) {
          _requireMemoryIdentity(identity);
          memoryChoiceProgress = '正在合并第 ${index + 1} / ${batches.length} 批记忆…';
          changed();
          await request('POST', '/api/room/memory/import', {
            'expectedUserId': accountId,
            'records': batches[index],
          }).timeout(const Duration(seconds: 20));
          _requireMemoryIdentity(identity);
        }
      }
      _requireMemoryIdentity(identity);
      final mode = choice == 'local' ? 'local' : 'cloud';
      await c.storage.saveDraft(
        choiceKey,
        jsonEncode({'mode': mode, 'fingerprint': fingerprint}),
      );
      _requireMemoryIdentity(identity);
      memorySource = mode;
      _sourceFingerprint = fingerprint;
      _sourceRequest++;
      memoryChoiceVisible = false;
      c.memoryRevision++;
    } catch (e) {
      if (!_disposed && identity == memoryIdentity) {
        memoryChoiceError = '操作未完成：$e。本地原件保留，重试不会重复导入已成功的批次。';
      }
      rethrow;
    } finally {
      if (!_disposed && localKey == localMemoryKey) {
        memoryChoicePending = false;
        memoryChoiceProgress = '';
        changed();
      }
    }
  }

  Future<void> persist() async {
    final key = localMemoryKey;
    final rows = List<Map<String, dynamic>>.of(localMemories);
    await c.storage.saveDraft(
      '${c.scope}.room-workspace',
      jsonEncode({
        'profile': profile,
        'note': note,
        'world': world,
        'memories': c.account == null
            ? localMemories
            : <Map<String, dynamic>>[],
      }),
    );
    await _persistMemories(key, rows);
  }

  Future<void> saveProfile(String nickname, String signature) async {
    profile = {'nickname': nickname.trim(), 'signature': signature.trim()};
    await persist();
    changed();
  }

  Future<void> saveNote(String value) async {
    note = value;
    await persist();
    changed();
  }

  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (c.site is! SiteDataService) throw const ApiFailure('站点接口不可用');
    final scope = c.scope;
    final result = await (c.site as SiteDataService).request(
      c.settings.siteUrl,
      method,
      path,
      body,
    );
    if (scope != c.scope || _disposed) {
      throw const ApiFailure('账号已切换，请重试', status: 409);
    }
    return result;
  }

  Future<void> refreshWorld({bool locate = false}) async {
    if (sharedWorld != null) return;
    final epoch = _epoch;
    try {
      var query = '';
      if (locate) {
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          throw const ApiFailure('定位未授权，仍使用站点提供的环境信息');
        }
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.low,
            timeLimit: Duration(seconds: 12),
          ),
        );
        query =
            '?lat=${position.latitude}&lon=${position.longitude}&accuracy=${position.accuracy}';
      }
      final r = await request(
        'GET',
        '/api/room/world/live/${DateTime.now().millisecondsSinceEpoch}$query',
      );
      if (epoch != _epoch) return;
      world = jsonMap(r['data']);
      worldStatus = '已更新';
      await persist();
    } catch (e) {
      if (epoch == _epoch) {
        worldStatus = e is ApiFailure ? e.message : '环境暂不可用，保留上次信息';
      }
    }
    changed();
  }

  Future<Map<String, dynamic>> memories({
    String query = '',
    String type = '',
    int offset = 0,
  }) async {
    if (!usesLocalMemory) {
      if (c.sessionExpired) throw const ApiFailure('请重新登录后管理账号记忆', status: 401);
      final uri = Uri(
        path: '/api/room/memory',
        queryParameters: {
          'view': 'manage',
          'limit': '80',
          'offset': '$offset',
          'q': query,
          'type': type,
        },
      );
      final identity = memoryIdentity;
      final data = jsonMap((await request('GET', uri.toString()))['data']);
      _requireMemoryIdentity(identity);
      return data;
    }
    final rows = localMemories
        .where(
          (v) =>
              (type.isEmpty || v['type'] == type) &&
              jsonEncode(v).toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    return {
      'items': rows.skip(offset).take(80).toList(),
      'total': rows.length,
      'hasMore': rows.length > offset + 80,
    };
  }

  Future<Map<String, dynamic>> memoryDetail(Map<String, dynamic> item) async {
    if (usesLocalMemory) return item;
    if (c.sessionExpired) throw const ApiFailure('请重新登录后读取账号记忆', status: 401);
    final identity = memoryIdentity;
    final data = jsonMap(
      (await request(
        'GET',
        '/api/room/memory/${Uri.encodeComponent('${item['id']}')}',
      ))['data'],
    );
    _requireMemoryIdentity(identity);
    return data;
  }

  Future<void> saveMemory(Map<String, dynamic> value) async {
    final identity = memoryIdentity;
    roomMemoryScoreValue(value['importance'], 'importance', .5);
    roomMemoryScoreValue(value['confidence'], 'confidence', .8);
    if (!usesLocalMemory) {
      if (!cloudMemoryAvailable) throw const ApiFailure('请重新登录后保存账号记忆');
      final id = value['id'];
      await request(
        id == null ? 'POST' : 'PUT',
        '/api/room/memory${id == null ? '' : '/${Uri.encodeComponent('$id')}'}',
        {...value, 'captureChat': false},
      );
    } else {
      final id = value['id'] ?? newTurnId();
      localMemories = [
        ...localMemories.where((v) => v['id'] != id),
        {
          ...value,
          'id': id,
          'manuallyEdited': true,
          'createdAt':
              value['createdAt'] ?? roomMemoryTimestamp(DateTime.now()),
          'updatedAt': roomMemoryTimestamp(DateTime.now()),
        },
      ];
      await persist();
    }
    _requireMemoryIdentity(identity);
    changed();
  }

  Future<void> deleteMemory(String? id) async {
    final identity = memoryIdentity;
    if (!usesLocalMemory) {
      if (!cloudMemoryAvailable) throw const ApiFailure('请重新登录后删除账号记忆');
      await request(
        'DELETE',
        '/api/room/memory${id == null ? '?expectedUserId=${Uri.encodeQueryComponent(c.account!.id)}' : '/${Uri.encodeComponent(id)}'}',
      );
    } else {
      localMemories = id == null
          ? []
          : localMemories.where((v) => v['id'] != id).toList();
      await persist();
    }
    _requireMemoryIdentity(identity);
    changed();
  }

  Future<void> captureGuestTurn(ChatTurn turn, {bool replace = false}) async {
    if (c.account != null && turn.memorySource != 'local' && !usesLocalMemory) {
      return;
    }
    final key = turn.localMemoryKey ?? localMemoryKey;
    if (key != localMemoryKey) return;
    final identity = memoryIdentity;
    final content = '用户：${turn.user}\n八千代：${turn.assistant}';
    final allowed =
        turn.memoryEnabled &&
        turn.user.isNotEmpty &&
        !sensitiveRoomMemory.hasMatch(content);
    if (!allowed && !replace) return;
    if (replace) {
      localMemories.removeWhere(
        (m) => m['sourceTurnId'] == turn.id && m['manuallyEdited'] != true,
      );
    }
    if (allowed && !localMemories.any((m) => m['sourceTurnId'] == turn.id)) {
      localMemories.add({
        'id': newTurnId(),
        'sourceTurnId': turn.id,
        'type': 'conversation',
        'summary': content.substring(0, content.length.clamp(0, 280)),
        'content': content,
        'importance': .5,
        'confidence': 1,
        'tags': ['chat-archive'],
        'createdAt': roomMemoryTimestamp(DateTime.now()),
        'updatedAt': roomMemoryTimestamp(DateTime.now()),
      });
    }
    await persist();
    _requireMemoryIdentity(identity);
    changed();
  }

  Future<RoomContextPack> context(
    String text, {
    Map<String, dynamic>? image,
    bool Function()? isCurrent,
  }) async {
    await RoomReference.load();
    final s = c.settings, scope = c.scope, memoryOwner = memoryIdentity;
    void checkCurrent() {
      if (scope != c.scope || _disposed) throw const ApiFailure('账号已切换');
      _requireMemoryIdentity(memoryOwner);
      if (isCurrent?.call() == false) throw const ApiFailure('对话已取消');
    }

    checkCurrent();
    final sections = <String, dynamic>{
      'time': DateTime.now().toIso8601String(),
      'environment': [
        _referenceFacts(currentWorld),
        if (profile.isNotEmpty) '访客资料：\n${_referenceFacts(profile)}',
      ].where((value) => value.isNotEmpty).join('\n'),
    };
    if (s.flag('knowledgeEnabled', true)) {
      final entries = s.options.containsKey('knowledge')
          ? s.rows('knowledge')
          : RoomReference.rows('knowledge');
      final enabled = entries.where((v) => v['enabled'] != false).toList();
      int score(Map v) => '${v['title']} ${v['tags']}'
          .split(RegExp(r'[,，\s]+'))
          .where((t) => t.length > 1 && text.contains(t))
          .length;
      enabled.sort((a, b) => score(b).compareTo(score(a)));
      sections['knowledge'] = enabled
          .take(6)
          .map(
            (v) => {
              'id': v['id'],
              'title': v['title'],
              'content': v['content'],
            },
          )
          .toList();
    }
    if (s.flag('memoryEnabled', true) && usesLocalMemory) {
      final scored =
          localMemories
              .map(
                (m) => {
                  ...m,
                  'score': roomMemoryScore(text, '${m['content']}'),
                },
              )
              .where((m) => (m['score'] as num) > 0)
              .toList()
            ..sort((a, b) => (b['score'] as num).compareTo(a['score'] as num));
      sections['memories'] = scored
          .take(6)
          .map(
            (m) => {
              'id': m['id'],
              'content': roomMemoryExcerpt('${m['content']}', text),
            },
          )
          .toList();
    }
    if (image != null &&
        s.option('visionMode') == 'mcp' &&
        !s.flag('mcpEnabled')) {
      throw const ApiFailure('请先启用 MCP 图片理解，或将图片理解策略改为自动');
    }
    if (!s.demo) {
      await Future.wait(
        [
              'persona-memory?q=${Uri.encodeQueryComponent(text)}&limit=3',
              '../site-feed?limit=20',
            ]
            .where(
              (path) =>
                  !path.startsWith('persona') ||
                  s.flag('knowledgeEnabled', true),
            )
            .map((path) async {
              try {
                final result = await request(
                  'GET',
                  path.startsWith('../')
                      ? '/api/site-feed?limit=20'
                      : '/api/room/$path',
                ).timeout(const Duration(seconds: 2));
                checkCurrent();
                sections[path.startsWith('../')
                    ? 'site'
                    : 'personaMemories'] = path.startsWith('../')
                    ? _siteReferences(result['data'])
                    : jsonRows(result['data']);
              } catch (_) {}
            }),
      );
      checkCurrent();
      if (s.flag('memoryEnabled', true) &&
          online &&
          !usesLocalMemory &&
          c.site is SiteDataService) {
        try {
          final result = await request(
            'GET',
            '/api/room/memory?purpose=chat&limit=6&q=${Uri.encodeQueryComponent(text)}',
          ).timeout(const Duration(seconds: 2));
          checkCurrent();
          sections['memories'] = _memoryReferences(jsonRows(result['data']));
        } catch (_) {
          checkCurrent();
          if (!c.sessionExpired) c.syncStatus = '记忆暂不可用，本轮仍可对话';
        }
      }
      if (online) {
        try {
          final state = jsonMap(
            (await request(
              'GET',
              '/api/growth/me',
            ).timeout(const Duration(seconds: 2)))['data'],
          );
          checkCurrent();
          sections['growth'] = _growthReference(state);
        } catch (_) {}
      }
      checkCurrent();
      if (s.flag('mcpEnabled')) {
        final result = <Map<String, dynamic>>[];
        if (image != null && s.option('visionMode', 'auto') != 'model') {
          try {
            final answer = await tools.tool(s, 'understand_image', {
              'image_url': image['dataUrl'],
              'prompt': text.isEmpty ? '描述图片' : text,
            }, cookie: c.site.cookie);
            checkCurrent();
            if (answer.isNotEmpty) {
              result.add({'id': 'understand_image', 'content': answer});
            }
          } catch (_) {
            if (s.option('visionMode') == 'mcp') {
              throw const ApiFailure('图片理解服务不可用，请检查 MCP 后重试');
            }
          }
          if (s.option('visionMode') == 'mcp' && result.isEmpty) {
            throw const ApiFailure('MCP 图片理解工具未启用');
          }
        }
        if (RegExp(
          r'搜索|查一下|查找|最新|search|新闻',
          caseSensitive: false,
        ).hasMatch(text)) {
          try {
            final answer = await tools.tool(s, 'web_search', {
              'query': text,
            }, cookie: c.site.cookie);
            checkCurrent();
            if (answer.isNotEmpty) {
              result.add({'id': 'web_search', 'content': answer});
            }
          } catch (_) {}
        }
        sections['toolResults'] = result;
      }
    }
    checkCurrent();
    return packRoomContext(
      sections,
      maxChars: roomProtocol(roomChatEndpoint(s.llmUrl)) == 'ollama'
          ? 4000
          : 8000,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    tools.cancel();
    archive.removeListener(changed);
    archive.dispose();
    super.dispose();
  }
}

String _referenceFacts(Map<String, dynamic> values) => values.entries
    .where(
      (item) => item.value != null && item.value is! Map && item.value is! List,
    )
    .map((item) => '${item.key}：${item.value}')
    .join('\n');

String _referenceField(List<dynamic> values) => values
    .map((value) => '${value ?? ''}'.trim())
    .firstWhere((value) => value.isNotEmpty, orElse: () => '');

List<Map<String, dynamic>> _memoryReferences(
  List<Map<String, dynamic>> memories,
) => [
  for (final memory in memories)
    if (_referenceField([
      memory['context'],
      memory['content'],
      memory['summary'],
    ]).isNotEmpty)
      {
        'id': _referenceField([memory['id'], memory['memoryId'], 'memory']),
        'content':
            '[${_referenceField([memory['createdAt'], '历史聊天'])}] '
            '${_referenceField([memory['context'], memory['content'], memory['summary']])}',
      },
];

List<Map<String, dynamic>> _siteReferences(dynamic data) {
  final feed = jsonMap(data);
  final site = jsonMap(feed['site']), stats = jsonMap(feed['stats']);
  final items = data is List ? jsonRows(data) : jsonRows(feed['items']);
  return [
    if (site.isNotEmpty)
      {
        'id': 'site-status',
        'content':
            '月读空间最新公开状况：\n'
            '站点状态：${site['status'] ?? 'online'}；动态更新时间：${feed['updatedAt'] ?? '未知'}。\n'
            '公开统计：文章 ${stats['articles'] ?? 0}，图库 ${stats['galleryItems'] ?? 0}，'
            '像素画 ${stats['pixelArtworks'] ?? 0}，广场留言 ${stats['plazaMessages'] ?? 0}。',
      },
    for (final item in items.take(14))
      {
        'id': item['id'],
        'title': item['title'],
        'content': _referenceField([
          item['summary'],
          item['content'],
          item['text'],
        ]),
      },
  ];
}

String _growthReference(Map<String, dynamic> state) {
  final level = jsonMap(state['level']);
  if (level.isEmpty) return '';
  final pending = jsonRows(jsonMap(state['today'])['tasks'])
      .where((task) => task['completed'] != true)
      .map((task) => '${task['label'] ?? ''}')
      .where((label) => label.isNotEmpty)
      .join('、');
  return [
    '当前用户的月契成长状态（仅在相关话题中自然使用，不要每次主动播报数值）：',
    'Lv.${level['level']}「${level['title']}」，总经验 ${level['totalXp']}，连续相伴 ${jsonMap(state['streak'])['current'] ?? 0} 天。',
    pending.isNotEmpty ? '今日尚未完成：$pending。' : '今日成长任务已经全部完成。',
    '签到和分享是固定任务，第三项会在主舞台、广场、像素画、图库和辉夜快跑中每日轮换。用户询问时再简短引导，不要使用客服式播报。',
  ].join('\n');
}
