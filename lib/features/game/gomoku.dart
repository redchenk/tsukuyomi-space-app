import 'dart:convert';

/// Freestyle rules and bounded AI matching the website gomoku.mjs contract.
class Gomoku {
  Gomoku({this.human = 1, this.difficulty = 'casual'});
  final int human;
  final String difficulty;
  final board = List<int>.filled(225, 0);
  final moves = <int>[];
  int turn = 1, winner = 0;
  List<int> line = [];
  bool get draw => winner == 0 && moves.length == 225;
  static const directions = [(1, 0), (0, 1), (1, 1), (1, -1)];
  static bool inside(int r, int c) => r >= 0 && r < 15 && c >= 0 && c < 15;
  static String coordinate(int index) =>
      '${'ABCDEFGHIJKLMNO'[index % 15]}${15 - index ~/ 15}';
  static List<int> winningLine(List<int> board, int index) {
    final stone = board[index];
    if (stone == 0) return [];
    for (final (dr, dc) in directions) {
      final line = [index];
      for (final sign in [-1, 1]) {
        var r = index ~/ 15 + dr * sign, c = index % 15 + dc * sign;
        while (inside(r, c) && board[r * 15 + c] == stone) {
          line.add(r * 15 + c);
          r += dr * sign;
          c += dc * sign;
        }
      }
      if (line.length >= 5) return line;
    }
    return [];
  }

  bool play(int index) {
    if (index < 0 || index >= 225 || board[index] != 0 || winner != 0 || draw) {
      return false;
    }
    board[index] = turn;
    moves.add(index);
    line = winningLine(board, index);
    if (line.isNotEmpty) winner = turn;
    turn = 3 - turn;
    return true;
  }

  void undo() {
    final index = moves.lastIndexWhere((move) => board[move] == human);
    if (index < 0) return;
    final keep = moves.take(index).toList();
    board.fillRange(0, 225, 0);
    moves.clear();
    turn = 1;
    winner = 0;
    line = [];
    for (final move in keep) {
      play(move);
    }
  }

  String save() => jsonEncode({
    'version': 1,
    'human': human,
    'difficulty': difficulty,
    'moves': moves,
  });
  static Gomoku? restore(String raw) {
    try {
      final data = jsonDecode(raw);
      if (data is! Map ||
          data['version'] != 1 ||
          ![1, 2].contains(data['human']) ||
          !['casual', 'challenge'].contains(data['difficulty']) ||
          data['moves'] is! List ||
          data['moves'].length > 225) {
        return null;
      }
      final game = Gomoku(human: data['human'], difficulty: data['difficulty']);
      for (final index in data['moves']) {
        if (index is! int || !game.play(index)) return null;
      }
      return game;
    } catch (_) {
      return null;
    }
  }

  static List<int> candidates(List<int> board) {
    final result = <int>{};
    for (var i = 0; i < 225; i++) {
      if (board[i] == 0) continue;
      for (var dr = -2; dr <= 2; dr++) {
        for (var dc = -2; dc <= 2; dc++) {
          final r = i ~/ 15 + dr, c = i % 15 + dc;
          if (inside(r, c) && board[r * 15 + c] == 0) result.add(r * 15 + c);
        }
      }
    }
    return result.isNotEmpty
        ? result.toList()
        : board.any((s) => s != 0)
        ? []
        : [112];
  }

  static int attackScore(List<int> board, int index, int stone) {
    var score = 0;
    board[index] = stone;
    for (final (dr, dc) in directions) {
      var count = 1, open = 0;
      for (final sign in [-1, 1]) {
        var r = index ~/ 15 + dr * sign, c = index % 15 + dc * sign;
        while (inside(r, c) && board[r * 15 + c] == stone) {
          count++;
          r += dr * sign;
          c += dc * sign;
        }
        if (inside(r, c) && board[r * 15 + c] == 0) open++;
      }
      if (count >= 5) {
        score += 1000000;
      } else if (open > 0) {
        score += [0, 2, 30, 700, 25000][count] * (open == 2 ? 6 : 1);
      }
      for (var offset = -4; offset <= 0; offset++) {
        var own = 0, valid = true;
        for (var n = 0; n < 5; n++) {
          final r = index ~/ 15 + dr * (offset + n),
              c = index % 15 + dc * (offset + n);
          if (!inside(r, c) ||
              board[r * 15 + c] != 0 && board[r * 15 + c] != stone) {
            valid = false;
            break;
          }
          if (board[r * 15 + c] == stone) own++;
        }
        if (valid) score += [0, 0, 3, 30, 900, 0][own];
      }
    }
    board[index] = 0;
    return score;
  }

  static List<({int index, int attack, int defense, double score})> rank(
    List<int> board,
    int stone,
  ) {
    final ranked = candidates(board).map((i) {
      final a = attackScore(board, i, stone),
          d = attackScore(board, i, 3 - stone);
      return (
        index: i,
        attack: a,
        defense: d,
        score: a + d * 1.08 + 14 - (i ~/ 15 - 7).abs() - (i % 15 - 7).abs(),
      );
    }).toList();
    ranked.sort((a, b) {
      final diff = b.score.compareTo(a.score);
      return diff != 0 ? diff : a.index.compareTo(b.index);
    });
    return ranked;
  }

  int? choose() {
    if (winner != 0 || draw) return null;
    final ranked = rank(board, turn);
    if (ranked.isEmpty) return null;
    for (final m in ranked) {
      if (m.attack >= 1000000) return m.index;
    }
    for (final m in ranked) {
      if (m.defense >= 1000000) return m.index;
    }
    if (difficulty == 'casual') return ranked.first.index;
    var best = ranked.first.index, score = double.negativeInfinity;
    for (final m in ranked.take(8)) {
      board[m.index] = turn;
      final replies = rank(board, 3 - turn);
      final threats = candidates(board)
          .where((i) => attackScore(board, i, turn) >= 1000000)
          .length;
      final value =
          m.score -
          (replies.firstOrNull?.score ?? 0) * .85 +
          (threats >= 2 ? 2000000 : 0);
      board[m.index] = 0;
      if (value > score) {
        score = value;
        best = m.index;
      }
    }
    return best;
  }

  Map<String, dynamic> context({int? hint}) => {
    'size': 15,
    'rules': 'freestyle-five-or-more',
    'human': human == 1 ? 'black' : 'white',
    'black': moves.where((i) => board[i] == 1).map(coordinate).toList(),
    'white': moves.where((i) => board[i] == 2).map(coordinate).toList(),
    'lastMove': moves.isEmpty ? null : coordinate(moves.last),
    'next': winner != 0 || draw
        ? null
        : turn == human
        ? 'human'
        : 'yachiyo',
    'result': winner != 0
        ? winner == human
              ? 'human-won'
              : 'yachiyo-won'
        : draw
        ? 'draw'
        : 'playing',
    'winningLine': line.map(coordinate).toList(),
    'hint': hint == null ? null : coordinate(hint),
  };
}
