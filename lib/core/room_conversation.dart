import 'dart:math' as math;

/// Select complete exchanges before applying the website's prompt budget.
/// Old assistant messages never become an unfinished request after trimming.
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
  String clean(String value) => value
      .replaceAll(RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]'), '')
      .trim();
  String bounded(String text, int limit) {
    if (text.length <= limit) return text;
    const marker = '\n[较早内容省略]\n';
    final head = ((limit - marker.length) / 2).ceil();
    return '${text.substring(0, head)}$marker${text.substring(text.length - (limit - marker.length - head))}';
  }

  for (var index = source.length - 1; index >= 0 && selected.length < count;) {
    final item = source[index];
    final question = index > 0 ? source[index - 1] : null;
    final paired =
        item['role'] == 'assistant' &&
        question?['role'] == 'user' &&
        ((item['turnId'] ?? '').isEmpty ||
            (question?['turnId'] ?? '').isEmpty ||
            item['turnId'] == question?['turnId']);
    final group = paired ? [question!, item] : [item];
    index -= group.length;
    if (item['role'] == 'assistant' &&
        !paired &&
        !(source.length == 1 || item['opener'] == 'true')) {
      continue;
    }
    if (selected.length + group.length > count) break;
    final raw = group.map((part) => clean(part['content'] ?? '')).toList();
    final sizes = raw.map((text) => math.min(2500, text.length)).toList();
    final remaining = budget - used;
    if (sizes.reduce((a, b) => a + b) > remaining) {
      if (selected.isNotEmpty || remaining < 100 * group.length) break;
      if (group.length == 2) {
        sizes[0] = math.min(sizes[0], math.max(100, remaining ~/ 2));
        sizes[1] = math.min(sizes[1], remaining - sizes[0]);
        sizes[0] = math.min(raw[0].length, remaining - sizes[1]);
      } else {
        sizes[0] = remaining;
      }
    }
    final exchange = [
      for (final (i, part) in group.indexed)
        {
          'role': part['role']!,
          'content': bounded(raw[i], sizes[i]),
          'turnId': part['turnId'] ?? '',
        },
    ];
    selected.insertAll(0, exchange);
    used += exchange.fold(0, (sum, part) => sum + part['content']!.length);
  }
  return selected;
}
