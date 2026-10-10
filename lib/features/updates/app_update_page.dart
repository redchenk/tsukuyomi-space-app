import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_update_controller.dart';
import '../../core/app_update_release.dart';
import '../room/room_controller.dart';
import '../room/room_style.dart';
import '../site/native_site_shell.dart';
import 'update_copy.dart';

class AppUpdateScope extends InheritedWidget {
  const AppUpdateScope({
    super.key,
    required this.controller,
    required super.child,
  });
  final AppUpdateController? controller;
  static AppUpdateController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppUpdateScope>()?.controller;
  @override
  bool updateShouldNotify(AppUpdateScope oldWidget) =>
      controller != oldWidget.controller;
}

/// Only this small indicator observes download progress, not the Room tree.
class AppUpdateButton extends StatelessWidget {
  const AppUpdateButton({super.key});
  @override
  Widget build(BuildContext context) {
    final controller = AppUpdateScope.maybeOf(context);
    if (controller == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => IconButton(
        key: const Key('app-update-button'),
        tooltip: updateText(context, controller.hasUpdate ? 'new' : 'title'),
        onPressed: () {
          if (ModalRoute.of(context)?.settings.name != '/app/update') {
            Navigator.of(context).pushNamed('/app/update');
          }
        },
        icon: Badge(
          isLabelVisible: controller.hasUpdate,
          child: const Icon(Icons.system_update_alt, size: 21),
        ),
      ),
    );
  }
}

class AppUpdatePage extends StatefulWidget {
  const AppUpdatePage({
    super.key,
    required this.updates,
    required this.room,
    required this.onGo,
    this.onTheme,
  });
  final AppUpdateController updates;
  final RoomController room;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  @override
  State<AppUpdatePage> createState() => _AppUpdatePageState();
}

class _AppUpdatePageState extends State<AppUpdatePage> {
  @override
  void initState() {
    super.initState();
    if (widget.updates.installed == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(widget.updates.check());
      });
    }
  }

  String t(String key) => updateText(context, key);
  Future<void> _install() async {
    final platform = widget.updates.installed?.platform;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('confirm')),
        content: SingleChildScrollView(
          child: Text(
            '${t('save')}${switch (platform) {
              UpdatePlatform.macos => '\n\n${t('macos')}',
              UpdatePlatform.linux => '\n\n${t('linux')}',
              UpdatePlatform.ios => '\n\n${t('ios')}',
              _ => '',
            }}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('back')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('continue')),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) await widget.updates.install();
  }

  @override
  Widget build(BuildContext context) => NativeSiteShell(
    controller: widget.room,
    title: t('title'),
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880),
        child: AnimatedBuilder(
          animation: widget.updates,
          builder: (context, _) {
            final c = widget.updates,
                p = RoomStyle(context),
                release = c.release;
            final platform = c.installed?.platform;
            Widget panel(List<Widget> children) => Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Material(
                color: p.surface,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: p.line),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
              ),
            );
            final canInstall = c.downloaded != null && !c.busy;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  t('intro'),
                  style: TextStyle(
                    fontFamily: RoomStyle.serif,
                    fontSize: 28,
                    color: p.ink,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  t('description'),
                  style: TextStyle(color: p.muted, height: 1.7),
                ),
                const SizedBox(height: 24),
                panel([
                  Text(t('current'), style: TextStyle(color: p.muted)),
                  const SizedBox(height: 8),
                  Text(
                    c.installed == null
                        ? '—'
                        : '${c.installed!.version.value} · ${c.installed!.build}',
                    key: const Key('app-installed-version'),
                    style: const TextStyle(fontSize: 20),
                  ),
                  if (platform != null) ...[
                    const SizedBox(height: 6),
                    Text(platform.label, style: TextStyle(color: p.muted)),
                  ],
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('app-update-check'),
                        onPressed: c.busy ? null : c.check,
                        icon: const Icon(Icons.refresh),
                        label: Text(t('check')),
                      ),
                      if (release != null)
                        TextButton(
                          onPressed: () => launchUrl(
                            release.url,
                            mode: LaunchMode.externalApplication,
                          ),
                          child: Text(t('github')),
                        ),
                    ],
                  ),
                  if (c.phase == AppUpdatePhase.checking) ...[
                    const SizedBox(height: 12),
                    Text(t('checking')),
                    const LinearProgressIndicator(),
                  ],
                  if (c.phase == AppUpdatePhase.idle &&
                      c.checkedAt != null) ...[
                    const SizedBox(height: 12),
                    Text(t('latest')),
                  ],
                  if (c.error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      t(c.error!),
                      key: const Key('app-update-error'),
                      style: TextStyle(color: p.danger, height: 1.6),
                    ),
                  ],
                ]),
                if (release != null)
                  panel([
                    Text(
                      t('new'),
                      style: TextStyle(
                        color: p.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(release.tag, style: const TextStyle(fontSize: 24)),
                    const SizedBox(height: 8),
                    Text(
                      '${platform?.label ?? ''} · ${(release.installer.size / (1024 * 1024)).toStringAsFixed(1)} MB',
                      style: TextStyle(color: p.muted),
                    ),
                    const SizedBox(height: 18),
                    if (c.phase == AppUpdatePhase.downloading ||
                        c.phase == AppUpdatePhase.verifying) ...[
                      Text(
                        t(
                          c.phase == AppUpdatePhase.verifying
                              ? 'verifying'
                              : 'downloading',
                        ),
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: c.phase == AppUpdatePhase.verifying
                            ? null
                            : c.total == 0
                            ? 0
                            : c.received / c.total,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${(c.received / (1024 * 1024)).toStringAsFixed(1)} / ${(c.total / (1024 * 1024)).toStringAsFixed(1)} MB',
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: c.cancel,
                          child: Text(t('cancel')),
                        ),
                      ),
                    ],
                    if (canInstall)
                      Text(t('ready'), style: TextStyle(color: p.success)),
                    if (c.phase == AppUpdatePhase.installing)
                      Text(t('installing')),
                    if (c.phase == AppUpdatePhase.permissionRequired)
                      Text(
                        t('permission'),
                        style: TextStyle(color: p.warning, height: 1.6),
                      ),
                    if (c.phase == AppUpdatePhase.opened)
                      Text(
                        t(
                          platform == UpdatePlatform.ios
                              ? 'iosOpened'
                              : 'opened',
                        ),
                        style: TextStyle(height: 1.6, color: p.success),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton.icon(
                          key: const Key('app-update-download'),
                          onPressed: c.busy
                              ? null
                              : canInstall
                              ? _install
                              : c.download,
                          icon: Icon(
                            canInstall ? Icons.install_desktop : Icons.download,
                          ),
                          label: Text(
                            t(
                              canInstall
                                  ? platform == UpdatePlatform.ios
                                        ? 'share'
                                        : {
                                            UpdatePlatform.macos,
                                            UpdatePlatform.linux,
                                          }.contains(platform)
                                        ? 'open'
                                        : 'install'
                                  : 'download',
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: c.busy ? null : c.remindLater,
                          child: Text(t('later')),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      t('source'),
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                    if ({
                      UpdatePlatform.macos,
                      UpdatePlatform.linux,
                      UpdatePlatform.ios,
                    }.contains(platform)) ...[
                      const SizedBox(height: 14),
                      Text(
                        t(platform!.name),
                        style: TextStyle(color: p.muted, height: 1.6),
                      ),
                    ],
                    if (release.notes.isNotEmpty) ...[
                      const Divider(height: 32),
                      Text(
                        t('notes'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      MarkdownBody(
                        data: release.notes,
                        selectable: true,
                        imageBuilder: (_, _, _) => const SizedBox.shrink(),
                        onTapLink: (_, href, _) {
                          final url = Uri.tryParse(href ?? '');
                          if (url != null &&
                              url.scheme == 'https' &&
                              url.userInfo.isEmpty) {
                            launchUrl(
                              url,
                              mode: LaunchMode.externalApplication,
                            );
                          }
                        },
                      ),
                    ],
                  ]),
                panel([
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('automatic')),
                    subtitle: Text(t('automaticNote')),
                    value: c.automatic,
                    onChanged: c.setAutomatic,
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('previews')),
                    subtitle: Text(t('previewNote')),
                    value: c.previews,
                    onChanged: c.busy ? null : c.setPreviews,
                  ),
                ]),
              ],
            );
          },
        ),
      ),
    ),
  );
}
