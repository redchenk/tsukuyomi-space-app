import 'package:flutter/material.dart';

import '../../core/site_routes.dart';
import '../room/room_controller.dart';
import 'site_widgets.dart';

Future<void> navigateSite(
  BuildContext context,
  RoomController controller,
  String value, {
  bool replace = false,
}) async {
  try {
    final target = resolveSiteTarget(controller.settings.siteUrl, value);
    final path = target.nativePath;
    if (path == null) {
      final opened = await openSiteLink(
        controller.settings.siteUrl,
        target.url.toString(),
      );
      if (!opened && context.mounted) _notice(context, '暂时无法打开网站');
      return;
    }
    final navigator = Navigator.of(context);
    if (Uri.parse(path).path == '/room') {
      var foundRoom = false;
      navigator.popUntil((route) {
        if (Uri.tryParse(route.settings.name ?? '')?.path == '/room') {
          foundRoom = true;
          return true;
        }
        return route.isFirst;
      });
      if (!foundRoom) navigator.pushNamed(path);
      return;
    }
    final current = ModalRoute.of(context)?.settings.name;
    if (current == path) return;
    if (replace && navigator.canPop()) {
      navigator.pushReplacementNamed(path);
    } else {
      navigator.pushNamed(path);
    }
  } catch (_) {
    if (context.mounted) _notice(context, '暂时无法打开此链接');
  }
}

void _notice(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// Handles direct route requests for pages still awaiting a native migration.
class SiteRouteFallback extends StatelessWidget {
  const SiteRouteFallback({
    super.key,
    required this.controller,
    required this.path,
  });
  final RoomController controller;
  final String path;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('月读空间')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('此页面暂未提供原生版本'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => navigateSite(context, controller, path),
              child: const Text('在网站打开'),
            ),
            TextButton(
              onPressed: () => navigateSite(context, controller, '/room'),
              child: const Text('返回房间'),
            ),
          ],
        ),
      ),
    ),
  );
}
