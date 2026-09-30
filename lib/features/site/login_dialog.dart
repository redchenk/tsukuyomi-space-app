import 'package:flutter/material.dart';

import '../../core/site_localization.dart';
import '../room/room_controller.dart';
import 'native_auth_page.dart';
import 'qq_auth.dart';
import 'site_navigation.dart';

/// Protected page actions use the same full native authentication flow.
/// Successful login closes the modal so the awaiting action can reload data.
Future<void> showSiteLogin(BuildContext context, RoomController controller) {
  final returnPath = ModalRoute.of(context)?.settings.name ?? '/hub';
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _LoginFlow(
      controller: controller,
      returnPath: returnPath,
      onGo: (path) {
        if (context.mounted) navigateSite(context, controller, path);
      },
    ),
  );
}

class _LoginFlow extends StatefulWidget {
  const _LoginFlow({
    required this.controller,
    required this.returnPath,
    required this.onGo,
  });
  final RoomController controller;
  final String returnPath;
  final ValueChanged<String> onGo;
  @override
  State<_LoginFlow> createState() => _LoginFlowState();
}

class _LoginFlowState extends State<_LoginFlow> {
  late String _path;
  bool _authenticated = false;
  @override
  void initState() {
    super.initState();
    _path = Uri(
      path: '/login',
      queryParameters: {'redirect': sanitizeAuthRedirect(widget.returnPath)},
    ).toString();
  }

  void _go(String next) {
    if (!_authenticated &&
        ['/login', '/register'].contains(Uri.tryParse(next)?.path)) {
      setState(() => _path = next);
      return;
    }
    Navigator.pop(context);
    if (!_authenticated) widget.onGo(next);
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(12),
    clipBehavior: Clip.antiAlias,
    child: SizedBox(
      width: 960,
      height: MediaQuery.sizeOf(context).height * .9,
      child: Stack(
        children: [
          NativeAuthPage(
            controller: widget.controller,
            path: _path,
            onAuthenticated: () => _authenticated = true,
            onGo: _go,
          ),
          Positioned(
            right: 8,
            top: 8,
            child: IconButton(
              tooltip: siteTranslate(context, '关闭'),
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    ),
  );
}
