import 'dart:math' as math;

/// Mirrors the website's `selectRecentRoomConversation` prompt budget.
///
/// The latest request is sent separately. Long history messages retain their
/// beginning and ending, and a budget cut never leaves a paired answer as the
/// first message without its question. Assistant openers remain valid.
List<Map<String, String>> selectRecentRoomConversation(
  List<Map<String, String>> history, {
  int maxChars = 6000,
  int maxMessages = 12,
}) {
  final budget = (maxChars == 0 ? 6000 : maxChars).clamp(500, 30000);
  final count = (maxMessages == 0 ? 12 : maxMessages).clamp(1, 40);
  final source = history
      .where(
        (item) =>
            ['user', 'assistant'].contains(item['role']) &&
            (item['content'] ?? '').isNotEmpty,
      )
      .toList();
  final selected = <Map<String, String>>[];
  var used = 0;
  for (
    var index = source.length - 1;
    index >= 0 && selected.length < count;
    index--
  ) {
    final item = source[index];
    final raw = (item['content'] ?? '')
        .replaceAll(
          RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]'),
          '',
        )
        .trim();
    final perMessage = math.min(2500, budget - used);
    if (perMessage < 100) break;
    final content = raw.length <= perMessage
        ? raw
        : '${raw.substring(0, math.max(50, perMessage ~/ 2 - 15))}'
              '\n[较早内容省略]\n'
              '${raw.substring(raw.length - ((perMessage + 1) ~/ 2 - 15))}';
    if (content.isEmpty) continue;
    selected.insert(0, {
      'role': item['role']!,
      'content': content,
      'turnId': item['turnId'] ?? '',
    });
    used += content.length;
    if (used >= budget) break;
  }
  if (selected.isNotEmpty && selected.first['role'] == 'assistant') {
    final turnId = selected.first['turnId'];
    final first = source.indexWhere(
      (item) =>
          (item['turnId'] ?? '').isNotEmpty &&
          item['turnId'] == turnId &&
          item['role'] == 'assistant',
    );
    if (first > 0 &&
        source[first - 1]['role'] == 'user' &&
        source[first - 1]['turnId'] == turnId) {
      selected.removeAt(0);
    }
  }
  return selected;
}
