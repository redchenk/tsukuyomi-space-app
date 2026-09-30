import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/room_reference.dart';
import 'room_controller.dart';

class RoomMusic extends ChangeNotifier {
  RoomMusic(this.c);
  final RoomController c;
  final tracks = RoomReference.rows('music');
  AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool playing = false, loading = false, _disposed = false;
  int index = 0;
  double volume = .35;
  Duration position = Duration.zero, duration = Duration.zero;
  String error = '';
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    try {
      final saved = await c.storage.draft('room-music');
      if (saved.isNotEmpty) {
        final value = jsonDecode(saved) as Map;
        index = (value['index'] as int? ?? 0).clamp(0, tracks.length - 1);
        volume = (value['volume'] as num? ?? .35).toDouble().clamp(0, 1);
      }
    } catch (_) {
      error = '音乐偏好读取失败，使用默认设置';
    }
    _changed();
  }

  Future<void> _persist() => c.storage.saveDraft(
    'room-music',
    jsonEncode({'index': index, 'volume': volume}),
  );
  AudioPlayer get player {
    if (_player != null) return _player!;
    final p = _player = AudioPlayer();
    _subscriptions.addAll([
      p.onPlayerStateChanged.listen((v) {
        playing = v == PlayerState.playing;
        _changed();
      }),
      p.onPositionChanged.listen((v) {
        position = v;
        _changed();
      }),
      p.onDurationChanged.listen((v) {
        duration = v;
        _changed();
      }),
      p.onPlayerComplete.listen((_) => unawaited(select(index + 1))),
    ]);
    return p;
  }

  Future<void> select(int value) async {
    if (loading || _disposed) return;
    loading = true;
    error = '';
    index = value % tracks.length;
    position = duration = Duration.zero;
    _changed();
    try {
      final uri = endpointUri(c.settings.siteUrl).resolve(
        '/assets/music/${Uri.encodeComponent('${tracks[index]['file']}')}',
      );
      await player.stop();
      await player
          .play(UrlSource(uri.toString()), volume: volume)
          .timeout(const Duration(seconds: 30));
      await _persist();
    } catch (_) {
      error = '音乐加载失败，检查网络后点击播放重试';
    } finally {
      loading = false;
      _changed();
    }
  }

  Future<void> toggle() async {
    if (loading) return;
    try {
      if (playing) {
        await player.pause();
      } else if (duration > Duration.zero && error.isEmpty) {
        await player.resume();
      } else {
        await select(index);
      }
    } catch (_) {
      error = '播放失败，请重试';
      _changed();
    }
  }

  Future<void> seek(double value) async {
    try {
      await player.seek(Duration(milliseconds: value.round()));
    } catch (_) {
      error = '暂时无法调整进度';
      _changed();
    }
  }

  Future<void> setVolume(double value) async {
    volume = value;
    _changed();
    try {
      await _player?.setVolume(value);
      await _persist();
    } catch (_) {
      error = '音量保存失败';
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    unawaited(_player?.dispose());
    super.dispose();
  }
}

Future<void> showRoomMusic(
  BuildContext context,
  RoomMusic music,
) => showDialog<void>(
  context: context,
  builder: (context) => Dialog(
    child: SizedBox(
      width: 480,
      height: MediaQuery.sizeOf(context).height * .8,
      child: AnimatedBuilder(
        animation: music,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('房间音乐', style: TextStyle(fontSize: 22)),
                  ),
                  IconButton(
                    tooltip: '关闭音乐面板',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(CupertinoIcons.xmark),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '${music.tracks[music.index]['title']}',
                maxLines: 2,
                textAlign: TextAlign.center,
              ),
              Slider(
                value: music.position.inMilliseconds.toDouble().clamp(
                  0,
                  music.duration.inMilliseconds.toDouble(),
                ),
                max: music.duration.inMilliseconds.toDouble().clamp(
                  1,
                  double.infinity,
                ),
                onChanged: music.duration == Duration.zero ? null : music.seek,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '上一曲',
                    onPressed: music.loading
                        ? null
                        : () => music.select(music.index - 1),
                    icon: const Icon(CupertinoIcons.backward_end),
                  ),
                  IconButton(
                    tooltip: music.playing ? '暂停' : '播放',
                    onPressed: music.loading ? null : music.toggle,
                    icon: music.loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            music.playing
                                ? CupertinoIcons.pause_fill
                                : CupertinoIcons.play_fill,
                          ),
                  ),
                  IconButton(
                    tooltip: '下一曲',
                    onPressed: music.loading
                        ? null
                        : () => music.select(music.index + 1),
                    icon: const Icon(CupertinoIcons.forward_end),
                  ),
                ],
              ),
              Row(
                children: [
                  const Icon(CupertinoIcons.speaker_2, size: 18),
                  Expanded(
                    child: Slider(
                      value: music.volume,
                      onChanged: music.setVolume,
                    ),
                  ),
                  Text('${(music.volume * 100).round()}%'),
                ],
              ),
              if (music.error.isNotEmpty)
                Text(
                  music.error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const Divider(),
              Expanded(
                child: ListView(
                  children: [
                    for (var i = 0; i < music.tracks.length; i++)
                      ListTile(
                        selected: i == music.index,
                        leading: Text('${i + 1}'.padLeft(2, '0')),
                        title: Text('${music.tracks[i]['title']}'),
                        trailing: i == music.index && music.playing
                            ? const Icon(CupertinoIcons.music_note_2)
                            : null,
                        onTap: music.loading ? null : () => music.select(i),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);
