import 'room_reference.dart';

/// Replays completed turns instead of maintaining a second mutable state store.
/// Policy text/regexes come from the website's shared/room-dialogue-policy.json.
class RoomDialogue {
  static Map<String, dynamic> get policy => RoomReference.map('dialoguePolicy');
  static bool _matches(String pattern, String text) =>
      RegExp(pattern, caseSensitive: false, unicode: true).hasMatch(text);
  static String _bounded(dynamic value) {
    final text = (value?.toString() ?? '')
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
        .trim();
    final limit = policy['maxTextChars'] as int;
    return text.length <= limit ? text : text.substring(0, limit);
  }

  static Map<String, dynamic> signals(String text) {
    text = _bounded(text);
    final patterns = policy['signals'] as Map;
    final result = <String, dynamic>{
      for (final entry in patterns.entries)
        entry.key as String: _matches(entry.value as String, text),
    };
    if (result['statement'] == true && !_matches('[?？]', text)) {
      result['question'] = false;
    }
    if (result['quoted'] == true) {
      for (final key in result.keys.toList()) {
        if (key != 'quoted') result[key] = false;
      }
    }
    result['topic'] = '';
    if (result['quoted'] != true) {
      for (final topic in policy['topics'] as List) {
        if (_matches(topic['pattern'] as String, text)) {
          result['topic'] = topic['id'];
          break;
        }
      }
    }
    return result;
  }

  static Map<String, dynamic> evaluateReply(String value) {
    final text = _bounded(value);
    final speech = text.replaceAll(
      RegExp(r'```[\s\S]*?```|`[^`]*`|https?:\/\/\S+', caseSensitive: false),
      '',
    );
    final openings = (policy['openings'] as List).cast<String>();
    final patterns = policy['patterns'] as Map;
    return {
      'question': _matches('[?？]', speech),
      'opening': openings.firstWhere(
        (opening) => text.toLowerCase().startsWith(opening.toLowerCase()),
        orElse: () => '',
      ),
      'patterns': [
        for (final entry in patterns.entries)
          if (_matches(entry.value as String, speech)) entry.key as String,
      ],
    };
  }

  static List<Map<String, dynamic>> completedTurns(
    List<Map<String, dynamic>> history,
  ) {
    final max = policy['maxMessages'] as int;
    final tail = history.length > max
        ? history.sublist(history.length - max)
        : history;
    final rows = tail
        .where(
          (row) =>
              row['pending'] != true &&
              row['failed'] != true &&
              ['user', 'assistant'].contains(row['role']) &&
              row['content'] is String &&
              (row['content'] as String).trim().isNotEmpty,
        )
        .toList();
    final turns = <String, Map<String, dynamic>>{};
    for (var i = 0; i < rows.length; i++) {
      final user = rows[i];
      final assistant = i + 1 < rows.length ? rows[i + 1] : null;
      final userId = user['turnId']?.toString() ?? '';
      final assistantId = assistant?['turnId']?.toString() ?? '';
      final paired =
          user['role'] == 'user' &&
          assistant?['role'] == 'assistant' &&
          (userId.isEmpty ||
              assistantId.isEmpty ||
              userId == assistantId ||
              (userId.startsWith('import-') &&
                  assistantId.startsWith('import-')));
      if (paired) {
        final rawId = userId.isNotEmpty
            ? userId
            : assistantId.isNotEmpty
            ? assistantId
            : 'row-$i';
        final id = rawId.length > 160 ? rawId.substring(0, 160) : rawId;
        turns[id] = {
          'id': id,
          'user': _bounded(user['content']),
          'assistant': _bounded(assistant!['content']),
          'createdAt': assistant['createdAt'] ?? user['createdAt'] ?? '',
        };
        i++;
      } else if (user['role'] == 'assistant' &&
          (user['opener'] == true || i == 0)) {
        final rawId = userId.isEmpty ? 'row-$i' : userId;
        final id = rawId.length > 160 ? rawId.substring(0, 160) : rawId;
        turns[id] = {
          'id': id,
          'user': '',
          'assistant': _bounded(user['content']),
          'createdAt': user['createdAt'] ?? '',
        };
      }
    }
    return turns.values.toList();
  }

  static String _advice(Map<String, dynamic> s, String previous) =>
      s['noAdvice'] == true
      ? 'no'
      : s['allowAdvice'] == true || s['help'] == true
      ? 'yes'
      : previous;
  static String _act(Map<String, dynamic> s) {
    if (s['close'] == true && s['help'] != true && s['question'] != true) {
      return 'close';
    }
    if (s['repair'] == true) return 'repair';
    if (s['help'] == true || (s['question'] == true && s['topic'] == 'debug')) {
      return 'answer';
    }
    if (s['close'] == true) return 'close';
    if (s['serious'] == true || s['distress'] == true) return 'acknowledge';
    if (s['recall'] == true) return 'recall';
    if (s['affection'] == true) return 'affection';
    if (s['praise'] == true) return 'receivePraise';
    if (s['opinion'] == true) return 'opinion';
    if (s['question'] == true) return 'answer';
    if (s['positive'] == true) return 'celebrate';
    if (s['play'] == true) return 'banter';
    return 'natural';
  }

  static String _tone(Map<String, dynamic> s, String previous) {
    if (s['serious'] == true || s['noBanter'] == true || s['repair'] == true) {
      return 'serious';
    }
    if (s['distress'] == true) return 'quiet';
    if (s['positive'] == true ||
        s['play'] == true ||
        s['allowBanter'] == true) {
      return 'light';
    }
    return previous;
  }

  static Map<String, dynamic> deriveState(
    List<Map<String, dynamic>> history, {
    int? now,
  }) {
    final turns = completedTurns(history);
    var advice = 'unknown', tone = 'neutral', topic = '', lastAct = 'natural';
    var noQuestions = false, noBanter = false, questionStreak = 0;
    final pending = <String, Map<String, dynamic>>{};
    final openings = <String>[];
    final patterns = <List<String>>[];
    for (final turn in turns) {
      final s = signals(turn['user'] as String);
      final reply = evaluateReply(turn['assistant'] as String);
      advice = _advice(s, advice == 'no' ? 'no' : 'unknown');
      if (s['noQuestions'] == true) {
        noQuestions = true;
      } else if (s['allowQuestions'] == true) {
        noQuestions = false;
      }
      if (s['noBanter'] == true) {
        noBanter = true;
      } else if (s['allowBanter'] == true) {
        noBanter = false;
      }
      tone = _tone(s, tone);
      if (s['close'] == true) {
        topic = '';
        pending.clear();
      }
      if (s['topic'] != '') topic = s['topic'] as String;
      if (s['resolved'] == true) {
        pending.remove(topic);
      } else if (topic.isNotEmpty && s['pending'] == true) {
        pending[topic] = {'topic': topic, 'sourceTurnId': turn['id']};
      }
      questionStreak = reply['question'] == true ? questionStreak + 1 : 0;
      lastAct = reply['question'] == true ? 'ask' : _act(s);
      openings.add(reply['opening'] as String);
      patterns.add((reply['patterns'] as List).cast<String>());
    }
    var date = turns.isEmpty ? '' : turns.last['createdAt'].toString();
    if (RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$').hasMatch(date)) {
      date = '${date.replaceFirst(' ', 'T')}Z';
    }
    final timestamp = DateTime.tryParse(date)?.millisecondsSinceEpoch;
    if (timestamp != null &&
        (now ?? DateTime.now().millisecondsSinceEpoch) - timestamp >
            (policy['toneTtlMs'] as int)) {
      tone = 'neutral';
    }
    final recent = openings
        .skip(openings.length > 4 ? openings.length - 4 : 0)
        .where((s) => s.isNotEmpty)
        .toList();
    final pendingRows = pending.values.toList();
    return {
      'version': policy['version'],
      'completedTurns': turns.length,
      'lastAct': lastAct,
      'questionStreak': questionStreak,
      'tone': tone,
      'topic': topic,
      'advice': advice == 'no' ? 'no' : 'unknown',
      'noQuestions': noQuestions,
      'noBanter': noBanter,
      'recentOpenings': recent,
      'repeatedOpening': recent.any(
        (s) => recent.where((v) => v == s).length > 1,
      ),
      'recentPatterns': patterns
          .skip(patterns.length > 4 ? patterns.length - 4 : 0)
          .expand((items) => items)
          .toSet()
          .toList(),
      'pendingTopics': pendingRows
          .skip(pendingRows.length > 3 ? pendingRows.length - 3 : 0)
          .toList(),
    };
  }

  static Map<String, dynamic> plan({
    required String message,
    List<Map<String, dynamic>> history = const [],
    int? now,
    bool opener = false,
  }) {
    final state = deriveState(history, now: now), s = signals(message);
    final advice = _advice(s, state['advice'] as String);
    final noQuestions =
        s['noQuestions'] == true ||
        (state['noQuestions'] == true && s['allowQuestions'] != true);
    final noBanter =
        s['noBanter'] == true ||
        (state['noBanter'] == true && s['allowBanter'] != true);
    var act = opener ? 'natural' : _act(s);
    final previousTone =
        s['close'] == true ||
            (s['topic'] != '' &&
                state['topic'] != '' &&
                s['topic'] != state['topic'])
        ? 'neutral'
        : state['tone'] as String;
    final tone = noBanter ? 'serious' : _tone(s, previousTone);
    if (act == 'banter' && (noBanter || ['quiet', 'serious'].contains(tone))) {
      act = 'natural';
    }
    final keys = <String>[
      if (advice == 'no') 'noAdvice',
      if (noQuestions)
        'noQuestions'
      else if ((state['questionStreak'] as int) > 0)
        'questionCooldown',
      if (noBanter) 'noBanter',
      if (['light', 'quiet', 'serious'].contains(tone)) tone,
      if (s['brief'] == true) 'brief' else if (s['detail'] == true) 'detail',
      if (state['repeatedOpening'] == true) 'repeatOpening',
      if ((state['recentPatterns'] as List).isNotEmpty) 'repeatPattern',
      if ((state['completedTurns'] as int) > 0) 'continuity',
    ];
    final notes = policy['notes'] as Map;
    return {
      'version': policy['version'],
      'act': act,
      'tone': tone,
      'advice': advice,
      'noQuestions': noQuestions,
      'noBanter': noBanter,
      'topic': s['topic'] != ''
          ? s['topic']
          : s['close'] == true
          ? ''
          : state['topic'],
      'state': state,
      'prompt': [
        notes['intro'],
        (policy['acts'] as Map)[act],
        ...keys.map((k) => notes[k]),
      ].join('\n'),
    };
  }
}
