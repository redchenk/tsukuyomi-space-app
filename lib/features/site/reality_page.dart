import '../../core/site_localization.dart';

import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

import '../../core/models.dart';
import '../room/room_controller.dart';
import 'native_site_shell.dart';
import 'site_widgets.dart';

class RealityPage extends StatefulWidget {
  const RealityPage({
    super.key,
    required this.controller,
    this.path = '/reality',
    required this.onGo,
    this.onTheme,
  });
  final RoomController controller;
  final String path;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  @override
  State<RealityPage> createState() => _RealityPageState();
}

class _RealityPageState extends State<RealityPage> {
  final _anchors = <String, GlobalKey>{};
  Map<String, dynamic> get data {
    final language = SiteLocaleScope.maybeOf(context)?.language ?? 'zh';
    return language == 'zh'
        ? SiteArchive.reality
        : mapOf(mapOf(SiteArchive.reality['localized'])[language]);
  }

  Map<String, dynamic> get copy => mapOf(data['copy']);
  String t(String key) => textOf(copy, 'reality$key');
  GlobalKey _key(String id) => _anchors.putIfAbsent(id, GlobalKey.new);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _jump(Uri.parse(widget.path).fragment),
    );
  }

  @override
  void didUpdateWidget(covariant RealityPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _jump(Uri.parse(widget.path).fragment),
      );
    }
  }

  void _jump(String id) {
    final target = _anchors[id]?.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 200),
        alignment: .05,
      );
    }
  }

  Widget _paragraph(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: SelectableText(
      text,
      style: const TextStyle(height: 1.85, fontSize: 16),
    ),
  );
  @override
  Widget build(BuildContext context) => NativeSiteShell(
    controller: widget.controller,
    title: t('Title'),
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SitePageHero(
          title: t('Title'),
          subtitle: '${t('Eyebrow')}\n${t('Subtitle')}',
          actions: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final key in const {
                'contact': 'ContactTitle',
                'support': 'SupportTitle',
                'privacy': 'PrivacyTitle',
              }.entries)
                OutlinedButton(
                  onPressed: () => _jump(key.key),
                  child: Text(t(key.value)),
                ),
            ],
          ),
        ),
        NativeSiteSection(
          key: _key('contact'),
          title: t('ContactTitle'),
          subtitle: t('ContactLead'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final item in const {
                'Repo': 'https://github.com/redchenk/tsukuyomi-space',
                'Issues': 'https://github.com/redchenk/tsukuyomi-space/issues',
                'Plaza': '/plaza',
              }.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: SiteCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t('Contact${item.key}'),
                          style: const TextStyle(fontSize: 20),
                        ),
                        const SizedBox(height: 10),
                        _paragraph(t('Contact${item.key}Desc')),
                        OutlinedButton.icon(
                          onPressed: () => widget.onGo(item.value),
                          icon: const Icon(Icons.arrow_forward),
                          label: Text(t('Contact${item.key}')),
                        ),
                      ],
                    ),
                  ),
                ),
              TextButton(
                onPressed: () => widget.onGo('/user-center'),
                child: const SiteText('用户中心'),
              ),
            ],
          ),
        ),
        NativeSiteSection(
          key: _key('support'),
          title: t('SupportTitle'),
          subtitle: t('SupportLead'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: InkWell(
                    onTap: () => widget.onGo(
                      'https://www.ifdian.net/a/redchenk?utm_source=copylink&utm_medium=link',
                    ),
                    child: Image.asset(
                      'assets/images/afdian-redchenk.jpg',
                      fit: BoxFit.contain,
                      semanticLabel: t('SupportImageAlt'),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              _paragraph(t('SupportNote')),
              FilledButton(
                onPressed: () => widget.onGo(
                  'https://www.ifdian.net/a/redchenk?utm_source=copylink&utm_medium=link',
                ),
                child: Text(t('SupportAction')),
              ),
            ],
          ),
        ),
        NativeSiteSection(
          key: _key('privacy'),
          title: t('PrivacyTitle'),
          subtitle: t('PrivacyLead'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final row in rowsOf(data['privacyRows']))
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: SiteCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          textOf(row, 'type'),
                          style: const TextStyle(fontSize: 20),
                        ),
                        const SizedBox(height: 10),
                        _paragraph(textOf(row, 'purpose')),
                        _paragraph(textOf(row, 'storage')),
                      ],
                    ),
                  ),
                ),
              _paragraph(
                '原生客户端：设备配置、访客会话与草稿保存在本机；API Key 与会话密钥使用系统安全存储。登录后的会话、长期记忆、日记和公开互动使用相同网站服务器与账号权限。',
              ),
            ],
          ),
        ),
        NativeSiteSection(
          key: _key('rights'),
          title: t('RightsTitle'),
          subtitle: t('RightsLead'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final card in rowsOf(data['rightsCards'])) ...[
                Text(
                  textOf(card, 'title'),
                  style: const TextStyle(fontSize: 20),
                ),
                const SizedBox(height: 10),
                for (final item in card['items'] as List) _paragraph('• $item'),
              ],
            ],
          ),
        ),
        NativeSiteSection(
          key: _key('notice'),
          title: t('NoticeTitle'),
          subtitle: t('NoticeLead'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final key in ['Virtual', 'Links', 'Update'])
                _paragraph(t('Notice$key')),
              for (final html in data['attributions'] as List)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: HtmlWidget(
                    '$html',
                    buildAsync: false,
                    baseUrl: endpointUri(widget.controller.settings.siteUrl),
                    textStyle: const TextStyle(height: 1.85, fontSize: 15),
                    onTapUrl: (value) {
                      widget.onGo(value);
                      return true;
                    },
                  ),
                ),
            ],
          ),
        ),
        Center(
          child: Column(
            children: [
              Text(t('FooterBrand')),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => widget.onGo('/hub'),
                child: Text(t('FooterBack')),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
