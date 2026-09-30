import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import 'kaguya_runtime.dart';

abstract interface class KaguyaSoundVoice {
  bool get playing;
  bool get paused;
  Future<void> playAsset(String path, double volume);
  Future<void> stop();
  Future<void> pause();
  Future<void> resume();
  Future<void> setVolume(double value);
  Future<void> dispose();
}

class _PlayerVoice implements KaguyaSoundVoice {
  final player = AudioPlayer();
  @override
  bool get playing => player.state == PlayerState.playing;
  @override
  bool get paused => player.state == PlayerState.paused;
  @override
  Future<void> playAsset(String path, double volume) =>
      player.play(AssetSource(path), volume: volume);
  @override
  Future<void> stop() => player.stop();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> resume() => player.resume();
  @override
  Future<void> setVolume(double value) => player.setVolume(value);
  @override
  Future<void> dispose() => player.dispose();
}

/// One voice per Scratch sound bank entry: starting the same sound restarts it.
class KaguyaAudio {
  KaguyaAudio(this.runtime, {KaguyaSoundVoice Function()? voiceFactory})
    : _voiceFactory = voiceFactory ?? _PlayerVoice.new {
    runtime.onSound = _play;
    runtime.onStopSounds = stop;
  }
  final KaguyaRuntime runtime;
  final KaguyaSoundVoice Function() _voiceFactory;
  final _voices = <String, KaguyaSoundVoice>{};
  final _owners = <String, KaguyaSprite>{};
  final _revisions = <String, int>{};
  final _queues = <String, Future<void>>{};
  double volume = .7;
  bool muted = false, _disposed = false, _paused = false;
  String error = '';

  void _play(KaguyaSprite sprite, Map<String, dynamic> sound, bool untilDone) {
    if (_disposed) return;
    final key = '${sprite.name}:${sound['assetId']}';
    final revision = (_revisions[key] ?? 0) + 1;
    _revisions[key] = revision;
    final player = _voices.putIfAbsent(key, _voiceFactory);
    _owners[key] = sprite;
    _enqueue(key, () async {
      if (_disposed || revision != _revisions[key]) return;
      await player.stop();
      if (_disposed || revision != _revisions[key]) return;
      await player.playAsset(
        'game/${sound['file'] ?? sound['md5ext']}',
        muted ? 0 : volume * sprite.volume / 100,
      );
      if (_disposed || revision != _revisions[key]) {
        // A restart can occur while the platform is preparing the asset.
        // Serialized operations stop that old playback before a newer play.
        await player.stop();
        return;
      }
      if (_paused) await player.pause();
    });
  }

  void _enqueue(String key, Future<void> Function() operation) {
    _queues[key] = (_queues[key] ?? Future.value())
        .then((_) => operation())
        .catchError((_) {
          if (!_disposed) error = '声音暂不可用，可继续游戏';
        });
  }

  void configure({double? gain, bool? mute}) {
    if (gain != null) volume = gain.clamp(0, 1);
    if (mute != null) muted = mute;
    syncVolumes();
  }

  void syncVolumes() {
    for (final e in _voices.entries) {
      _enqueue(
        e.key,
        () => e.value.setVolume(
          muted ? 0 : volume * (_owners[e.key]?.volume ?? 100) / 100,
        ),
      );
    }
  }

  void pause(bool value) {
    _paused = value;
    for (final entry in _voices.entries) {
      _enqueue(entry.key, () async {
        if (_disposed) return;
        if (_paused && entry.value.playing) {
          await entry.value.pause();
        } else if (!_paused && entry.value.paused) {
          await entry.value.resume();
        }
      });
    }
  }

  void stop() {
    for (final entry in _voices.entries) {
      _revisions[entry.key] = (_revisions[entry.key] ?? 0) + 1;
      _enqueue(entry.key, entry.value.stop);
    }
  }

  void dispose() {
    _disposed = true;
    runtime.onSound = null;
    runtime.onStopSounds = null;
    for (final entry in _voices.entries) {
      _enqueue(entry.key, entry.value.dispose);
    }
    _voices.clear();
    _owners.clear();
  }
}
