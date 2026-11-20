import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../../core/site_localization.dart';
import '../room/room_controller.dart';
import 'native_site_shell.dart';
import 'site_widgets.dart';

class PlayApplyPage extends StatefulWidget {
  const PlayApplyPage({
    super.key,
    required this.controller,
    required this.onGo,
    this.onTheme,
  });
  final RoomController controller;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  @override
  State<PlayApplyPage> createState() => _PlayApplyState();
}

class _PlayApplyState extends State<PlayApplyPage> {
  final form = GlobalKey<FormState>();
  final sections = {
    for (final s in ['apply', 'guide', 'testing', 'faq', 'dataUse'])
      s: GlobalKey(),
  };
  final email = TextEditingController(),
      device = TextEditingController(),
      version = TextEditingController();
  Map<String, dynamic> words = {}, config = {};
  bool busy = false, eligible = false, consent = false, received = false;
  String error = '', owner = '';
  int revision = 0;
  @override
  void initState() {
    super.initState();
    owner = widget.controller.scope;
    widget.controller.addListener(ownerChanged);
    loadWords();
    load();
  }

  void ownerChanged() {
    if (owner != widget.controller.scope) {
      owner = widget.controller.scope;
      email.clear();
      device.clear();
      version.clear();
      consent = false;
      eligible = false;
      received = false;
      config = {};
      load();
    }
  }

  Future<void> loadWords() async {
    final data = jsonDecode(
      await rootBundle.loadString('assets/site/play-testing.json'),
    );
    if (mounted) setState(() => words = mapOf(data));
  }

  Future<void> load() async {
    final run = ++revision;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final r = await (widget.controller.site as SiteDataService).request(
        widget.controller.settings.siteUrl,
        'GET',
        '/api/play-testing',
      );
      if (mounted && revision == run) setState(() => config = mapOf(r['data']));
    } catch (e) {
      if (mounted && revision == run) setState(() => error = '$e');
    } finally {
      if (mounted && revision == run) setState(() => busy = false);
    }
  }

  Future<void> submit() async {
    if (busy ||
        received ||
        !eligible ||
        !consent ||
        config['registrationOpen'] != true ||
        form.currentState?.validate() != true) {
      return;
    }
    final run = ++revision;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await (widget.controller.site as SiteDataService).request(
        widget.controller.settings.siteUrl,
        'POST',
        '/api/play-testing',
        {
          'email': email.text.trim(),
          'device': device.text.trim(),
          'androidVersion': version.text.trim(),
          'eligible': eligible,
          'consent': consent,
          'website': '',
          'consentVersion': config['consentVersion'],
        },
      );
      if (result['success'] != true) {
        throw ApiFailure(textOf(result, 'message'));
      }
      if (mounted && run == revision) {
        setState(() => received = true);
        jump('apply');
      }
    } catch (e) {
      if (mounted && run == revision) setState(() => error = '$e');
    } finally {
      if (mounted && run == revision) setState(() => busy = false);
    }
  }

  void jump(String key) {
    final ctx = sections[key]?.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, alignment: .12);
  }

  @override
  void dispose() {
    revision++;
    widget.controller.removeListener(ownerChanged);
    email.dispose();
    device.dispose();
    version.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (words.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final d = mapOf(
      words[SiteLocaleScope.maybeOf(context)?.language == 'zh' ||
              SiteLocaleScope.maybeOf(context) == null
          ? 'zh'
          : 'en'],
    );
    final policy = mapOf(words['policy']);
    String t(String key) => textOf(d, key);
    Widget action(String key, VoidCallback cb) =>
        TextButton(onPressed: cb, child: Text(t(key)));
    Widget field(
      TextEditingController controller,
      String label,
      int max, {
      bool mail = false,
    }) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextFormField(
        controller: controller,
        enabled: !busy,
        maxLength: max,
        keyboardType: mail ? TextInputType.emailAddress : TextInputType.text,
        autocorrect: !mail,
        autofillHints: mail ? const [AutofillHints.email] : null,
        decoration: InputDecoration(
          labelText: t(label),
          hintText: mail ? 'you@gmail.com' : null,
          counterText: '',
        ),
        validator: mail
            ? (s) =>
                  RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                      .hasMatch((s ?? '').trim())
                  ? null
                  : t('emailHelp')
            : null,
      ),
    );
    void feedback() {
      launchUrl(
        Uri(
          scheme: 'mailto',
          path: textOf(policy, 'contact'),
          queryParameters: {'subject': t('eyebrow')},
        ),
      );
    }

    return NativeSiteShell(
      controller: widget.controller,
      title: t('formTitle'),
      onGo: widget.onGo,
      onTheme: widget.onTheme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SitePageHero(
            title: t('title'),
            kicker: t('eyebrow'),
            subtitle: t('intro'),
          ),
          Wrap(
            spacing: 6,
            children: [
              for (final tag in ['android', 'days', 'honest'])
                Chip(label: Text(t(tag))),
            ],
          ),
          Wrap(
            children: [
              for (final key in ['apply', 'guide', 'testing', 'faq'])
                action(key, () => jump(key)),
            ],
          ),
          NativeSiteSection(
            key: sections['apply'],
            title: t(received ? 'receiptTitle' : 'formTitle'),
            subtitle: t(received ? 'receipt' : 'formIntro'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (received) ...[
                  SelectableText(email.text.trim()),
                  Text(t('receiptInfo')),
                  Text(t('receiptWait')),
                  action('receiptNext', () => jump('guide')),
                ] else if (config['registrationOpen'] == true)
                  Form(
                    key: form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        field(email, 'email', 254, mail: true),
                        Text(t('emailHelp')),
                        field(device, 'device', 80),
                        field(version, 'version', 40),
                        CheckboxListTile(
                          value: eligible,
                          onChanged: busy
                              ? null
                              : (v) => setState(() => eligible = v == true),
                          title: Text(t('eligible')),
                        ),
                        CheckboxListTile(
                          value: consent,
                          onChanged: busy
                              ? null
                              : (v) => setState(() => consent = v == true),
                          title: Text(
                            [
                              t('consent'),
                              t('dataUse'),
                              t('and'),
                              t('privacy'),
                              t('dot'),
                            ].join(' '),
                          ),
                        ),
                        Wrap(
                          children: [
                            action('dataUse', () => jump('dataUse')),
                            action('privacy', () => widget.onGo('/privacy')),
                          ],
                        ),
                        FilledButton(
                          onPressed: !eligible || !consent || busy
                              ? null
                              : submit,
                          child: Text(t(busy ? 'submitting' : 'submit')),
                        ),
                        Text(t('noSecrets')),
                      ],
                    ),
                  )
                else if (config.isNotEmpty)
                  Text(t('closed')),
                if (busy) const LinearProgressIndicator(),
                if (error.isNotEmpty) ...[
                  Text(error),
                  if (config.isEmpty) action('retry', load),
                ],
              ],
            ),
          ),
          NativeSiteSection(
            key: sections['guide'],
            title: t('guideTitle'),
            subtitle: t('guideIntro'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t('internal')),
                for (final step in d['steps'] as List? ?? [])
                  ListTile(title: Text(step[0]), subtitle: Text(step[1])),
                if (Uri.tryParse(textOf(config, 'joinUrl'))?.host ==
                    'play.google.com')
                  action('join', () => widget.onGo(config['joinUrl'])),
                Text(t('requirements')),
                action(
                  'official',
                  () => widget.onGo(policy['requirementsUrl']),
                ),
              ],
            ),
          ),
          NativeSiteSection(
            key: sections['testing'],
            title: t('testingTitle'),
            child: Column(
              children: [
                for (final key in ['character', 'memory', 'mobile', 'feedback'])
                  ListTile(
                    title: Text(t(key == 'feedback' ? 'feedbackTitle' : key)),
                    subtitle: Text(t('${key}Body')),
                  ),
                action('feedback', feedback),
              ],
            ),
          ),
          NativeSiteSection(
            key: sections['faq'],
            title: t('faqTitle'),
            child: Column(
              children: [
                for (final item in d['faqs'] as List? ?? [])
                  ExpansionTile(
                    title: Text(item[0]),
                    children: [ListTile(title: Text(item[1]))],
                  ),
              ],
            ),
          ),
          NativeSiteSection(
            key: sections['dataUse'],
            title: t('dataTitle'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('dataBody')),
                Text(t('contact')),
                TextButton(
                  onPressed: feedback,
                  child: Text(textOf(policy, 'contact')),
                ),
                action('privacyFull', () => widget.onGo('/privacy')),
                action(
                  'googleGuide',
                  () => widget.onGo(policy['joiningGuideUrl']),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
