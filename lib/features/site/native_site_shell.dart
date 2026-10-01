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

class NativeSiteShell extends StatelessWidget {
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
  @override
  Widget build(BuildContext context) {
    final p = RoomStyle(context);
    final narrow = MediaQuery.sizeOf(context).width < 650;
    final route =
        Uri.tryParse(ModalRoute.of(context)?.settings.name ?? '')?.path ?? '';
    final showBeian =
        showChrome &&
        route != '/hub' &&
        route != '/room' &&
        !route.startsWith('/room/');
    Widget body = SingleChildScrollView(
      controller: scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              narrow ? 14 : 32,
              12,
              narrow ? 14 : 32,
              24,
            ),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: p.ink),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  child,
                  if (showBeian) const SiteBeianLinks(),
                  const SizedBox(height: 36),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (onRefresh != null) {
      body = RefreshIndicator(onRefresh: onRefresh!, child: body);
    }
    return Scaffold(
      backgroundColor: p.background,
      floatingActionButton: floatingActionButton,
      body: SiteBackground(
        child: SafeArea(
          child: Column(
            children: [
              if (showChrome)
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: narrow ? 14 : 24,
                    vertical: narrow ? 10 : 16,
                  ),
                  child: AnimatedBuilder(
                    animation: controller,
                    builder: (context, _) => SiteHeader(
                      title: title,
                      onGo: onGo,
                      onTheme: onTheme,
                      username: controller.sessionExpired
                          ? null
                          : controller.account?.displayName,
                      role: controller.sessionExpired
                          ? null
                          : controller.account?.role,
                      onLogin: () {
                        if (controller.account != null &&
                            !controller.sessionExpired) {
                          onGo('/user');
                        } else {
                          showSiteLogin(context, controller);
                        }
                      },
                    ),
                  ),
                ),
              Expanded(child: body),
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
  if (asset != null) {
    return Image.asset(
      asset,
      height: height,
      width: width,
      fit: fit,
      semanticLabel: label,
      errorBuilder: (_, _, _) => failed,
    );
  }
  try {
    final uri = endpointUri(site).resolve(value);
    if (value.isEmpty ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty) {
      return failed;
    }
    return Image.network(
      '$uri',
      height: height,
      width: width,
      fit: fit,
      semanticLabel: label,
      errorBuilder: (_, _, _) => failed,
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
