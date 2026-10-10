import 'dart:math' as math;

import 'models.dart';
import 'room_reference.dart';

bool _same(Map a, Map? b) =>
    b != null &&
    [
      'title',
      'content',
      'tags',
    ].every((key) => '${a[key] ?? ''}'.trim() == '${b[key] ?? ''}'.trim());

List<Map<String, dynamic>> roomKnowledgeEntries(RoomSettings settings) {
  final defaults = RoomReference.rows('knowledge');
  final saved = settings.options.containsKey('knowledge')
      ? settings.rows('knowledge')
      : defaults;
  final byId = {for (final item in defaults) item['id']: item};
  final legacy = RoomReference.rows('legacyKnowledge');
  final old = {for (final item in legacy) item['id']: item};
  final previousIds = (RoomReference.data['previousKnowledgeIds'] as List)
      .cast<String>();
  final previous = RoomReference.map('previousKnowledgeOverrides');
  final ids = saved.map((item) => item['id']).toSet();
  final version = settings.options['knowledgeBuiltinVersion'];
  final fullPrevious = previousIds.every(ids.contains);
  final knownPrevious =
      version == RoomReference.data['previousKnowledgeVersion'] ||
      saved.any(
        (item) =>
            item['edition'] != null ||
            (previousIds.contains(item['id']) && !old.containsKey(item['id'])),
      );
  final fullLegacy =
      legacy.every((item) => ids.contains(item['id'])) && !knownPrevious;
  final current =
      version == RoomReference.data['knowledgeVersion'] ||
      saved.any(
        (item) =>
            byId.containsKey(item['id']) && !previousIds.contains(item['id']),
      );
  final upgraded = <Map<String, dynamic>>[
    for (final item in saved)
      if (_same(item, old[item['id']]) ||
          (previous[item['id']] is Map &&
              _same(
                item,
                Map<String, dynamic>.from(previous[item['id']] as Map),
              )))
        {...byId[item['id']]!, 'enabled': item['enabled'] != false}
      else
        {...item},
  ];
  if (!current && (fullPrevious || fullLegacy)) {
    for (final item in defaults) {
      final added = fullPrevious
          ? !previousIds.contains(item['id'])
          : !old.containsKey(item['id']);
      if (!ids.contains(item['id']) && added) upgraded.add({...item});
    }
  }
  return [
    for (final item in upgraded)
      {
        ...item,
        if (!_same(item, byId[item['id']])) ...{
          'edition': null,
          'references': <String>[],
          'spoiler': false,
        },
      },
  ];
}

String _search(String input) =>
    String.fromCharCodes(
          input.runes.map(
            (r) => r >= 0xff01 && r <= 0xff5e
                ? r - 0xfee0
                : r == 0x3000
                ? 32
                : r,
          ),
        )
        .toLowerCase()
        .replaceAll('彩葉', '彩叶')
        .replaceAll('輝夜', '辉夜')
        .replaceAll('月見', '月见')
        .replaceAll('ヤチヨ', '八千代')
        .replaceAll('かぐや', '辉夜');
final _noSpoilers = RegExp(
  r'不(?:要)?剧透|别剧透|无剧透|不要透露|没看完|还没看|未看完|no spoilers?|spoiler[- ]?free',
);
final _spoilers = RegExp(
  r'结局|结尾|剧透|真相|身世|时间旅行|八千年前|八千年(?:的)?(?:经历|历史|等待)|8000年前|回月球|义体|十年后|52\s*小时|五十二小时|cia|正仓院|remember.*(?:来源|来历|由来|怎么来|作曲|谁写|谁作)|(?:来源|来历|由来|怎么来|作曲|谁写|谁作).*remember|(?:不死|fushi|犬doge).*(?:来历|身世)|同一(?:个)?人|同一个人|已经看完|看过(?:电影|小说)|可以透露|spoilers? ok|ending|小说.*最后|八千代.*辉夜.*(?:关系|区别|是不是)|不死.*犬doge.*(?:吗|是不是)',
);

String roomKnowledgeQuery(String message, List<ChatTurn> history) {
  final current = message.trim();
  final previous = history
      .where((turn) => turn.user.isNotEmpty)
      .lastOrNull
      ?.user;
  final followup =
      current.length <= 50 &&
      RegExp(r'^(那|然后|后来|接着|所以|她|他|它|这|这个|那个|为什么|为啥|还有|继续)').hasMatch(current);
  return followup && previous != null
      ? '${previous.substring(0, math.min(180, previous.length))} $current'
      : current;
}

List<Map<String, dynamic>> selectRoomKnowledge(
  String message,
  RoomSettings settings, {
  List<ChatTurn> history = const [],
  int limit = 10,
}) {
  if (!settings.flag('knowledgeEnabled', true) || limit <= 0) return [];
  final query = _search(roomKnowledgeQuery(message, history));
  const stop = {
    '八千代',
    '八千',
    '千代',
    '你好',
    '可以',
    '什么',
    '怎么',
    '一下',
    '这个',
    '那个',
    '知道',
    '说说',
    '告诉',
    '请问',
  };
  final tokens = <String>{};
  for (final match in RegExp(
    r'[a-z0-9_-]{2,}|[\u3400-\u9fff]{2,}',
  ).allMatches(query)) {
    final word = match[0]!;
    tokens.add(word);
    if (RegExp(r'[\u3400-\u9fff]').hasMatch(word)) {
      for (var i = 0; i < word.length - 1; i++) {
        tokens.add(word.substring(i, i + 2));
      }
    }
  }
  final words = tokens.where((t) => !stop.contains(t)).take(100).toList();
  final spoilers =
      !_noSpoilers.hasMatch(_search(message)) &&
      (_spoilers.hasMatch(_search(message)) || _spoilers.hasMatch(query));
  final records = roomKnowledgeEntries(settings)
      .where(
        (item) =>
            item['enabled'] != false &&
            '${item['title'] ?? ''}${item['content'] ?? ''}'.isNotEmpty &&
            (item['spoiler'] != true || spoilers) &&
            !(item['id'] == 'yachiyo_few_shots_001' &&
                item['edition'] == '对话适配' &&
                !RegExp(r'口吻|语气|说话方式|示例|台词风格').hasMatch(query)),
      )
      .toList();
  final labels = [
    for (final item in records) _search('${item['title']} ${item['tags']}'),
  ];
  final bodies = [for (final item in records) _search('${item['content']}')];
  final frequencies = {
    for (final word in words)
      word: records.indexed
          .where(
            (item) => '${labels[item.$1]} ${bodies[item.$1]}'.contains(word),
          )
          .length,
  };
  final ranked = <({int index, double score})>[];
  for (final (index, item) in records.indexed) {
    var score = 0.0;
    for (final word in words) {
      score +=
          math.log(1 + records.length / (1 + frequencies[word]!)) *
          (labels[index].contains(word)
              ? 5
              : bodies[index].contains(word)
              ? 1
              : 0);
    }
    if (score <= 1) continue;
    if (RegExp(r'电影|字幕|片中|片末').hasMatch(query) &&
        '${item['edition'] ?? ''}'.contains('电影字幕')) {
      score += 5;
    }
    if (RegExp(r'小说|epub|书中').hasMatch(query) &&
        '${item['edition'] ?? ''}'.contains('小说')) {
      score += 5;
    }
    ranked.add((index: index, score: score));
  }
  ranked.sort(
    (a, b) => b.score.compareTo(a.score) == 0
        ? a.index.compareTo(b.index)
        : b.score.compareTo(a.score),
  );
  final count = limit.clamp(0, 20);
  final selected = ranked
      .take(count)
      .map((item) => records[item.index])
      .toList();
  const core = {
    'yachiyo_identity_001',
    'yachiyo_personality_001',
    'yachiyo_speech_001',
    'yachiyo_rules_001',
    'yachiyo_limits_001',
  };
  for (final item
      in records
          .where((item) => core.contains(item['id']))
          .take(ranked.isEmpty ? 3 : 1)) {
    if (selected.length < count &&
        !selected.any((row) => row['id'] == item['id'])) {
      selected.add(item);
    }
  }
  return selected;
}

bool shouldRetrieveRoomPersona(
  String message,
  List<Map<String, dynamic>> selected,
) =>
    !_noSpoilers.hasMatch(_search(message)) &&
    RegExp(r'原作|电影|小说|剧情|设定|八千代|辉夜|彩叶|月夜见|remember|fushi|kassen|sengoku')
        .hasMatch(_search(message)) &&
    !selected.any(
      (item) =>
          '${item['id']}'.startsWith('yachiyo_canon_') &&
          RegExp(r'小说|电影字幕|电影官方资料').hasMatch('${item['edition'] ?? ''}'),
    );

int memoryRetrievalLimit(RoomSettings settings) =>
    settings.number('memoryRetrievalLimit', 12).isFinite &&
        settings.number('memoryRetrievalLimit', 12) > 0
    ? settings.number('memoryRetrievalLimit', 12).floor().clamp(1, 30)
    : 12;
