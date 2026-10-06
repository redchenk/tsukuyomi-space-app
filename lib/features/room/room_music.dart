import '../../core/site_localization.dart';

import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/music_playback_order.dart';
import 'music_library.dart';
import 'music_library_panel.dart';
import '../../core/room_reference.dart';
import 'room_controller.dart';

class SiteMusicScope extends InheritedWidget {
  const SiteMusicScope({super.key, required this.music, required super.child});
  final RoomMusic music;
  static RoomMusic? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SiteMusicScope>()?.music;
  @override
  bool updateShouldNotify(SiteMusicScope oldWidget) => oldWidget.music != music;
}

class RoomMusic extends ChangeNotifier {
  RoomMusic(this.c) {
    library = MusicLibrary(c, useLocal: useLocal, playTracks: selectRemote);
  }
  late final MusicLibrary library;
  final order = MusicPlaybackOrder();
  MusicPlaybackMode mode = MusicPlaybackMode.loop;
  bool remote = false;
  int _intent = 0;
  Future<void> _audioQueue = Future.value();
  final RoomController c;
  final localTracks = RoomReference.rows('music');
  late List<Map<String, dynamic>> tracks = localTracks;
  AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool playing = false, loading = false, _disposed = false;
  int index = 0;
  double volume = .72;
  Duration position = Duration.zero, duration = Duration.zero;
  String error = '';
  bool _suspended = false, _resumeAfterSuspend = false;
  Future<void> suspend(bool value) async {
    if (_disposed || value == _suspended) return;
    _suspended = value;
    try {
      if (value) {
        _resumeAfterSuspend = playing || loading;
        await _player?.pause();
      } else if (_resumeAfterSuspend) {
        _resumeAfterSuspend = false;
        await _player?.resume();
      }
    } catch (_) {
      error = '音乐暂停或恢复失败，请点击播放重试';
    }
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    final intent = _intent;
    try {
      final saved = await c.storage.draft('room-music');
      if (_disposed || intent != _intent) return;
      if (saved.isNotEmpty) {
        final value = jsonDecode(saved) as Map;
        index = (value['index'] as int? ?? 0).clamp(0, tracks.length - 1);
        mode =
            MusicPlaybackMode.values
                .where((m) => m.name == value['mode'])
                .firstOrNull ??
            MusicPlaybackMode.loop;
        volume = (value['volume'] as num? ?? .72).toDouble().clamp(0, 1);
      }
    } catch (_) {
      error = '音乐偏好读取失败，使用默认设置';
    }
    _changed();
  }

  Future<void> _persist() => c.storage.saveDraft(
    'room-music',
    jsonEncode({
      'index': remote ? 0 : index,
      'volume': volume,
      'mode': mode.name,
    }),
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
      p.onPlayerComplete.listen((_) => unawaited(next(automatic: true))),
    ]);
    return p;
  }

  Future<void> setMode(MusicPlaybackMode value) async {
    mode = value;
    order.reset(index, tracks.length);
    _changed();
    try {
      await _persist();
    } catch (_) {
      error = '音乐偏好保存失败';
      _changed();
    }
  }

  Future<void> next({bool automatic = false}) async {
    final next = order.next(index, tracks.length, mode, automatic: automatic);
    if (next == null) {
      playing = false;
      _changed();
      return;
    }
    await select(next);
  }

  Future<void> previous() async {
    final previous = order.previous(index, tracks.length, mode);
    if (previous != null) await select(previous);
  }

  void useLocal() {
    if (!remote) return;
    _intent++;
    remote = false;
    tracks = localTracks;
    index = 0;
    loading = playing = false;
    position = duration = Duration.zero;
    order.reset(index, tracks.length);
    _audioQueue = _audioQueue
        .then((_) async {
          await _player?.stop();
        })
        .catchError((_) {});
    _changed();
  }

  Future<void> selectRemote(
    Map<String, dynamic> track,
    List<Map<String, dynamic>> queue,
  ) async {
    if (library.profile == null) throw const ApiFailure('请先使用网易云 App 扫码登录');
    final nextTracks = queue.take(100).toList();
    final at = nextTracks.indexWhere((t) => t['id'] == track['id']);
    if (at < 0) throw const ApiFailure('曲目已过期，请重新选择');
    tracks = nextTracks;
    remote = true;
    order.reset(at, tracks.length);
    await select(at);
  }

  Future<void> select(int value, {bool play = true}) async {
    if (_disposed || tracks.isEmpty) return;
    final intent = ++_intent;
    loading = true;
    error = '';
    playing = false;
    index = value % tracks.length;
    position = duration = Duration.zero;
    final track = tracks[index], wasRemote = remote;
    _changed();
    try {
      final String url;
      if (wasRemote) {
        final data = await library.request(
          '/tracks/${Uri.encodeComponent('${track['id']}')}/playback',
        );
        final uri = Uri.tryParse('${data['url']}');
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const ApiFailure('曲目播放地址无效');
        }
        url = uri.toString();
      } else {
        url = endpointUri(c.settings.siteUrl)
            .resolve('/assets/music/${Uri.encodeComponent('${track['file']}')}')
            .toString();
      }
      if (_disposed || intent != _intent) return;
      final operation = _audioQueue.then((_) async {
        if (_disposed || intent != _intent) return;
        await player.stop();
        if (_disposed || intent != _intent) return;
        if (play && !_suspended) {
          await player
              .play(UrlSource(url), volume: volume)
              .timeout(const Duration(seconds: 30));
        } else {
          await player.setSourceUrl(url).timeout(const Duration(seconds: 30));
          await player.setVolume(volume);
        }
        if (_disposed || intent != _intent || _suspended) {
          await _player?.pause();
        }
        if (_suspended && intent == _intent) _resumeAfterSuspend = play;
      });
      _audioQueue = operation.catchError((_) {});
      await operation;
      if (intent == _intent && !_disposed) await _persist();
    } catch (e) {
      if (intent == _intent && !_disposed) {
        error = e is ApiFailure ? e.message : '音乐加载失败，检查网络后点击播放重试';
      }
    } finally {
      if (intent == _intent && !_disposed) {
        loading = false;
        _changed();
      }
    }
  }

  Future<void> toggle() async {
    try {
      if (loading) {
        _intent++;
        loading = playing = false;
        _resumeAfterSuspend = false;
        _audioQueue = _audioQueue
            .then((_) async {
              await _player?.pause();
            })
            .catchError((_) {});
      } else if (playing) {
        await player.pause();
      } else if (duration > Duration.zero && error.isEmpty) {
        await player.resume();
      } else {
        await select(index);
      }
    } catch (_) {
      error = '播放失败，请重试';
    }
    _changed();
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
    _intent++;
    library.dispose();
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
                    child: SiteText('房间音乐', style: TextStyle(fontSize: 22)),
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
                '${music.tracks[music.index]['title'] ?? music.tracks[music.index]['name']}',
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
                    onPressed: music.previous,
                    icon: const Icon(CupertinoIcons.backward_end),
                  ),
                  IconButton(
                    tooltip: music.playing ? '暂停' : '播放',
                    onPressed: music.toggle,
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
                    onPressed: music.next,
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
              DropdownButton<MusicPlaybackMode>(
                value: music.mode,
                items: [
                  for (final mode in MusicPlaybackMode.values)
                    DropdownMenuItem(
                      value: mode,
                      child: SiteText(
                        const {
                          MusicPlaybackMode.sequence: '顺序播放',
                          MusicPlaybackMode.loop: '列表循环',
                          MusicPlaybackMode.shuffle: '随机播放',
                          MusicPlaybackMode.single: '单曲循环',
                        }[mode]!,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) music.setMode(value);
                },
              ),
              Expanded(child: MusicLibraryPanel(music: music)),
            ],
          ),
        ),
      ),
    ),
  ),
);
