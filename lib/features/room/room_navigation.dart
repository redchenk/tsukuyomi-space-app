import 'package:flutter/material.dart';

import '../site/site_widgets.dart';
import '../site/site_search.dart';

/// Room uses the same top navigation as the rest of the native site.
class RoomNavigation extends StatelessWidget {
  const RoomNavigation({
    super.key,
    required this.mobile,
    required this.width,
    required this.onGo,
    required this.onSearch,
    required this.onSettings,
    this.onTheme,
    this.onAccount,
    this.accountLabel = '登录',
    this.title = '私人居所',
  });
  final bool mobile;
  final double width;
  final String title, accountLabel;
  final ValueChanged<String> onGo;
  final VoidCallback onSearch, onSettings;
  final VoidCallback? onAccount, onTheme;
  @override
  Widget build(BuildContext context) {
    final room = SiteControllerScope.maybeOf(context);
    return SiteHeader(
      key: const Key('site-header'),
      title: title,
      onGo: onGo,
      onLogin: onAccount ?? () {},
      onTheme: onTheme,
      username: room?.account?.displayName,
      role: room?.sessionExpired == true ? null : room?.account?.role,
    );
  }
}
