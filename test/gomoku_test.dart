import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/features/game/gomoku.dart';

void main() {
  test('edge boundaries and diagonals do not wrap', () {
    final board = List<int>.filled(225, 0);
    for (final i in [13, 14, 15, 16, 17]) {
      board[i] = 1;
    }
    expect(Gomoku.winningLine(board, 15), isEmpty);
    for (final i in [0, 16, 32, 48, 64]) {
      board[i] = 2;
    }
    expect(Gomoku.winningLine(board, 32).length, 5);
  });
  test('AI wins before defending and blocks immediate wins', () {
    final game = Gomoku();
    for (final i in [0, 15, 1, 16, 2, 17, 3, 18]) {
      game.play(i);
    }
    expect(game.choose(), 4);
    final block = Gomoku();
    for (final i in [0, 30, 1, 45, 2, 60, 3]) {
      block.play(i);
    }
    expect(block.choose(), 4);
  });
  test('undo removes human move and response, including a terminal move', () {
    final game = Gomoku(human: 2);
    for (final i in [112, 113, 114]) {
      game.play(i);
    }
    game.undo();
    expect(game.moves, [112]);
    expect(game.turn, 2);
    expect(Gomoku.restore(game.save())!.moves, [112]);
    expect(
      Gomoku.restore(
        '{"version":1,"human":1,"difficulty":"casual","moves":[1,1]}',
      ),
      isNull,
    );
  });
  test('challenge search leaves the board intact', () {
    final game = Gomoku(difficulty: 'challenge');
    for (final i in [112, 113, 97, 127]) {
      game.play(i);
    }
    final saved = game.save(), board = List.of(game.board);
    final move = game.choose();
    expect(move, isNotNull);
    expect(game.board[move!], 0);
    expect(game.board, board);
    expect(game.save(), saved);
  });
}
