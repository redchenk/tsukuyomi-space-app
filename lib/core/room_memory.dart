// Same guest-memory search rules as shared/room-memory-retrieval.cjs in the website.
final sensitiveRoomMemory = RegExp(
  r'password|api[_-]?key|secret|bearer\s+[a-z0-9._-]+|\btoken\b|sk-[a-z0-9._-]+|密码|密钥|令牌|身份证|银行卡',
  caseSensitive: false,
);
List<String> roomSearchTerms(String query) {
  final text = query.toLowerCase();
  final cleaned = text.replaceAll(
    RegExp('还记得|记不记得|之前|以前|请问|什么|那个|一下|告诉|我们|我的|你的'),
    ' ',
  );
  final words = <String>{};
  for (final match in RegExp(
    r'[a-z0-9_]{2,}|[\u4e00-\u9fff]{2,}',
  ).allMatches(cleaned)) {
    final word = match.group(0)!;
    words.add(word);
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(word)) {
      for (var i = 0; i < word.length - 1; i++) {
        words.add(word.substring(i, i + 2));
      }
    }
  }
  for (final entry in {
    '名字|称呼|叫[啥什]|我是谁|name|call me': ['我叫', '叫我', '名字', '称呼', 'name'],
    '喜欢|口味|偏好|爱喝|讨厌|favorite|prefer|like': [
      '喜欢',
      '偏好',
      '讨厌',
      '爱喝',
      'favorite',
      'prefer',
    ],
    '宠物|猫|狗|pet|cat|dog': ['宠物', '猫', '狗', 'pet', 'cat', 'dog'],
    '约定|计划|安排|答应|plan|promise': ['约定', '计划', '安排', '答应', 'plan', 'promise'],
    '生日|纪念日|birthday|anniversary': ['生日', '纪念日', 'birthday', 'anniversary'],
  }.entries) {
    if (RegExp(entry.key).hasMatch(text)) words.addAll(entry.value);
  }
  words.removeAll([
    'the',
    'you',
    'was',
    'are',
    'and',
    'what',
    'remember',
    '之前',
    '记得',
  ]);
  return words.toList();
}

double roomMemoryScore(String query, String content) {
  final terms = roomSearchTerms(query);
  if (terms.isEmpty) return 0;
  final text = content.toLowerCase();
  var score = 0, total = 0;
  for (final term in terms) {
    final weight = term.length.clamp(0, 4);
    total += weight;
    if (text.contains(term)) score += weight;
  }
  return score / total;
}

String roomMemoryExcerpt(String content, String query, {int limit = 760}) {
  if (content.length <= limit) return content;
  final text = content.toLowerCase();
  final anchors = <int>[0];
  for (final term in roomSearchTerms(query)) {
    var at = text.indexOf(term), count = 0;
    while (at >= 0 && count++ < 40) {
      anchors.add(at);
      at = text.indexOf(term, at + term.length);
    }
  }
  var best = 0, score = -1.0;
  for (final anchor in anchors) {
    final start = (anchor - limit ~/ 4).clamp(0, content.length - limit);
    final value = roomMemoryScore(
      query,
      content.substring(start, start + limit),
    );
    if (value > score) {
      best = start;
      score = value;
    }
  }
  return '${best > 0 ? '…' : ''}${content.substring(best, best + limit)}${best + limit < content.length ? '…' : ''}';
}
