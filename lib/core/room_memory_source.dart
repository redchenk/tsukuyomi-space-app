import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';

const roomMemoryTypes = {
  'profile',
  'preference',
  'project',
  'episodic',
  'semantic',
  'conversation',
};

String roomMemoryTimestamp(DateTime date) =>
    DateTime.fromMillisecondsSinceEpoch(
      date.millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String();

String guestRoomMemoryFingerprint(List<Map<String, dynamic>> rows) {
  if (rows.isEmpty) return '';
  final records = [
    for (final row in rows)
      {
        'id': '${row['id'] ?? ''}',
        for (final key in [
          'type',
          'summary',
          'content',
          'importance',
          'confidence',
          'tags',
          'createdAt',
          'updatedAt',
        ])
          if (row.containsKey(key)) key: row[key],
      },
  ]..sort((a, b) => '${a['id']}'.compareTo('${b['id']}'));
  return sha256.convert(utf8.encode(jsonEncode(records))).toString();
}

double roomMemoryScoreValue(dynamic value, String name, double fallback) {
  if (value == null) return fallback;
  if (value is! num || !value.isFinite || value < 0 || value > 1) {
    throw ApiFailure('$name 必须是 0 到 1 之间的数字');
  }
  return value.toDouble();
}

Map<String, dynamic> roomMemoryImportRecord(
  Map<String, dynamic> row, {
  int maxContentLength = 12000,
}) {
  final id = '${row['id'] ?? ''}';
  if (id.trim().isEmpty || id.length > 256) {
    throw const ApiFailure('本地记忆的来源标识无效');
  }
  final type = '${row['type'] ?? 'conversation'}';
  if (!roomMemoryTypes.contains(type)) throw const ApiFailure('本地记忆类型无效，请先编辑');
  final summary = '${row['summary'] ?? ''}',
      content = '${row['content'] ?? ''}';
  if (summary.trim().isEmpty || content.trim().isEmpty) {
    throw const ApiFailure('本地记忆摘要和内容不能为空');
  }
  if (summary.length > 800 || content.length > maxContentLength) {
    throw ApiFailure('本地记忆超出长度上限（摘要 800 字、内容 $maxContentLength 字），请先编辑');
  }
  final tags = row['tags'] is List
      ? List<dynamic>.of(row['tags'])
      : <dynamic>[];
  if (tags.length > 12 ||
      tags.any(
        (tag) => tag is! String || tag.trim().isEmpty || tag.length > 80,
      )) {
    throw const ApiFailure('每条记忆最多 12 个标签，每个标签 1 到 80 字');
  }
  String timestamp(String key, [String? fallback]) {
    final raw = row[key];
    if (raw == null || '$raw'.isEmpty) {
      return fallback ?? '1970-01-01T00:00:00.000Z';
    }
    if (!RegExp(
      r'^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})?$',
    ).hasMatch('$raw')) {
      throw ApiFailure('$key 时间无效');
    }
    final calendar = '$raw'.substring(0, 10).split('-').map(int.parse).toList();
    final validDate = DateTime.utc(calendar[0], calendar[1], calendar[2]);
    if (validDate.year != calendar[0] ||
        validDate.month != calendar[1] ||
        validDate.day != calendar[2]) {
      throw ApiFailure('$key 时间无效');
    }
    final date = DateTime.tryParse('$raw');
    if (date == null ||
        date.millisecondsSinceEpoch < 0 ||
        date.isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
      throw ApiFailure('$key 时间无效');
    }
    return roomMemoryTimestamp(date);
  }

  final created = timestamp('createdAt'),
      updated = timestamp('updatedAt', created);
  if (updated.compareTo(created) < 0) {
    throw const ApiFailure('updatedAt 不能早于 createdAt');
  }
  return {
    'id': id,
    'type': type,
    'summary': summary,
    'content': content,
    'importance': roomMemoryScoreValue(row['importance'], 'importance', .5),
    'confidence': roomMemoryScoreValue(row['confidence'], 'confidence', .8),
    'tags': tags,
    'createdAt': created,
    'updatedAt': updated,
  };
}

/// Validate every record before the first request. Each original-site import
/// stays below its 1 MB parser limit, with at most 100 rows and 700 KB of data.
List<List<Map<String, dynamic>>> roomMemoryImportBatches(
  List<Map<String, dynamic>> rows, {
  int maxContentLength = 12000,
}) {
  final batches = <List<Map<String, dynamic>>>[];
  var batch = <Map<String, dynamic>>[], size = 0;
  for (final row in rows) {
    final record = roomMemoryImportRecord(
      row,
      maxContentLength: maxContentLength,
    );
    final bytes = utf8.encode(jsonEncode(record)).length;
    if (bytes > 700000) {
      throw const ApiFailure('单条本地记忆超过导入请求上限，请先编辑。原数据仍保留。');
    }
    if (batch.isNotEmpty && (batch.length >= 100 || size + bytes > 700000)) {
      batches.add(batch);
      batch = [];
      size = 0;
    }
    batch.add(record);
    size += bytes;
  }
  if (batch.isNotEmpty) batches.add(batch);
  return batches;
}
