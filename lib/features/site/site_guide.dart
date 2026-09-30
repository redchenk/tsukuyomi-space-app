import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../core/room_archive.dart';
import '../../core/site_localization.dart';
import '../room/room_controller.dart';
import 'site_guide_service.dart';

export 'site_guide_service.dart';

class SiteGuideController extends ChangeNotifier {
  SiteGuideController(
    this.room, {
    SiteGuideService? service,
    this.path = '/hub',
  }) : service = service ?? SiteGuideService() {
    _owner = owner;
    room.addListener(_settingsChanged);
  }
  final RoomController room;
  final SiteGuideService service;
  String path, error = '';
  bool asking = false, _disposed = false;
  int _generation = 0, _owner = 0;
  final messages = <Map<String, dynamic>>[];
  SiteGuideModelStatus get model => SiteGuideModelStatus.read(room.settings);
  int get owner => Object.hash(
    room.settings.siteUrl,
    room.account?.id,
    room.sessionExpired,
    room.settings.llmUrl,
    room.settings.model,
    room.settings.apiKey,
    room.settings.demo,
    room.settings.flag('llmProxy'),
  );
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _settingsChanged() {
    if (_owner != owner) {
      _owner = owner;
      cancel();
      messages.clear();
      error = '';
    }
    _changed();
  }

  Future<void> ask(String value, {String language = 'zh'}) async {
    final question = value.trim().substring(
      0,
      value.trim().length.clamp(0, 800),
    );
    if (question.isEmpty || asking || !model.configured) return;
    final ticket = ++_generation,
        currentOwner = owner,
        history = siteGuideHistory(messages),
        settings = room.settings;
    messages.add({'role': 'user', 'content': question});
    asking = true;
    error = '';
    _changed();
    try {
      final reply = await service.ask(
        settings: settings,
        question: question,
        history: history,
        language: language,
        routeName: SiteGuideReference.routeName(path),
        siteCookie: room.sessionExpired ? null : room.site.cookie,
      );
      if (_disposed || ticket != _generation || currentOwner != owner) return;
      messages.add({'role': 'assistant', 'content': reply});
    } catch (e) {
      if (!_disposed && ticket == _generation && currentOwner == owner) {
        error = '$e';
      }
    } finally {
      if (!_disposed && ticket == _generation) {
        asking = false;
        _changed();
      }
    }
  }

  void cancel() {
    _generation++;
    asking = false;
    service.cancel();
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    room.removeListener(_settingsChanged);
    service.dispose();
    super.dispose();
  }
}

Future<void> showSiteGuide(
  BuildContext context,
  RoomController controller,
  String path,
  ValueChanged<String> onGo, {
  SiteGuideController? guide,
}) async {
  final owned = guide == null;
  final active = guide ?? SiteGuideController(controller, path: path);
  active.path = path;
  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _SiteGuideDialog(
        guide: active,
        onGo: (next) {
          Navigator.pop(dialogContext);
          onGo(next);
        },
      ),
    );
  } finally {
    if (owned) {
      active.dispose();
    } else {
      active.cancel();
    }
  }
}

/// Exact 8×9 source sprite sequences, rendered natively from bundled pixels.
class SitePet extends StatefulWidget {
  const SitePet({
    super.key,
    required this.onTap,
    this.reduced = false,
    this.actionsEnabled = true,
    this.width = 110,
    this.label = '打开八千代 AI 使用向导',
    this.spriteAsset = 'assets/images/site-pet-yachiyo-sprites.webp',
    this.idleAsset = 'assets/images/site-pet-yachiyo-idle.webp',
  });
  final VoidCallback onTap;
  final bool reduced, actionsEnabled;
  final double width;
  final String label, spriteAsset, idleAsset;
  @override
  State<SitePet> createState() => _SitePetState();
}

class _SitePetState extends State<SitePet> with WidgetsBindingObserver {
  ui.Image? _image;
  Timer? _frameTimer, _actionTimer;
  final _random = math.Random();
  String _sequence = 'idle';
  int _index = 0, _loops = 0, _loadTicket = 0;
  bool _reduced = true, _active = true;
  Map<String, dynamic> get sequence =>
      jsonMap(jsonMap(SiteGuideReference.data['sequences'])[_sequence]);
  List<dynamic> get frames => sequence['frames'] as List;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    final ticket = ++_loadTicket;
    try {
      final bytes = await rootBundle.load(widget.spriteAsset);
      final codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted || ticket != _loadTicket) {
        frame.image.dispose();
        return;
      }
      _image?.dispose();
      setState(() => _image = frame.image);
    } catch (_) {
      /* A missing sprite falls back to the bundled idle image. */
    }
  }

  @override
  void didUpdateWidget(covariant SitePet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spriteAsset != widget.spriteAsset) _load();
    _updateReduced();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateReduced();
  }

  void _updateReduced() {
    final next = widget.reduced || MediaQuery.disableAnimationsOf(context);
    if (next == _reduced) return;
    _reduced = next;
    _frameTimer?.cancel();
    _actionTimer?.cancel();
    _sequence = 'idle';
    _index = 0;
    _loops = 0;
    if (!_reduced && _active) {
      _nextFrame();
      _scheduleAction();
    }
  }

  void _nextFrame() {
    if (_reduced || !_active || !mounted) return;
    final durations = sequence['durations'] as List;
    _frameTimer = Timer(
      Duration(milliseconds: (durations[_index] as num).toInt()),
      () {
        if (!mounted || !_active) return;
        setState(() {
          _index++;
          if (_index >= frames.length) {
            _index = 0;
            if (_sequence != 'idle' && ++_loops >= (sequence['loops'] as num)) {
              _sequence = 'idle';
              _loops = 0;
              _scheduleAction();
            }
          }
        });
        _nextFrame();
      },
    );
  }

  void _scheduleAction() {
    _actionTimer?.cancel();
    if (_reduced || !_active) return;
    _actionTimer = Timer(
      Duration(milliseconds: 12000 + _random.nextInt(10000)),
      () {
        if (!mounted) return;
        if (!widget.actionsEnabled) {
          _scheduleAction();
          return;
        }
        final actions = jsonMap(SiteGuideReference.data['sequences']).keys
            .where((s) => s != 'idle')
            .toList();
        _play(actions[_random.nextInt(actions.length)]);
      },
    );
  }

  void _play(String name) {
    if (_reduced || !_active) return;
    _frameTimer?.cancel();
    _actionTimer?.cancel();
    setState(() {
      _sequence = name;
      _index = 0;
      _loops = 0;
    });
    _nextFrame();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _frameTimer?.cancel();
    _actionTimer?.cancel();
    if (_active && !_reduced) {
      _nextFrame();
      _scheduleAction();
    }
  }

  @override
  void dispose() {
    _loadTicket++;
    WidgetsBinding.instance.removeObserver(this);
    _frameTimer?.cancel();
    _actionTimer?.cancel();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    child: Tooltip(
      message: widget.label,
      child: GestureDetector(
        onTap: () {
          _play('waving');
          widget.onTap();
        },
        child: SizedBox(
          width: widget.width,
          height: widget.width * 208 / 192,
          child: RepaintBoundary(
            child: _reduced || _image == null
                ? Image.asset(
                    widget.idleAsset,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.auto_awesome, size: 56),
                  )
                : CustomPaint(
                    painter: _PetPainter(
                      _image!,
                      (frames[_index] as num).toInt(),
                    ),
                  ),
          ),
        ),
      ),
    ),
  );
}

class _PetPainter extends CustomPainter {
  _PetPainter(this.image, this.frame);
  final ui.Image image;
  final int frame;
  @override
  void paint(Canvas canvas, Size size) {
    final w = image.width / 8, h = image.height / 9;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH((frame % 8) * w, (frame ~/ 8) * h, w, h),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _PetPainter oldDelegate) =>
      oldDelegate.frame != frame || oldDelegate.image != image;
}

/// The host positions this common button in its global overlay. Guide history
/// remains in memory while it is mounted and is isolated by account/provider.
class SiteGuideButton extends StatefulWidget {
  const SiteGuideButton({
    super.key,
    required this.controller,
    required this.path,
    required this.onGo,
    this.reduced = false,
    this.width = 110,
    this.showPet = true,
    this.dialogContext,
  });
  final RoomController controller;
  final String path;
  final ValueChanged<String> onGo;
  final bool reduced, showPet;
  final double width;
  final BuildContext Function()? dialogContext;
  @override
  State<SiteGuideButton> createState() => _SiteGuideButtonState();
}

class _SiteGuideButtonState extends State<SiteGuideButton> {
  late SiteGuideController guide;
  bool _open = false;
  @override
  void initState() {
    super.initState();
    guide = SiteGuideController(widget.controller, path: widget.path);
  }

  @override
  void didUpdateWidget(covariant SiteGuideButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      guide.dispose();
      guide = SiteGuideController(widget.controller, path: widget.path);
    }
    guide.path = widget.path;
  }

  Future<void> _show() async {
    if (_open) return;
    setState(() => _open = true);
    await showSiteGuide(
      widget.dialogContext?.call() ?? context,
      widget.controller,
      widget.path,
      widget.onGo,
      guide: guide,
    );
    if (mounted) setState(() => _open = false);
  }

  @override
  void dispose() {
    guide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lang = SiteLocaleScope.maybeOf(context)?.language ?? 'zh',
        copy = SiteGuideReference.copy(lang);
    return widget.showPet
        ? SitePet(
            width: widget.width,
            reduced: widget.reduced,
            actionsEnabled: !_open,
            label: '${copy['petLabel']}',
            onTap: _show,
          )
        : IconButton(
            tooltip: '${copy['petLabel']}',
            onPressed: _show,
            icon: const Icon(Icons.auto_awesome_outlined),
          );
  }
}

class _SiteGuideDialog extends StatefulWidget {
  const _SiteGuideDialog({required this.guide, required this.onGo});
  final SiteGuideController guide;
  final ValueChanged<String> onGo;
  @override
  State<_SiteGuideDialog> createState() => _SiteGuideDialogState();
}

class _SiteGuideDialogState extends State<_SiteGuideDialog> {
  final _question = TextEditingController(),
      _scroll = ScrollController(),
      _focus = FocusNode();
  @override
  void dispose() {
    _question.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _ask(String language, [String? preset]) async {
    final text = preset ?? _question.text;
    if (text.trim().isEmpty || widget.guide.asking) return;
    _question.clear();
    await widget.guide.ask(text, language: language);
    if (!mounted) return;
    _focus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _link(String? href) {
    if (href == null) return;
    final uri = Uri.tryParse(href);
    if (uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        !href.startsWith('/') ||
        href.startsWith('//') ||
        href.contains('\\')) {
      return;
    }
    widget.onGo(href);
  }

  @override
  Widget build(BuildContext context) {
    final lang = SiteLocaleScope.maybeOf(context)?.language ?? 'zh',
        copy = SiteGuideReference.copy(lang);
    String t(String key) => '${copy[key] ?? key}';
    final guides = SiteGuideReference.guides(widget.guide.path);
    final route = SiteGuideReference.routeName(widget.guide.path),
        current = guides
            .where((g) => (g['routes'] as List).contains(route))
            .firstOrNull;
    final currentLabel = current == null
        ? (route == 'hub'
              ? (lang == 'ja'
                    ? 'ロビー'
                    : lang == 'en'
                    ? 'Hub'
                    : '大厅')
              : route)
        : '${(current[lang] ?? current['zh'] as List)[0]}';
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: MediaQuery.sizeOf(context).height * .9,
        ),
        child: AnimatedBuilder(
          animation: widget.guide,
          builder: (context, _) {
            final g = widget.guide, status = g.model;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 12, 16),
                  child: Row(
                    children: [
                      const Icon(Icons.auto_awesome_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t('eyebrow'),
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                            Text(
                              t('title'),
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text(t('subtitle')),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: t('close'),
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  status.configured
                                      ? t('connected')
                                      : t('noModel'),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  status.configured
                                      ? '${status.local ? t('local') : t('cloud')} · ${status.model}'
                                      : t('noModelBody'),
                                ),
                                if (!status.configured)
                                  TextButton(
                                    onPressed: () =>
                                        widget.onGo('/room/settings'),
                                    child: Text(t('setup')),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          t('fixed'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text('${t('currentPage')} · $currentLabel'),
                        const SizedBox(height: 12),
                        for (final item in guides)
                          Card(
                            child: ListTile(
                              title: Text(
                                '${(item[lang] ?? item['zh'] as List)[0]}',
                              ),
                              subtitle: Text(
                                '${(item[lang] ?? item['zh'] as List)[1]}',
                              ),
                              trailing: const Icon(Icons.arrow_forward),
                              onTap: () => widget.onGo('${item['path']}'),
                            ),
                          ),
                        if (status.configured) ...[
                          const SizedBox(height: 24),
                          Text(
                            t('ask'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final text in copy['suggestions'] as List)
                                OutlinedButton(
                                  onPressed: g.asking
                                      ? null
                                      : () => _ask(lang, '$text'),
                                  child: Text('$text'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          if (g.messages.isEmpty && !g.asking) Text(t('empty')),
                          for (final message in g.messages)
                            Card(
                              color: message['role'] == 'assistant'
                                  ? Theme.of(context)
                                        .colorScheme
                                        .surfaceContainer
                                  : Theme.of(context)
                                        .colorScheme
                                        .primaryContainer,
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      message['role'] == 'assistant'
                                          ? t('title')
                                          : lang == 'en'
                                          ? 'You'
                                          : lang == 'ja'
                                          ? 'あなた'
                                          : '你',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    MarkdownBody(
                                      selectable: true,
                                      data: '${message['content']}',
                                      onTapLink: (_, href, _) => _link(href),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (g.asking)
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(child: Text(t('sending'))),
                                ],
                              ),
                            ),
                          if (g.error.isNotEmpty)
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                g.error,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          const SizedBox(height: 14),
                          TextField(
                            key: const Key('site-guide-question'),
                            controller: _question,
                            focusNode: _focus,
                            autofocus: true,
                            enabled: !g.asking,
                            minLines: 2,
                            maxLines: 5,
                            maxLength: 800,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _ask(lang),
                            decoration: InputDecoration(
                              labelText: t('ask'),
                              hintText: t('placeholder'),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                          FilledButton.icon(
                            key: const Key('site-guide-send'),
                            onPressed: g.asking || _question.text.trim().isEmpty
                                ? null
                                : () => _ask(lang),
                            icon: const Icon(Icons.send_outlined),
                            label: Text(g.asking ? t('sending') : t('send')),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
