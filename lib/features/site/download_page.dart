import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_update_release.dart';
import '../../core/site_client.dart';
import '../../core/site_localization.dart';
import '../room/room_controller.dart';
import 'native_site_shell.dart';
import 'site_widgets.dart';

class DownloadPage extends StatefulWidget {
  const DownloadPage({
    super.key,
    required this.controller,
    required this.onGo,
    this.onTheme,
  });
  final RoomController controller;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage>
    with WidgetsBindingObserver {
  Map<String, dynamic> copy = {};
  List<Map<String, dynamic>> releases = [];
  bool loading = false;
  bool? preview;
  String source = 'verified', error = '';
  final platforms = GlobalKey();
  int revision = 0;
  String origin = '';
  Timer? timer;
  static const suffixes = {
    'windows': 'windows-x64-setup.exe',
    'windowsPortable': 'windows-x64.zip',
    'macos': 'macos-universal.dmg',
    'android': 'android-arm64-v8a.apk',
    'androidEmulator': 'android-x86_64.apk',
    'linux': 'linux-x64.deb',
    'linuxPortable': 'linux-x64.tar.gz',
    'ios': 'ios-arm64-unsigned.ipa',
    'ohosInstall': 'OHOS-INSTALL.md',
    'ohosChecksums': 'OHOS-SHA256SUMS.txt',
    'checksums': 'SHA256SUMS.txt',
    'install': 'INSTALL.md',
    'notices': 'THIRD_PARTY_NOTICES.md',
  };
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(siteChanged);
    origin = widget.controller.settings.siteUrl;
    initialize();
    timer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          ModalRoute.of(context)?.isCurrent == true) {
        refresh();
      }
    });
  }

  void siteChanged() {
    final next = widget.controller.settings.siteUrl;
    if (next != origin) {
      origin = next;
      revision++;
      loading = false;
      refresh();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        ModalRoute.of(context)?.isCurrent == true) {
      refresh();
    }
  }

  Future<void> initialize() async {
    final data = await Future.wait([
      rootBundle.loadString('assets/site/download-copy.json'),
      rootBundle.loadString('assets/site/app-releases.json'),
    ]);
    if (!mounted) return;
    setState(() {
      copy = mapOf(jsonDecode(data[0]));
      if (releases.isEmpty) releases = valid(jsonDecode(data[1]));
    });
    await refresh();
  }

  List<Map<String, dynamic>> valid(dynamic data) {
    final items = rowsOf(data)
        .where(
          (r) => AppUpdateRelease.parse(r, UpdatePlatform.androidArm64) != null,
        )
        .toList();
    items.sort(
      (a, b) =>
          AppVersion.parse(b['tag_name'])!
              .compareTo(AppVersion.parse(a['tag_name'])!),
    );
    return items;
  }

  Future<void> refresh() async {
    if (loading) return;
    final ticket = ++revision;
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final result = await (widget.controller.site as SiteDataService).request(
        origin,
        'GET',
        '/api/app/releases',
      );
      final data = mapOf(result['data']);
      final list = valid(data['releases']);
      if (list.isEmpty) throw const FormatException('Invalid catalog');
      if (mounted && revision == ticket) {
        setState(() {
          releases = list;
          source = data['source'] == 'distribution'
              ? 'latest'
              : data['source'] == 'cache'
              ? 'cached'
              : 'verified';
          if (data['stale'] == true) error = 'checkFailedCached';
        });
      }
    } catch (_) {
      if (mounted && revision == ticket) setState(() => error = 'checkFailed');
    } finally {
      if (mounted && revision == ticket) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    revision++;
    timer?.cancel();
    widget.controller.removeListener(siteChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (copy.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final labels = mapOf(
      copy[SiteLocaleScope.maybeOf(context)?.language ?? 'zh'],
    );
    String t(String key) => textOf(labels, key);
    final row =
        releases.where((r) => r['prerelease'] == preview).firstOrNull ??
        releases.firstOrNull;
    final tag = textOf(row ?? {}, 'tag_name'),
        version = AppVersion.parse(tag)?.base;
    final assets = rowsOf(row?['assets']);
    UpdateAsset? asset(String key) {
      String? name = suffixes[key];
      if (key == 'ohos') {
        final pattern = RegExp(
          '^tsukuyomi-space-${RegExp.escape(version ?? '')}-[1-9][0-9]{0,8}-ohos-arm64-unsigned\\.hap\$',
        );
        final files = assets.where((a) => pattern.hasMatch(textOf(a, 'name')));
        if (files.length != 1) return null;
        name = textOf(files.single, 'name');
      } else if (name == null) {
        return null;
      } else if (!name.endsWith('.md') && !name.endsWith('.txt')) {
        name = 'tsukuyomi-space-$version-$name';
      }
      final files = assets.where((a) => a['name'] == name);
      return files.length == 1
          ? UpdateAsset.parse(files.single, tag, name)
          : null;
    }

    Widget link(String label, UpdateAsset? file) => TextButton.icon(
      icon: const Icon(Icons.download_outlined, size: 16),
      onPressed: file == null ? null : () => widget.onGo(file.url.toString()),
      label: Text(label),
    );
    final platform = Theme.of(context).platform.name.toLowerCase();
    final names = mapOf(labels['platformsCopy']);
    return NativeSiteShell(
      controller: widget.controller,
      title: t('app'),
      onTheme: widget.onTheme,
      onGo: widget.onGo,
      onRefresh: refresh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SitePageHero(
            title: t('title'),
            kicker: t('eyebrow'),
            subtitle: t('intro'),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (asset(platform) != null)
                link(textOf(mapOf(names[platform]), 'action'), asset(platform)),
              TextButton(
                onPressed: () {
                  final ctx = platforms.currentContext;
                  if (ctx != null) Scrollable.ensureVisible(ctx);
                },
                child: Text(t('other')),
              ),
              TextButton(
                onPressed: () => widget.onGo('/apply'),
                child: Text(
                  SiteLocaleScope.maybeOf(context)?.language == 'en'
                      ? 'Join the Google Play closed test'
                      : '参与 Google Play 封闭测试 · 报名与加入教程',
                ),
              ),
            ],
          ),
          if (row != null)
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '$tag · ${t(source)} · ${textOf(row, 'published_at').split('T').first}',
                ),
                if (releases.any((r) => r['prerelease'] == true) &&
                    releases.any((r) => r['prerelease'] == false))
                  for (final channel in [false, true])
                    ChoiceChip(
                      label: Text(t(channel ? 'preview' : 'stable')),
                      selected: row['prerelease'] == channel,
                      onSelected: (_) => setState(() => preview = channel),
                    ),
                TextButton(
                  onPressed: () =>
                      widget.onGo('$appRepository/releases/tag/$tag'),
                  child: Text(t('versionNotes')),
                ),
                TextButton(
                  onPressed: loading ? null : refresh,
                  child: Text(t(loading ? 'checking' : 'check')),
                ),
              ],
            ),
          if (error.isNotEmpty) Text(t(error)),
          if (loading) const LinearProgressIndicator(),
          const SizedBox(height: 20),
          Text(
            t('platforms'),
            key: platforms,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Text(t('platformIntro')),
          const SizedBox(height: 12),
          SiteResponsiveGrid(
            minWidth: 310,
            children: [
              for (final item in names.entries)
                Builder(
                  builder: (context) {
                    final info = mapOf(item.value), file = asset(item.key);
                    final extra = {
                      'windows': 'windowsPortable',
                      'android': 'androidEmulator',
                      'linux': 'linuxPortable',
                    }[item.key];
                    return SiteCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            textOf(info, 'name'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(textOf(info, 'target')),
                          const SizedBox(height: 10),
                          Text(textOf(info, 'note')),
                          if (file != null)
                            Text(
                              '${textOf(info, 'format')} · ${(file.size / 1048576).toStringAsFixed(1)} MB',
                            ),
                          link(
                            file == null
                                ? t('unavailable')
                                : textOf(info, 'action'),
                            file,
                          ),
                          if (extra != null && asset(extra) != null)
                            link(textOf(info, 'extra'), asset(extra)),
                          if (textOf(info, 'extraNote').isNotEmpty)
                            Text(textOf(info, 'extraNote')),
                          if (item.key == 'ohos') ...[
                            link(
                              textOf(info, 'guideAction'),
                              asset('ohosInstall') ?? asset('install'),
                            ),
                            link(t('checksum'), asset('ohosChecksums')),
                          ],
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            t('stepsTitle'),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          for (final step in labels['steps'] as List? ?? [])
            ListTile(title: Text(step[0]), subtitle: Text(step[1])),
          if (labels['help'] is List)
            for (final item in labels['help'])
              ExpansionTile(
                title: Text(item[0]),
                children: [ListTile(title: Text(item[1]))],
              ),
          Wrap(
            children: [
              link(t('guide'), asset('install')),
              link(t('checksum'), asset('checksums')),
              TextButton(
                onPressed: () => widget.onGo('$appRepository/releases'),
                child: Text(t('history')),
              ),
              TextButton(
                onPressed: () => widget.onGo(appRepository),
                child: Text(t('source')),
              ),
              TextButton(
                onPressed: () => widget.onGo('/room'),
                child: Text(t('web')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
