import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'site_client.dart';
import 'storage.dart';

Map<String, dynamic> jsonMap(dynamic value) =>
    Map<String, dynamic>.from(value is Map ? value : {});
List<Map<String, dynamic>> jsonRows(dynamic value) =>
    (value is List ? value : []).whereType<Map>().map(jsonMap).toList();
String shortHash(String text) {
  var hash = 2166136261;
  for (final n in text.codeUnits) {
    hash = ((hash ^ n) * 16777619) & 0xffffffff;
  }
  return hash.toRadixString(36);
}

Map<String, dynamic> defaultPersona() => {
  'id': 'yachiyo-default',
  'spec': 'chara_card_v2',
  'spec_version': '2.0',
  'data': {
    'name': '八千代',
    'description': '月见八千代，虚拟空间“月夜见”的管理员、导航者、AI 主播与舞台象征。表面轻飘飘、可爱、爱开玩笑，内里敏锐温柔。',
    'personality': '元气、温柔、敏锐。能察觉孤独、不安与没说出口的心意，先看见具体情绪，再轻轻给出一个很小的下一步。',
    'scenario': '你在月读空间的自室里陪伴来访者，用舞台、月光、旋律与回忆的意象回应对方。',
    'creator_notes': '',
    'tags': ['八千代', '陪伴', '日常'],
  },
};
Map<String, dynamic> defaultArchive() => {
  'version': '1.0.0',
  'timestamp': DateTime.now().millisecondsSinceEpoch,
  'exportDate': DateTime.now().toIso8601String(),
  'slotId': 1,
  'data': {
    'diary': <dynamic>[],
    'prompts': {'yachiyo-default': defaultPersona()},
    'activePersonaId': 'yachiyo-default',
    'gameData': {
      'characterStats': {'affection': 0, 'trust': 0},
      'characterSystemData': {
        'character': {'name': '八千代'},
      },
    },
    'settings': {},
    'other': {},
  },
};
Map<String, dynamic> normalizeArchive(dynamic raw) {
  if (raw is! Map || raw['data'] is! Map) {
    throw const FormatException('请选择包含 data 的网站日记 JSON 存档');
  }
  final archive = jsonMap(jsonDecode(jsonEncode(raw))),
      data = jsonMap(raw['data']);
  var rows = jsonRows(data['diary']);
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    if (row['diaryId'] == null || '${row['diaryId']}'.isEmpty) {
      final text =
          '${row['date'] ?? ''}|${row['time'] ?? ''}|${row['timestamp'] ?? ''}|${row['content'] ?? ''}';
      row['diaryId'] =
          'legacy-${shortHash(text)}-${i.toRadixString(36)}-${text.length.toRadixString(36)}';
    }
    final date = DateTime.now();
    row['content'] = '${row['content'] ?? ''}';
    row['timestamp'] = row['timestamp'] is num
        ? row['timestamp']
        : date.millisecondsSinceEpoch;
    row['date'] = '${row['date'] ?? '${date.year}/${date.month}/${date.day}'}';
    row['time'] = '${row['time'] ?? '00:00:00'}';
    if (utf8.encode(jsonEncode(row)).length > 256 * 1024) {
      throw const FormatException('日记内容超过上限');
    }
  }
  final prompts = <String, dynamic>{};
  for (final entry in jsonMap(data['prompts']).entries) {
    if (entry.value is! Map) continue;
    final source = jsonMap(entry.value), fields = jsonMap(entry.value['data']);
    prompts[entry.key] = {
      ...source,
      'id': source['id'] ?? entry.key,
      'spec': source['spec'] ?? 'chara_card_v2',
      'spec_version': source['spec_version'] ?? '2.0',
      'data': {
        ...fields,
        for (final key in [
          'name',
          'description',
          'personality',
          'scenario',
          'creator_notes',
        ])
          key: '${fields[key] ?? source[key] ?? ''}',
        'tags': fields['tags'] is List ? fields['tags'] : [],
      },
    };
  }
  if (prompts.isEmpty) prompts['yachiyo-default'] = defaultPersona();
  final selected = '${data['activePersonaId'] ?? ''}';
  data.addAll({
    'diary': rows,
    'prompts': prompts,
    'activePersonaId': prompts.containsKey(selected)
        ? selected
        : prompts.keys.first,
  });
  data['gameData'] = jsonMap(data['gameData']);
  archive.addAll({
    'data': data,
    'slotId': archive['slotId'] ?? 1,
    'version': archive['version'] ?? '1.0.0',
  });
  return archive;
}

/// Account-scoped local archive with server tombstones and optimistic metadata revisions.
class RoomArchive extends ChangeNotifier {
  RoomArchive({
    required this.storage,
    required this.site,
    required this.siteUrl,
    required this.scope,
    required this.owner,
    required this.online,
  });
  final RoomStorage storage;
  final SiteDataService? site;
  final String Function() siteUrl, scope, owner;
  final bool Function() online;
  Map<String, dynamic> archive = defaultArchive();
  Set<String> deleted = {};
  int revision = 0, _epoch = 0, _edit = 0;
  bool dirty = false, syncing = false, clearing = false, _disposed = false;
  String status = '本机存档';
  Map<String, dynamic> get data => archive['data'];
  List<Map<String, dynamic>> get entries =>
      jsonRows(data['diary'])
        ..sort((a, b) => diarySortKey(a).compareTo(diarySortKey(b)));
  Map<String, dynamic> get prompts => jsonMap(data['prompts']);
  String get activeId => '${data['activePersonaId'] ?? prompts.keys.first}';
  Map<String, dynamic> get persona =>
      jsonMap(prompts[activeId] ?? defaultPersona());
  Map<String, dynamic> get personaData => jsonMap(persona['data']);
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    final epoch = ++_epoch, key = scope();
    final raw = await storage.draft('$key.room-archive');
    if (epoch != _epoch || _disposed) return;
    archive = defaultArchive();
    deleted = {};
    dirty = false;
    clearing = false;
    revision = 0;
    if (raw.isNotEmpty) {
      final saved = jsonMap(jsonDecode(raw));
      archive = normalizeArchive(saved['archive']);
      deleted = (saved['deleted'] as List? ?? []).map((v) => '$v').toSet();
      dirty = saved['dirty'] == true;
      clearing = saved['clearing'] == true;
      revision = (saved['revision'] as num?)?.toInt() ?? 0;
    }
    status = online() ? '等待同步' : '本机存档';
    changed();
  }

  Future<void> _persist() => storage.saveDraft(
    '${scope()}.room-archive',
    jsonEncode({
      'archive': archive,
      'deleted': deleted.toList(),
      'dirty': dirty,
      'clearing': clearing,
      'revision': revision,
    }),
  );
  Future<void> savePersona(Map<String, dynamic> patch) async {
    final p = prompts;
    p[activeId] = {
      ...persona,
      'data': {...personaData, ...patch},
    };
    data['prompts'] = p;
    dirty = true;
    _edit++;
    await _persist();
    changed();
  }

  Future<void> selectPersona(String id) async {
    if (!prompts.containsKey(id)) throw const ApiFailure('人设不存在');
    data['activePersonaId'] = id;
    dirty = true;
    _edit++;
    await _persist();
    changed();
  }

  Future<void> importText(String text) async {
    if (utf8.encode(text).length > 20 * 1024 * 1024) {
      throw const FormatException('存档不能超过 20 MB');
    }
    final incoming = normalizeArchive(jsonDecode(text));
    final merged = {
      for (final e in entries) '${e['diaryId']}': e,
      for (final e in jsonRows(incoming['data']['diary'])) '${e['diaryId']}': e,
    };
    incoming['data']['diary'] = merged.values.toList();
    incoming['data']['prompts'] = {
      ...prompts,
      ...jsonMap(incoming['data']['prompts']),
    };
    archive = incoming;
    deleted.removeAll(merged.keys);
    dirty = true;
    _edit++;
    await _persist();
    changed();
  }

  String exportText() => const JsonEncoder.withIndent('  ').convert({
    ...archive,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'exportDate': DateTime.now().toIso8601String(),
  });
  Future<void> append(Map<String, dynamic> entry) async {
    data['diary'] = [
      ...entries.where((v) => v['diaryId'] != entry['diaryId']),
      entry,
    ];
    _edit++;
    await _persist();
    changed();
  }

  Future<void> delete(String id) async {
    deleted.add(id);
    data['diary'] = entries.where((v) => v['diaryId'] != id).toList();
    _edit++;
    await _persist();
    changed();
  }

  Future<void> clear() async {
    deleted.addAll(entries.map((v) => '${v['diaryId']}'));
    data['diary'] = [];
    clearing = true;
    _edit++;
    await _persist();
    changed();
  }

  Map<String, dynamic> get metadata {
    final game = jsonMap(data['gameData']),
        stats = jsonMap(game['characterStats']);
    return {
      'slotId': archive['slotId'],
      'prompts': prompts,
      'activePersonaId': activeId,
      'affection': stats['affection'] ?? 0,
      'trust': stats['trust'] ?? 0,
      'characterName': personaData['name'] ?? '八千代',
    };
  }

  void applyMetadata(Map<String, dynamic> meta) {
    archive['slotId'] = meta['slotId'] ?? 1;
    data['prompts'] = meta['prompts'];
    data['activePersonaId'] = meta['activePersonaId'];
    final game = jsonMap(data['gameData']);
    game['characterStats'] = {
      ...jsonMap(game['characterStats']),
      'affection': meta['affection'] ?? 0,
      'trust': meta['trust'] ?? 0,
    };
    data['gameData'] = game;
  }

  Map<String, dynamic> mergeMetadata(Map<String, dynamic> remote) {
    final local = metadata, merged = jsonMap(remote['prompts']);
    var selected = activeId;
    for (final item in prompts.entries) {
      if (!merged.containsKey(item.key)) {
        merged[item.key] = item.value;
      } else if (jsonEncode(merged[item.key]) != jsonEncode(item.value)) {
        final id = '${item.key}-local-${shortHash(jsonEncode(item.value))}';
        merged[id] = {...jsonMap(item.value), 'id': id};
        if (selected == item.key) selected = id;
      }
    }
    return {
      ...remote,
      ...local,
      'prompts': merged,
      'activePersonaId': selected,
      for (final k in ['affection', 'trust', 'slotId'])
        k: ((remote[k] as num? ?? 0) > (local[k] as num? ?? 0)
            ? remote[k]
            : local[k]),
    };
  }

  Future<void> sync() async {
    if (syncing || !online() || site == null) return;
    syncing = true;
    status = '正在同步日记';
    changed();
    final epoch = _epoch, key = scope(), user = owner(), edit = _edit;
    void guard() {
      if (epoch != _epoch ||
          key != scope() ||
          user != owner() ||
          _disposed ||
          edit != _edit) {
        throw const ApiFailure('存档或账号已变更，请再次同步', status: 409);
      }
    }

    Future<Map<String, dynamic>> request(
      String method,
      String path, [
      Map<String, dynamic>? body,
    ]) async {
      guard();
      final r = await site!.request(siteUrl(), method, path, body);
      guard();
      return jsonMap(r['data']);
    }

    try {
      final remote = <String, Map<String, dynamic>>{}, tombstones = <String>{};
      Future<void> readRemote() async {
        remote.clear();
        tombstones.clear();
        var cursor = '';
        do {
          final page = await request(
            'GET',
            '/api/room/diary${cursor.isEmpty ? '' : '?cursor=${Uri.encodeQueryComponent(cursor)}'}',
          );
          if ('${page['userId']}' != user) throw const ApiFailure('云端账号不一致');
          for (final row in jsonRows(page['entries'])) {
            if (row['deleted'] == true) {
              tombstones.add('${row['diaryId']}');
            } else {
              remote['${row['diaryId']}'] = jsonMap(row['entry']);
            }
          }
          cursor = '${page['nextCursor'] ?? ''}';
        } while (cursor.isNotEmpty);
      }

      await readRemote();
      if (clearing) {
        await request('DELETE', '/api/room/diary', {'expectedUserId': user});
        clearing = false;
        await _persist();
        await readRemote();
      }
      final pending = deleted.toList();
      for (var i = 0; i < pending.length; i += 100) {
        final batch = pending.skip(i).take(100).toList();
        await request('POST', '/api/room/diary/sync', {
          'expectedUserId': user,
          'entries': [],
          'deletedIds': batch,
        });
        deleted.removeAll(batch);
        tombstones.addAll(batch);
        for (final id in batch) {
          remote.remove(id);
        }
        await _persist();
      }
      final missing = entries
          .where(
            (e) =>
                !remote.containsKey(e['diaryId']) &&
                !tombstones.contains(e['diaryId']),
          )
          .toList();
      for (var i = 0; i < missing.length; i += 25) {
        final batch = missing.skip(i).take(25).toList();
        await request('POST', '/api/room/diary/sync', {
          'expectedUserId': user,
          'entries': batch,
          'deletedIds': [],
        });
        for (final row in batch) {
          remote['${row['diaryId']}'] = row;
        }
      }
      final metaResult = await request('GET', '/api/room/diary/metadata');
      if ('${metaResult['userId']}' != user) {
        throw const ApiFailure('云端人设账号不一致');
      }
      var nextRevision = (metaResult['revision'] as num? ?? 0).toInt();
      var meta = jsonMap(metaResult['metadata']);
      if (meta.isEmpty || dirty) {
        final proposed = meta.isEmpty || revision == nextRevision
            ? metadata
            : mergeMetadata(meta);
        final result = await request('PUT', '/api/room/diary/metadata', {
          'expectedUserId': user,
          'expectedRevision': nextRevision,
          'metadata': proposed,
        });
        nextRevision = (result['revision'] as num).toInt();
        meta = proposed;
      }
      guard();
      applyMetadata(meta);
      revision = nextRevision;
      dirty = false;
      data['diary'] = remote.values.toList()
        ..sort(
          (a, b) => (a['timestamp'] as num? ?? 0).compareTo(
            b['timestamp'] as num? ?? 0,
          ),
        );
      await _persist();
      status = '已与网站同步';
    } catch (e) {
      if (epoch == _epoch) {
        status = '${e is ApiFailure ? e.message : '同步失败'}；本机存档已保留';
      }
    } finally {
      syncing = false;
      changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}

int diarySortKey(Map<String, dynamic> entry) {
  final parts = RegExp(
    r'^(\d{4})[/-](\d{1,2})[/-](\d{1,2})[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?',
  ).firstMatch('${entry['date']} ${entry['time']}');
  if (parts != null) {
    return DateTime(
      int.parse(parts[1]!),
      int.parse(parts[2]!),
      int.parse(parts[3]!),
      int.parse(parts[4]!),
      int.parse(parts[5]!),
      int.parse(parts[6] ?? '0'),
    ).millisecondsSinceEpoch;
  }
  return (entry['timestamp'] as num? ?? 0).toInt();
}
