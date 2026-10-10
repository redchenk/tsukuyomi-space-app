import 'site_seasonal_surface.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

import '../../core/season_theme.dart';
import '../../core/site_localization.dart';
import '../room/room_style.dart';
import 'site_widgets.dart';

const siteNavigationGroups = <String, List<String>>{
  '发现': ['/wiki', '/plaza', '/gallery', '/game'],
  '创作': ['/stage', '/pixel'],
  '空间': ['/agent-os', '/reality', '/friend-links', '/growth', '/rss.xml'],
};
const _descriptions = {
  '/wiki': '角色、音乐与月读世界',
  '/plaza': '留言、回复与社区日常',
  '/gallery': '收集与分享喜欢的创作',
  '/game': '跟着节拍，轻松玩一局',
  '/stage': '文章、故事与创作手记',
  '/pixel': '把灵感画进小小像素',
  '/agent-os': '打开你的智能工作空间',
  '/reality': '关于本站与开源项目',
  '/friend-links': '去看看同频的小站',
  '/growth': '签到、任务与成长记录',
  '/rss.xml': '用 RSS 阅读器接收公开动态',
};

String navigationArtwork(SiteSeason season, String path) {
  final art = SeasonalArt(season);
  if (path == '/wiki') return 'assets/images/navigation/wiki-study.webp';
  if (path == '/game') return 'assets/images/navigation/kaguya-run.webp';
  if (season != SiteSeason.spring) {
    return switch (path) {
      '/stage' => art.article,
      '/plaza' => art.gallery,
      '/gallery' => art.hero,
      _ => art.pixel,
    };
  }
  return 'assets/images/navigation/${switch (path) {
    '/stage' => 'star-study',
    '/plaza' => 'plaza-gathering',
    '/gallery' => 'gallery-yachiyo',
    _ => 'pixel-workshop',
  }}.webp';
}

/// One overlay shared by three disclosures. Only the visible preview is decoded.
class SiteDesktopNavigation extends StatefulWidget {
  const SiteDesktopNavigation({
    super.key,
    required this.onGo,
    required this.path,
  });
  final ValueChanged<String> onGo;
  final String path;
  @override
  State<SiteDesktopNavigation> createState() => _NavigationState();
}

class _NavigationState extends State<SiteDesktopNavigation> {
  final _overlay = OverlayPortalController();
  final _anchors = List.generate(3, (_) => GlobalKey());
  final _triggers = List.generate(
    3,
    (i) => FocusNode(debugLabel: 'Navigation $i'),
  );
  final _links = List.generate(
    5,
    (i) => FocusNode(debugLabel: 'Navigation link $i'),
  );
  final _region = Object();
  Timer? _closeTimer;
  int? _active;
  String _preview = '/wiki';
  bool _pinned = false;
  String? _themeSignature;
  Offset _position = Offset.zero;
  double _width = 650;
  List<String> get _routes =>
      siteNavigationGroups.values.elementAt(_active ?? 0);

  void _close({bool restore = false}) {
    _closeTimer?.cancel();
    final active = _active;
    if (active == null) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _close(restore: restore);
      });
      return;
    }
    _overlay.hide();
    if (_active != null && mounted) {
      setState(() {
        _active = null;
        _pinned = false;
      });
    }
    if (restore) _triggers[active].requestFocus();
  }

  void _scheduleClose() {
    if (!_pinned) {
      _closeTimer = Timer(const Duration(milliseconds: 180), () => _close());
    }
  }

  void _open(int group, {bool pin = false, int? focus}) {
    _closeTimer?.cancel();
    if (_active == group && !pin && focus == null) return;
    final size = MediaQuery.sizeOf(context);
    final box =
        _anchors[group].currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final point = box.localToGlobal(Offset.zero);
    _width = math.min([650.0, 486.0, 320.0][group], size.width - 48);
    _position = Offset(
      point.dx.clamp(24, math.max(24, size.width - _width - 24)),
      point.dy + box.size.height + 16,
    );
    setState(() {
      _active = group;
      _pinned = pin;
      _preview = _routes.first;
    });
    _overlay.show();
    if (pin && focus == null) _triggers[group].requestFocus();
    if (focus != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active == group) {
          _links[focus < 0 ? _routes.length - 1 : focus].requestFocus();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant SiteDesktopNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _close();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final signature =
        '${RoomStyle(context).palette.season}:${Theme.of(context).brightness}:${SiteLocaleScope.maybeOf(context)?.language}:${MediaQuery.sizeOf(context)}';
    if (_themeSignature != null && _themeSignature != signature) _close();
    _themeSignature = signature;
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    for (final node in [..._triggers, ..._links]) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _triggerKey(int i, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close(restore: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      _open(i, pin: true, focus: key == LogicalKeyboardKey.arrowUp ? -1 : 0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final next = (i + (key == LogicalKeyboardKey.arrowRight ? 1 : 2)) % 3;
      _triggers[next].requestFocus();
      if (_active != null) _open(next, pin: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab &&
        !HardwareKeyboard.instance.isShiftPressed &&
        _active == i) {
      _open(i, pin: true, focus: 0);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _link(String route, int at, {Widget? child}) => Focus(
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _close(restore: true);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.tab) {
        final backwards = HardwareKeyboard.instance.isShiftPressed;
        if (at == 0 && backwards) {
          _close(restore: true);
          return KeyEventResult.handled;
        }
        if (at == _routes.length - 1 && !backwards) {
          final group = _active!;
          _close();
          _triggers[group].nextFocus();
          return KeyEventResult.handled;
        }
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _links[(at +
                    (event.logicalKey == LogicalKeyboardKey.arrowDown
                        ? 1
                        : _routes.length - 1)) %
                _routes.length]
            .requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: MouseRegion(
      onEnter: (_) => setState(() => _preview = route),
      child: TextButton(
        key: Key('site-navigation-link-$route'),
        focusNode: _links[at],
        onFocusChange: (focus) {
          if (focus) setState(() => _preview = route);
        },
        onPressed: () {
          _close();
          widget.onGo(route);
        },
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          foregroundColor: RoomStyle(context).ink,
          backgroundColor: widget.path == route || _preview == route
              ? RoomStyle(context).soft
              : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.all(14),
        ),
        child:
            child ??
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(switch (route) {
                      '/wiki' => Icons.menu_book_outlined,
                      '/plaza' => Icons.forum_outlined,
                      '/gallery' => Icons.photo_library_outlined,
                      '/game' => Icons.sports_esports_outlined,
                      '/agent-os' => Icons.auto_awesome_outlined,
                      '/reality' => Icons.public_outlined,
                      '/friend-links' => Icons.link,
                      '/growth' => Icons.trending_up,
                      _ => Icons.rss_feed,
                    }, size: 18),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        siteDestinationLabel(context, route),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SiteText(
                  _descriptions[route]!,
                  style: TextStyle(
                    fontSize: 11,
                    color: RoomStyle(context).muted,
                  ),
                ),
              ],
            ),
      ),
    ),
  );
  Widget _art(String route, {double? height}) => Image.asset(
    navigationArtwork(RoomStyle(context).palette.season, route),
    fit: BoxFit.cover,
    height: height,
    width: double.infinity,
    cacheWidth: 800,
    gaplessPlayback: true,
    excludeFromSemantics: true,
  );
  Widget _panel() {
    if (_active == 0) {
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 252,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  children: [
                    for (final (i, route) in _routes.indexed) _link(route, i),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _art(_preview),
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 14,
                    child: SiteCard(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            siteDestinationLabel(context, _preview),
                            style: const TextStyle(
                              fontSize: 24,
                              fontFamily: RoomStyle.serif,
                            ),
                          ),
                          const SizedBox(height: 6),
                          SiteText(
                            _descriptions[_preview]!,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    if (_active == 1) {
      return Padding(
        padding: const EdgeInsets.all(9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, route) in _routes.indexed)
              Expanded(
                child: _link(
                  route,
                  i,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: _art(route, height: 168),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        siteDestinationLabel(context, route),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 7),
                      SiteText(
                        _descriptions[route]!,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [for (final (i, route) in _routes.indexed) _link(route, i)],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => TapRegion(
    groupId: _region,
    onTapOutside: (_) => _close(),
    child: OverlayPortal(
      controller: _overlay,
      overlayChildBuilder: (context) => AnimatedPositioned(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
        left: _position.dx,
        top: _position.dy,
        width: _width,
        child: TapRegion(
          groupId: _region,
          child: MouseRegion(
            onEnter: (_) => _closeTimer?.cancel(),
            onExit: (_) => _scheduleClose(),
            child: Material(
              elevation: 8,
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(24),
              clipBehavior: Clip.antiAlias,
              child: SiteSeasonalSurface(
                radius: 24,
                menu: true,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: math.max(
                      80,
                      MediaQuery.sizeOf(context).height - _position.dy - 16,
                    ),
                  ),
                  child: AnimatedSize(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 520),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topLeft,
                    child: SingleChildScrollView(child: _panel()),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () => widget.onGo('/hub'),
            child: const SiteText('中枢'),
          ),
          for (final (i, group) in siteNavigationGroups.keys.indexed)
            MouseRegion(
              onEnter: (_) => _open(i),
              onExit: (_) => _scheduleClose(),
              child: Focus(
                key: Key('site-navigation-group-$i'),
                onKeyEvent: (_, event) => _triggerKey(i, event),
                child: TextButton(
                  key: _anchors[i],
                  focusNode: _triggers[i],
                  onPressed: () => _active == i && _pinned
                      ? _close(restore: true)
                      : _open(i, pin: true),
                  style: TextButton.styleFrom(
                    backgroundColor:
                        _active == i ||
                            siteNavigationGroups[group]!.contains(widget.path)
                        ? RoomStyle(context).selected
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SiteText(group),
                      const Icon(Icons.expand_more, size: 16),
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
