import '../../core/site_localization.dart';

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../room/room_controller.dart';
import '../room/room_style.dart';
import 'login_dialog.dart';
import 'site_archive_data.dart';
import 'site_chrome.dart';
import 'site_widgets.dart';
import 'site_mobile_navigation.dart';

class SiteArchive {
  static final Map<String, dynamic> data = mapOf(jsonDecode(siteArchiveJson));
  static Map<String, dynamic> get wiki => mapOf(data['wiki']);
  static Map<String, dynamic> get reality => mapOf(data['reality']);
  static Map<String, dynamic> get access => mapOf(data['access']);
  static List<Map<String, dynamic>> get entries => rowsOf(wiki['entries']);
  static Map<String, dynamic>? entry(String kind, String slug) {
    for (final entry in entries) {
      if (entry['kind'] == kind && entry['slug'] == slug) return entry;
    }
    return null;
  }

  static String entryPath(Map item) =>
      '/wiki/${item['kind'] == 'character' ? 'characters' : 'terms'}/${item['slug']}';
  static String? imageAsset(String value) {
    if (!RegExp(
          r'^/assets/images/wiki/(?:[a-z0-9_-]+/)*[a-z0-9_.-]+\.(?:gif|jpe?g|png|webp)$',
          caseSensitive: false,
        ).hasMatch(value) ||
        value.contains('..')) {
      return null;
    }
    return 'assets/images/${value.substring('/assets/images/'.length).replaceAll('/', '_')}';
  }
}

class NativeSiteShell extends StatefulWidget {
  const NativeSiteShell({
    super.key,
    required this.controller,
    required this.title,
    required this.onGo,
    required this.child,
    this.onTheme,
    this.onRefresh,
    this.scrollController,
    this.floatingActionButton,
    this.showChrome = true,
    this.maxWidth = 1280,
    this.footer,
    this.fullBleed = false,
    this.fixedViewport = false,
  });
  final RoomController controller;
  final String title;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  final Future<void> Function()? onRefresh;
  final ScrollController? scrollController;
  final Widget child;
  final Widget? floatingActionButton;
  final bool showChrome;
  final double maxWidth;
  final Widget? footer;
  final bool fullBleed;
  final bool fixedViewport;
  @override
  State<NativeSiteShell> createState() => _NativeSiteShellState();
}

class _NativeSiteShellState extends State<NativeSiteShell> {
  bool scrolled = false, hideDock = false;
  double lastOffset = 0;

  @override
  Widget build(BuildContext context) {
    final w = widget, p = RoomStyle(context);
    final narrow = MediaQuery.sizeOf(context).width <= 860;
    final route =
        Uri.tryParse(ModalRoute.of(context)?.settings.name ?? '')?.path ?? '';
    final dock =
        narrow &&
        !w.fixedViewport &&
        w.showChrome &&
        !route.startsWith('/articles/') &&
        !route.startsWith('/room') &&
        MediaQuery.viewInsetsOf(context).bottom == 0;
    final headerHeight = narrow ? 58.0 : 76.0;
    final body = SingleChildScrollView(
      controller: w.scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: w.fullBleed ? double.infinity : w.maxWidth,
          ),
          child: Padding(
            padding: w.fullBleed
                ? EdgeInsets.zero
                : EdgeInsets.fromLTRB(
                    narrow ? 14 : 32,
                    narrow ? 14 : 12,
                    narrow ? 14 : 32,
                    24,
                  ),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: p.ink),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  w.child,
                  if (w.showChrome &&
                      !w.fullBleed &&
                      !route.startsWith('/room'))
                    w.footer ?? const SiteBeianLinks(),
                  SizedBox(height: dock ? 100 : 36),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Scaffold(
      backgroundColor: p.background,
      floatingActionButton: w.floatingActionButton,
      body: SiteBackground(
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                top: w.showChrome ? headerHeight : 0,
                child: NotificationListener<ScrollUpdateNotification>(
                  onNotification: (n) {
                    if (n.depth != 0 || n.metrics.axis != Axis.vertical) {
                      return false;
                    }
                    final y = n.metrics.pixels;
                    final down = y - lastOffset;
                    final hidden =
                        y > 120 && (down.abs() < 3 ? hideDock : down > 0);
                    lastOffset = y;
                    if (scrolled != (y > 24) || hideDock != hidden) {
                      setState(() {
                        scrolled = y > 24;
                        hideDock = hidden;
                      });
                    }
                    return false;
                  },
                  child: RepaintBoundary(
                    child: w.fixedViewport
                        ? w.child
                        : w.onRefresh == null
                        ? body
                        : RefreshIndicator(
                            onRefresh: w.onRefresh!,
                            child: body,
                          ),
                  ),
                ),
              ),
              if (w.showChrome)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedBuilder(
                    animation: w.controller,
                    builder: (context, _) => SiteHeader(
                      onHero: w.fullBleed && !scrolled,
                      title: w.title,
                      onGo: w.onGo,
                      onTheme: w.onTheme,
                      username: w.controller.sessionExpired
                          ? null
                          : w.controller.account?.displayName,
                      role: w.controller.sessionExpired
                          ? null
                          : w.controller.account?.role,
                      onLogin: () {
                        if (w.controller.account != null &&
                            !w.controller.sessionExpired) {
                          w.onGo('/user');
                        } else {
                          showSiteLogin(context, w.controller);
                        }
                      },
                    ),
                  ),
                ),
              if (dock && !hideDock)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 8,
                  child: SiteMobileDock(
                    onTheme: w.onTheme,
                    path: w.fullBleed ? '/hub' : route,
                    onGo: w.onGo,
                    controller: w.controller,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class NativeSiteSection extends StatelessWidget {
  const NativeSiteSection({
    super.key,
    required this.title,
    required this.child,
    this.subtitle = '',
    this.translate = true,
    this.padding = const EdgeInsets.all(22),
  });
  final String title, subtitle;
  final bool translate;
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: SiteCard(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SiteText(
            title,
            translate: translate,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 8),
            SiteText(
              subtitle,
              translate: translate,
              style: TextStyle(color: RoomStyle(context).muted, height: 1.7),
            ),
          ],
          const SizedBox(height: 18),
          child,
        ],
      ),
    ),
  );
}

Widget nativeSiteImage(
  String site,
  String value, {
  double? height,
  double? width,
  BoxFit fit = BoxFit.cover,
  String label = '',
  Widget? fallback,
}) {
  final failed =
      fallback ??
      SizedBox(
        height: height ?? 120,
        width: width,
        child: const Center(child: Icon(Icons.image_not_supported_outlined)),
      );
  final asset = SiteArchive.imageAsset(value);
  try {
    final uri = asset == null ? endpointUri(site).resolve(value) : null;
    if (asset == null &&
        (value.isEmpty ||
            !['http', 'https'].contains(uri!.scheme) ||
            uri.userInfo.isNotEmpty)) {
      return failed;
    }
    return LayoutBuilder(
      builder: (context, box) {
        final logicalWidth =
            (width?.isFinite == true ? width : null) ??
            (box.hasBoundedWidth
                ? box.maxWidth
                : MediaQuery.sizeOf(context).width);
        final ratio = MediaQuery.devicePixelRatioOf(context);
        final logicalHeight =
            (height?.isFinite == true ? height : null) ??
            (box.hasBoundedHeight
                ? box.maxHeight
                : MediaQuery.sizeOf(context).height);
        final ImageProvider provider = asset != null
            ? AssetImage(asset)
            : NetworkImage('$uri');
        return Image(
          image: ResizeImage(
            provider,
            width: (logicalWidth * ratio).ceil().clamp(1, 2048),
            height: (logicalHeight * ratio).ceil().clamp(1, 2048),
            policy: ResizeImagePolicy.fit,
          ),
          height: height,
          width: width,
          fit: fit,
          semanticLabel: label,
          errorBuilder: (_, _, _) => failed,
        );
      },
    );
  } catch (_) {
    return failed;
  }
}

Widget nativeSiteFeedback(
  BuildContext context,
  String message, {
  VoidCallback? retry,
  bool error = false,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 16),
  child: SiteCard(
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        Icon(
          error ? Icons.error_outline : Icons.info_outline,
          color: error
              ? Theme.of(context).colorScheme.error
              : RoomStyle(context).accent,
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
        if (retry != null)
          TextButton(onPressed: retry, child: const SiteText('重试')),
      ],
    ),
  ),
);
