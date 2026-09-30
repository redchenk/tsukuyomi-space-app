import '../../core/site_localization.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

import '../../core/llm_client.dart';
import '../../core/room_archive.dart';
import '../../core/room_reference.dart';
import '../../live2d/character_stage.dart';
import '../../live2d/live2d_semantics.dart';
import '../room/room_controller.dart';
import '../site/native_site_shell.dart';
import 'live2d_director_controller.dart';

class Live2DPage extends StatefulWidget {
  const Live2DPage({
    super.key,
    required this.controller,
    this.path = '/live2d',
    required this.onGo,
    this.onTheme,
    this.loadNative = true,
    this.modelLoader,
    this.director,
    this.directorChat,
  });
  final RoomController controller;
  final String path;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  final bool loadNative;
  final Future<Live2DModel> Function()? modelLoader;
  final Live2DDirectorController? director;
  final ChatService? directorChat;
  @override
  State<Live2DPage> createState() => _Live2DPageState();
}

class _Live2DPageState extends State<Live2DPage> with WidgetsBindingObserver {
  late final Live2DDirectorController d;
  final _stageKey = GlobalKey();
  final _prompt = TextEditingController(text: '向观众打个招呼，选择明亮的表情和自然的动作。'),
      _topic = TextEditingController(),
      _audience = TextEditingController(),
      _json = TextEditingController(
        text: '{\n  "expression": "smile",\n  "actions": [{"type": "head_tilt", "side": "left", "duration": 1.2}],\n  "durationMs": 3000\n}',
      );
  bool _ready = false, _streaming = true;
  String _commandError = '';
  bool get canAct => _ready || d.animation.ready;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    d =
        widget.director ??
        Live2DDirectorController(widget.controller, chat: widget.directorChat);
    _topic.text = d.topic;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) d.stop();
  }

  void _act(Map<String, dynamic> command) {
    try {
      d.animation.custom(command);
      setState(() => _commandError = '');
    } catch (e) {
      setState(() => _commandError = '$e');
    }
  }

  void _sendAudience() {
    d.sendAudience(_audience.text);
    _audience.clear();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.director == null) {
      d.dispose();
    } else {
      d.stop();
    }
    for (final field in [_prompt, _topic, _audience, _json]) {
      field.dispose();
    }
    super.dispose();
  }

  Widget _stage() => NativeSiteSection(
    title: 'Yachiyo Live2D 原生舞台',
    subtitle: 'Cubism Native · 表情、身体与语义动作在本机模型上执行',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            Chip(label: Text(canAct ? 'READY' : 'STANDBY')),
            Chip(
              label: Text(
                '${d.running
                    ? d.status == 'thinking'
                          ? 'THINKING'
                          : d.status == 'speaking'
                          ? 'SPEAKING'
                          : 'ON AIR'
                    : 'OFF AIR'} · #${d.turn}',
              ),
            ),
            if (widget.controller.voice.playing)
              const Chip(label: SiteText('VOICE')),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: MediaQuery.sizeOf(context).width < 600 ? 490 : 570,
          child: CharacterStage(
            key: _stageKey,
            voice: widget.controller.voice,
            animation: d.animation,
            settings: widget.controller.settings,
            loadNative: widget.loadNative,
            modelLoader: widget.modelLoader,
            onReady: (ready) {
              if (mounted) setState(() => _ready = ready);
            },
            mobile: MediaQuery.sizeOf(context).width < 700,
            onSettings: () => widget.onGo('/room/settings'),
            onVoiceSettings: () => widget.onGo('/room/settings?tab=voice'),
          ),
        ),
        if (d.caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Semantics(
              liveRegion: true,
              child: SelectableText(
                d.caption,
                key: const Key('live2d-caption'),
                style: const TextStyle(fontSize: 20, height: 1.65),
              ),
            ),
          ),
        if (d.showLog.isNotEmpty)
          ExpansionTile(
            initiallyExpanded: true,
            title: const SiteText('直播记录'),
            children: [
              for (final line in d.showLog)
                ListTile(
                  title: Text(
                    line['role'] == 'yachiyo'
                        ? 'Yachiyo'
                        : line['role'] == 'audience'
                        ? 'Chat'
                        : 'System',
                  ),
                  subtitle: Text(
                    '${line['text']}',
                    style: const TextStyle(height: 1.7),
                  ),
                ),
            ],
          ),
      ],
    ),
  );
  Widget _controls() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      NativeSiteSection(
        title: '直播导演',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('live2d-topic'),
              controller: _topic,
              onChanged: (text) => d.topic = text,
              decoration: InputDecoration(
                labelText: siteTranslate(context, '直播主题'),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const SiteText('自动语音'),
              value: d.autoVoice,
              onChanged: (value) => setState(() => d.autoVoice = value),
            ),
            FilledButton.icon(
              key: const Key('live2d-director'),
              onPressed: d.running
                  ? d.stop
                  : canAct && !d.loading
                  ? d.start
                  : null,
              icon: Icon(d.running ? Icons.stop : Icons.play_arrow),
              label: SiteText(d.running ? '停止直播' : '开始直播'),
            ),
            const SizedBox(height: 18),
            TextField(
              key: const Key('live2d-audience'),
              controller: _audience,
              onSubmitted: (_) => _sendAudience(),
              maxLength: 500,
              decoration: InputDecoration(
                labelText: siteTranslate(context, '观众留言'),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _sendAudience,
              icon: const Icon(Icons.send_outlined),
              label: const SiteText('加入观众队列'),
            ),
            if (d.audienceQueue.isNotEmpty)
              Text(
                siteTr(
                  context,
                  'nativeLive2DAudienceQueue',
                  fallback: '{count} 条留言等待回应',
                  params: {'count': d.audienceQueue.length},
                ),
              ),
            if (d.error.isNotEmpty)
              Text(
                d.error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (d.speechError.isNotEmpty)
              Text(
                d.speechError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      NativeSiteSection(
        title: '表情与动作测试',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in RoomReference.rows('expressions'))
                  OutlinedButton(
                    onPressed: canAct
                        ? () => _act({
                            'expression': item['id'],
                            'durationMs': 4200,
                          })
                        : null,
                    child: Text('${item['label']}'),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in Live2DSemantics.actions)
                  OutlinedButton(
                    onPressed: canAct
                        ? () => _act({
                            'actions': [
                              {'type': item['id'], 'intensity': .85},
                            ],
                            'durationMs': 2600,
                          })
                        : null,
                    child: Text('${item['label']}'),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: canAct
                      ? () => _act({
                          'sequence': [
                            {
                              'expression': 'smile',
                              'bodyPose': 'bounce',
                              'durationMs': 2300,
                            },
                            {
                              'expression': 'bsmile',
                              'bodyPose': 'lean_in',
                              'delayMs': 180,
                              'durationMs': 2600,
                            },
                            {
                              'expression': 'neutral',
                              'bodyPose': 'sway',
                              'delayMs': 180,
                              'durationMs': 2200,
                            },
                          ],
                        })
                      : null,
                  child: const SiteText('打招呼'),
                ),
                OutlinedButton(
                  onPressed: canAct && d.caption.isNotEmpty && !d.loading
                      ? d.speakCaption
                      : null,
                  child: const SiteText('朗读字幕'),
                ),
                OutlinedButton(
                  onPressed: d.animation.clear,
                  child: const SiteText('清空动作队列'),
                ),
              ],
            ),
          ],
        ),
      ),
      NativeSiteSection(
        title: '单次 LLM 导演',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('live2d-prompt'),
              controller: _prompt,
              maxLines: 3,
              maxLength: 4000,
              decoration: InputDecoration(
                labelText: siteTranslate(context, '让模型控制 Live2D'),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const SiteText('流式导演'),
              subtitle: const SiteText('BEAT / VOICE / CONTROL'),
              value: _streaming,
              onChanged: d.loading
                  ? null
                  : (value) => setState(() => _streaming = value),
            ),
            FilledButton(
              key: const Key('live2d-perform'),
              onPressed: canAct && !d.loading
                  ? () => d.perform(_prompt.text, streaming: _streaming)
                  : null,
              child: SiteText(d.loading ? '正在思考…' : '执行 LLM 指令'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: d.loading ? d.stop : null,
                  child: const SiteText('停止请求'),
                ),
                TextButton(
                  onPressed: d.clearHistory,
                  child: const SiteText('清除导演历史'),
                ),
                TextButton(
                  onPressed: () => widget.onGo('/room/settings'),
                  child: const SiteText('模型与语音设置'),
                ),
              ],
            ),
            if (d.loading) const LinearProgressIndicator(),
            if (d.intent.isNotEmpty)
              ExpansionTile(
                title: const SiteText('ACT · 实际执行指令'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      const JsonEncoder.withIndent('  ').convert(d.intent),
                    ),
                  ),
                ],
              ),
            if (d.raw.isNotEmpty)
              ExpansionTile(
                title: const SiteText('模型原始输出'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(d.raw),
                  ),
                ],
              ),
          ],
        ),
      ),
      NativeSiteSection(
        title: '参数 JSON',
        subtitle: '支持 expressionMix、actions、parameters、sequence 和 interruptPolicy。未知参数不会写入模型。',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('live2d-json'),
              controller: _json,
              minLines: 5,
              maxLines: 14,
              decoration: InputDecoration(
                labelText: siteTranslate(context, 'Live2D JSON 指令'),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: canAct ? () => _applyJson() : null,
              child: const SiteText('应用 JSON'),
            ),
            if (_commandError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _commandError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ExpansionTile(
              title: const SiteText('可控 Cubism 参数'),
              children: [
                for (final item in jsonRows(
                  RoomReference.map('live2d')['parameterControls'],
                ))
                  ListTile(
                    title: Text('${item['id']}'),
                    subtitle: Text(
                      '${item['label']} · ${item['min']}…${item['max']}',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
  void _applyJson() {
    try {
      final value = jsonDecode(_json.text);
      d.animation.custom(value);
      setState(() => _commandError = '');
    } catch (e) {
      setState(() => _commandError = 'JSON 指令无效：$e');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([d, widget.controller.voice]),
    builder: (context, _) => NativeSiteShell(
      showChrome: false,
      controller: widget.controller,
      title: 'Live2D 工作台',
      onGo: widget.onGo,
      onTheme: widget.onTheme,
      child: LayoutBuilder(
        builder: (context, box) => box.maxWidth > 900
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 6, child: _stage()),
                  const SizedBox(width: 20),
                  Expanded(flex: 5, child: _controls()),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [_stage(), _controls()],
              ),
      ),
    ),
  );
}
