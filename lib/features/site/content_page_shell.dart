import '../../core/site_localization.dart';

import 'package:flutter/material.dart';

import '../room/room_controller.dart';
import '../room/room_style.dart';
import 'login_dialog.dart';
import 'site_chrome.dart';
import 'site_widgets.dart';

class ContentPageShell extends StatelessWidget {
  const ContentPageShell({
    super.key,
    required this.controller,
    required this.title,
    required this.onGo,
    required this.child,
    this.onTheme,
    this.loading = false,
    this.error = '',
    this.notice = '',
    this.onRefresh,
    this.maxWidth = 1200,
    this.toolbar,
  });
  final RoomController controller;
  final String title, error, notice;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  final bool loading;
  final Future<void> Function()? onRefresh;
  final Widget child;
  final Widget? toolbar;
  final double maxWidth;
  @override
  Widget build(BuildContext context) {
    final p = RoomStyle(context),
        narrow = MediaQuery.sizeOf(context).width < 650;
    final content = SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.all(narrow ? 14 : 24),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (notice.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: SiteText(notice),
                ),
              if (error.isNotEmpty)
                SiteCard(
                  child: Column(
                    children: [
                      Text(error),
                      const SizedBox(height: 8),
                      if (onRefresh != null)
                        TextButton(
                          onPressed: loading ? null : onRefresh,
                          child: const SiteText('重试'),
                        ),
                    ],
                  ),
                ),
              child,
              const SiteBeianFooter(),
            ],
          ),
        ),
      ),
    );
    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.all(narrow ? 14 : 24),
              child: SiteHeader(
                title: title,
                username: controller.account?.username,
                role: controller.sessionExpired
                    ? null
                    : controller.account?.role,
                onGo: onGo,
                onTheme: onTheme,
                onLogin: () {
                  if (controller.account == null || controller.sessionExpired) {
                    showSiteLogin(context, controller);
                  } else {
                    onGo('/user');
                  }
                },
              ),
            ),
            if (loading) const LinearProgressIndicator(minHeight: 2),
            if (controller.sessionExpired)
              MaterialBanner(
                content: const SiteText('登录已过期，本机草稿已保留。'),
                actions: [
                  TextButton(
                    onPressed: () => showSiteLogin(context, controller),
                    child: const SiteText('重新登录'),
                  ),
                ],
              ),
            if (toolbar != null)
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: narrow ? 14 : 24),
                    child: toolbar,
                  ),
                ),
              ),
            Expanded(
              child: onRefresh == null
                  ? content
                  : RefreshIndicator(onRefresh: onRefresh!, child: content),
            ),
          ],
        ),
      ),
    );
  }
}
