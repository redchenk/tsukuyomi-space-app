import '../../core/site_localization.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../../core/site_repository.dart';
import '../room/room_controller.dart';
import 'native_media_view.dart';
import 'native_site_shell.dart';
import 'site_widgets.dart';

class AccessPage extends StatefulWidget {
  const AccessPage({
    super.key,
    required this.controller,
    this.path = '/',
    required this.onGo,
    this.onTheme,
    this.playVideo = true,
  });
  final RoomController controller;
  final String path;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  final bool playVideo;
  @override
  State<AccessPage> createState() => _AccessPageState();
}

class _AccessPageState extends State<AccessPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _transition;
  Map<String, dynamic> _settings = {};
  bool _entering = false;
  Timer? _navigationTimer;
  int _generation = 0;
  String get site => widget.controller.settings.siteUrl;
  Map<String, dynamic> get copy => SiteArchive.access;
  @override
  void initState() {
    super.initState();
    _transition =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 300),
        )..addListener(() {
          if (mounted) setState(() {});
        });
    widget.controller.addListener(_settingsChanged);
    _loadSettings();
  }

  String _origin = '';
  void _settingsChanged() {
    if (_origin != site) _loadSettings();
  }

  Future<void> _loadSettings() async {
    _origin = site;
    if (mounted) setState(() => _settings = {});
    final ticket = ++_generation;
    try {
      final repository = SiteRepository(
        api: widget.controller.site as SiteDataService,
        storage: widget.controller.storage,
        site: () => site,
        accountId: () => widget.controller.account?.id,
      );
      final result = await repository.read('/api/settings');
      if (mounted && ticket == _generation) {
        setState(() => _settings = mapOf(result.data));
      }
    } catch (_) {
      /* Entering the app never depends on the settings endpoint. */
    }
  }

  Future<void> _enter() async {
    if (_entering) return;
    setState(() => _entering = true);
    final reduced = MediaQuery.disableAnimationsOf(context);
    _transition.duration = Duration(milliseconds: reduced ? 100 : 300);
    await _transition.forward();
    if (!mounted) return;
    _navigationTimer = Timer(Duration(milliseconds: reduced ? 24 : 70), () {
      if (mounted) widget.onGo('/hub');
    });
  }

  @override
  void dispose() {
    _generation++;
    widget.controller.removeListener(_settingsChanged);
    _navigationTimer?.cancel();
    _transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = Curves.easeOutCubic.transform(_transition.value);
    final labels = ['connecting', 'loading', 'sync', 'welcome'];
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/images/tsukuyomi-bg.webp', fit: BoxFit.cover),
          if (widget.playVideo && !MediaQuery.disableAnimationsOf(context))
            IgnorePointer(
              child: LayoutBuilder(
                builder: (context, box) => FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: box.maxWidth > box.maxHeight * 16 / 9
                        ? box.maxWidth
                        : box.maxHeight * 16 / 9,
                    height: box.maxWidth > box.maxHeight * 16 / 9
                        ? box.maxWidth * 9 / 16
                        : box.maxHeight,
                    child: NativeMediaView(
                      url: endpointUri(site)
                          .resolve(
                            '/assets/video/【4K⧸中日双语】超时空辉夜姬「ray 」官方MV.mp4',
                          )
                          .toString(),
                      poster: endpointUri(site)
                          .resolve('/assets/images/tsukuyomi-bg.webp')
                          .toString(),
                      autoPlay: true,
                      muted: true,
                      loop: true,
                      showControls: false,
                      fit: BoxFit.cover,
                      placeholder: Image.asset(
                        'assets/images/tsukuyomi-bg.webp',
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          const ColoredBox(color: Color(0x8c080519)),
          SafeArea(
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight:
                      MediaQuery.sizeOf(context).height -
                      MediaQuery.paddingOf(context).vertical,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SiteText(
                        textOf(copy, 'title'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 52,
                          color: Colors.white,
                          fontFamily: 'Songti SC',
                          letterSpacing: 4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const SiteText(
                        'TSUKUYOMI SPACE',
                        style: TextStyle(
                          fontSize: 12,
                          letterSpacing: 4,
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 24),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 570),
                        child: SiteText(
                          textOf(copy, 'heroCopy'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            height: 1.9,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                      FilledButton(
                        key: const Key('access-enter'),
                        onPressed: _entering ? null : _enter,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 28,
                            vertical: 10,
                          ),
                          child: SiteText(
                            textOf(copy, 'access'),
                            style: const TextStyle(fontSize: 17),
                          ),
                        ),
                      ),
                      const SizedBox(height: 54),
                      const SiteText(
                        '本站使用《超时空辉夜姬》相关素材版权归原著所有，本站为非盈利性质。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          height: 1.7,
                        ),
                      ),
                      if (textOf(_settings, 'beianText').isNotEmpty)
                        TextButton(
                          onPressed: () => widget.onGo(
                            textOf(_settings, 'beianUrl').isEmpty
                                ? 'https://beian.miit.gov.cn/'
                                : textOf(_settings, 'beianUrl'),
                          ),
                          child: Text(
                            textOf(_settings, 'beianText'),
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                      if (textOf(_settings, 'mpsBeianText').isNotEmpty)
                        TextButton(
                          onPressed: () => widget.onGo(
                            textOf(_settings, 'mpsBeianUrl').isEmpty
                                ? 'https://beian.mps.gov.cn/'
                                : textOf(_settings, 'mpsBeianUrl'),
                          ),
                          child: Text(
                            textOf(_settings, 'mpsBeianText'),
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_entering)
            ColoredBox(
              color: const Color(0xe6110d1d),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 290),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          textOf(
                            copy,
                            labels[(progress * 4).floor().clamp(0, 3)],
                          ),
                          style: const TextStyle(
                            color: Colors.white,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 20),
                        LinearProgressIndicator(value: progress),
                        const SizedBox(height: 12),
                        Text(
                          '${(progress * 100).round()}%',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
