import 'dart:math';

enum MusicPlaybackMode { sequence, loop, shuffle, single }

/// Website shuffle bag: no repeats per cycle, Previous follows actual history.
class MusicPlaybackOrder {
  MusicPlaybackOrder({Random? random}) : random = random ?? Random();
  final Random random;
  final _bag = <int>[], _history = <int>[];
  int _position = -1, _size = 0;
  void reset(int current, int count) {
    _bag.clear();
    _history.clear();
    if (count > 0) _history.add(current);
    _position = _history.length - 1;
    _size = count;
  }

  void _prepare(int current, int count) {
    if (_size != count || _position < 0 || _history[_position] != current) {
      reset(current, count);
    }
  }

  int _remember(int index) {
    _history.removeRange(_position + 1, _history.length);
    _history.add(index);
    if (_history.length > 100) _history.removeAt(0);
    _position = _history.length - 1;
    return index;
  }

  int? next(
    int current,
    int count,
    MusicPlaybackMode mode, {
    bool automatic = false,
  }) {
    if (count == 0) return null;
    _prepare(current, count);
    if (automatic && mode == MusicPlaybackMode.single) return current;
    if (mode != MusicPlaybackMode.shuffle) {
      if (automatic &&
          mode == MusicPlaybackMode.sequence &&
          current == count - 1) {
        return null;
      }
      return _remember((current + 1) % count);
    }
    if (_position < _history.length - 1) return _history[++_position];
    if (_bag.isEmpty) {
      _bag.addAll(
        [
          for (var i = 0; i < count; i++)
            if (i != current) i,
        ]..shuffle(random),
      );
    }
    return _remember(_bag.isEmpty ? current : _bag.removeLast());
  }

  int? previous(int current, int count, MusicPlaybackMode mode) {
    if (count == 0) return null;
    _prepare(current, count);
    if (mode == MusicPlaybackMode.shuffle) {
      return _position > 0 ? _history[--_position] : current;
    }
    return _remember((current - 1 + count) % count);
  }
}
