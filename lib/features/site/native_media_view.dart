import '../../core/site_localization.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class NativeMediaView extends StatefulWidget {
  const NativeMediaView({
    super.key,
    required this.url,
    this.poster,
    this.headers,
    this.autoPlay = false,
    this.muted = false,
    this.loop = false,
    this.showControls = true,
    this.fit = BoxFit.contain,
    this.placeholder,
  });
  final String url;
  final String? poster;
  final Map<String, String>? headers;
  final bool autoPlay;
  final bool muted, loop, showControls;
  final BoxFit fit;
  final Widget? placeholder;
  @override
  State<NativeMediaView> createState() => _NativeMediaViewState();
}

class _NativeMediaViewState extends State<NativeMediaView>
    with WidgetsBindingObserver {
  Player? _player;
  VideoController? _video;
  StreamSubscription<String>? _errors;
  String _error = '';
  bool _opened = false;
  int _revision = 0;
  bool _routeCurrent = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.autoPlay) _open();
  }

  @override
  void didUpdateWidget(covariant NativeMediaView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        !mapEquals(oldWidget.headers, widget.headers)) {
      _revision++;
      _disposePlayer();
      _error = '';
      _opened = false;
      if (widget.autoPlay) _open();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    if (current == _routeCurrent) return;
    _routeCurrent = current;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_routeCurrent) {
        unawaited(_player?.pause());
      } else if (widget.autoPlay) {
        unawaited(_player?.play());
      }
    });
  }

  Future<void> _open() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty) {
      setState(() => _error = '媒体地址无效');
      return;
    }
    final revision = ++_revision;
    try {
      MediaKit.ensureInitialized();
      final player = Player();
      _player = player;
      _video = VideoController(player);
      _opened = true;
      _errors = player.stream.error.listen((message) {
        if (mounted && revision == _revision) setState(() => _error = message);
      });
      setState(() => _error = '');
      if (widget.muted) await player.setVolume(0);
      if (widget.loop) await player.setPlaylistMode(PlaylistMode.single);
      await player.open(
        Media(widget.url, httpHeaders: widget.headers),
        play: true,
      );
      if (mounted && revision == _revision && !_routeCurrent) {
        await player.pause();
      }
    } catch (e) {
      if (mounted && revision == _revision) {
        setState(() => _error = '媒体加载失败：$e');
      }
    }
  }

  void _disposePlayer() {
    unawaited(_errors?.cancel());
    _errors = null;
    final player = _player;
    _player = null;
    _video = null;
    if (player != null) unawaited(player.dispose());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_player?.pause());
    if (state == AppLifecycleState.resumed &&
        widget.autoPlay &&
        !widget.showControls &&
        mounted &&
        ModalRoute.of(context)?.isCurrent == true) {
      unawaited(_player?.play());
    }
  }

  @override
  void dispose() {
    _revision++;
    WidgetsBinding.instance.removeObserver(this);
    _disposePlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 16 / 9,
    child: ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.placeholder != null && (!_opened || _error.isNotEmpty))
            widget.placeholder!,
          if (widget.poster != null && (!_opened || _error.isNotEmpty))
            Image.network(
              widget.poster!,
              headers: widget.headers,
              fit: widget.fit,
              errorBuilder: (_, _, _) => const SizedBox(),
            ),
          if (_opened && _video != null && _error.isEmpty)
            Video(
              controller: _video!,
              fit: widget.fit,
              controls: widget.showControls
                  ? AdaptiveVideoControls
                  : NoVideoControls,
            ),
          if (!_opened && widget.showControls)
            Center(
              child: FilledButton.icon(
                onPressed: _open,
                icon: const Icon(Icons.play_arrow),
                label: const SiteText('播放'),
              ),
            ),
          if (_error.isNotEmpty && widget.showControls)
            Align(
              alignment: Alignment.bottomCenter,
              child: Material(
                color: Colors.black87,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        siteTranslate(context, _error),
                        style: const TextStyle(color: Colors.white),
                      ),
                      TextButton(
                        onPressed: () {
                          _disposePlayer();
                          _open();
                        },
                        child: const SiteText('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
