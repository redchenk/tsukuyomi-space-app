import '../../core/site_localization.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../core/site_routes.dart';
import '../../core/llm_client.dart';
import '../../core/room_protocol.dart';
import '../../core/room_reference.dart';
import '../../core/room_archive.dart';
import '../../core/voice_service.dart';
import '../room/room_controller.dart';
import '../room/room_style.dart';
import '../room/room_navigation.dart';
import '../room/room_search.dart';
import '../room/room_diary_panel.dart';
import '../site/site_widgets.dart';
import '../site/site_navigation.dart';
import '../site/login_dialog.dart';
import 'room_memory_manager.dart';

const roomSections = <String, (String, IconData, String)>{
  'llm': ('聊天模型', CupertinoIcons.chat_bubble, '基础与陪伴'),
  'tts': ('语音与朗读', CupertinoIcons.waveform, '基础与陪伴'),
  'memory': ('长期记忆', CupertinoIcons.bookmark, '基础与陪伴'),
  'knowledge': ('角色知识库', CupertinoIcons.book, '基础与陪伴'),
  'model': ('角色与布局', CupertinoIcons.layers, '房间个性化'),
  'diary': ('日记与存档', CupertinoIcons.doc_text, '房间个性化'),
  'mcp': ('工具与扩展', CupertinoIcons.square_grid_2x2, '进阶功能'),
  'debug': (
    'Live2D 调试',
    CupertinoIcons.chevron_left_slash_chevron_right,
    '进阶功能',
  ),
};

class RoomSettingsPage extends StatefulWidget {
  const RoomSettingsPage({
    super.key,
    required this.controller,
    this.initialSection = 'llm',
    this.onTheme,
  });
  final RoomController controller;
  final VoidCallback? onTheme;
  final String initialSection;
  @override
  State<RoomSettingsPage> createState() => _RoomSettingsPageState();
}

class _RoomSettingsPageState extends State<RoomSettingsPage> {
  RoomController get c => widget.controller;
  final fields = <String, TextEditingController>{};
  final scroll = ScrollController();
  final debugInput = TextEditingController(
    text: '{"expression":"smile","motion":"nod","durationMs":3000}',
  );
  late Map<String, dynamic> options;
  late String section;
  bool demo = false,
      speak = false,
      busy = false,
      guide = true,
      showKey = false,
      mobileMenu = false,
      allowPop = false;
  String search = '', notice = '', testStatus = '尚未测试连接', savedSnapshot = '';
  List<Map<String, dynamic>> catalog = [], tools = [];
  String expression = 'smile', motion = '';
  double duration = 5000;
  LlmClient? testing;
  AudioVoice? testVoice;
  @override
  void initState() {
    super.initState();
    section = widget.initialSection;
    _restore();
    c.addListener(_controllerChanged);
  }

  Future<void> _go(String path) async {
    if (busy) return;
    final target = resolveSiteTarget(c.settings.siteUrl, path);
    if (target.nativePath != null &&
        Uri.parse(target.nativePath!).path == '/room') {
      await _leave(returnToRoom: true);
      return;
    }
    // A later Room shortcut can remove this settings route from the stack.
    // Resolve unsaved edits before navigating to another native page.
    if (target.nativePath != null && dirty) {
      if (!await _confirmLeave() || !mounted) return;
      setState(_restore);
    }
    if (mounted) await navigateSite(context, c, path);
  }

  void _controllerChanged() {
    if (mounted) setState(() {});
  }

  void _restore() {
    final s = c.settings;
    options = jsonMap(jsonDecode(jsonEncode(s.options)));
    demo = s.demo;
    speak = s.speak;
    final values = {
      'siteUrl': s.siteUrl,
      'llmUrl': s.llmUrl,
      'model': s.model,
      'apiKey': s.apiKey,
      'ttsUrl': s.ttsUrl,
      'ttsKey': s.ttsKey,
      'ttsModel': s.ttsModel,
      'voice': s.voice,
      'ttsFormat': s.ttsFormat,
      'mcpKey': s.mcpKey,
    };
    for (final key in [
      'systemPrompt',
      'refAudioPath',
      'promptText',
      'gptWeightPath',
      'sovitsWeightPath',
      'mcpEndpoint',
      'mcpAuthHeader',
      'mcpApiHost',
      'mcpBasePath',
      'mcpAllowlist',
    ]) {
      values[key] = s.option(
        key,
        key == 'mcpAuthHeader'
            ? 'Authorization'
            : key == 'mcpApiHost'
            ? 'https://api.minimaxi.chat'
            : '',
      );
    }
    for (final item in values.entries) {
      fields.putIfAbsent(item.key, () => TextEditingController()).text =
          item.value;
    }
    if (!options.containsKey('knowledge')) {
      options['knowledge'] = RoomReference.rows('knowledge');
    }
    savedSnapshot = _snapshot();
  }

  String _snapshot() => jsonEncode({
    ..._value().toJson(),
    'apiKey': fields['apiKey']!.text,
    'ttsKey': fields['ttsKey']!.text,
    'mcpKey': fields['mcpKey']!.text,
  });
  bool get dirty => _snapshot() != savedSnapshot;
  RoomSettings _value() {
    final o = {...options};
    for (final k in [
      'systemPrompt',
      'refAudioPath',
      'promptText',
      'gptWeightPath',
      'sovitsWeightPath',
      'mcpEndpoint',
      'mcpAuthHeader',
      'mcpApiHost',
      'mcpBasePath',
      'mcpAllowlist',
    ]) {
      o[k] = fields[k]!.text.trim();
    }
    return c.settings.copyWith(
      siteUrl: fields['siteUrl']!.text.trim(),
      llmUrl: fields['llmUrl']!.text.trim(),
      model: fields['model']!.text.trim(),
      apiKey: fields['apiKey']!.text.trim(),
      ttsUrl: fields['ttsUrl']!.text.trim(),
      ttsKey: fields['ttsKey']!.text.trim(),
      ttsModel: fields['ttsModel']!.text.trim(),
      voice: fields['voice']!.text.trim(),
      ttsFormat: fields['ttsFormat']!.text,
      demo: demo,
      speak: speak,
      options: o,
      mcpKey: fields['mcpKey']!.text.trim(),
    );
  }

  Future<void> _run(Future<void> Function() task) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await task();
    } catch (e) {
      if (mounted) {
        setState(
          () => notice = e is ApiFailure
              ? e.message
              : e is FormatException
              ? e.message
              : '操作失败，请检查配置与网络后重试',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _save() async {
    try {
      final s = _value();
      endpointUri(s.siteUrl);
      if (!s.demo) {
        roomChatEndpoint(s.llmUrl);
        if (s.model.isEmpty) throw const ApiFailure('请填写聊天模型');
      }
      if (s.speak) {
        endpointUri(s.ttsUrl);
        if (s.option('ttsProvider') == 'gpt-sovits' &&
            s.option('refAudioPath').isEmpty &&
            s.voice.isEmpty) {
          throw const ApiFailure('请填写 GPT-SoVITS 参考音频路径');
        }
      }
      if (s.flag('mcpEnabled') &&
          s.option('mcpEndpoint') != '/api/mcp/token-plan') {
        endpointUri(s.option('mcpEndpoint'));
      }
      await c.configure(s);
      if (mounted) {
        setState(() {
          savedSnapshot = _snapshot();
          notice = '所有修改已保存';
        });
      }
      return true;
    } catch (e) {
      if (mounted) {
        setState(
          () => notice = e is ApiFailure
              ? e.message
              : e is FormatException
              ? e.message
              : '设置保存失败，修改仍保留在表单中',
        );
      }
      return false;
    }
  }

  Future<bool> _confirmLeave() async {
    if (dirty) {
      final result = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const SiteText('设置尚未保存'),
          content: const SiteText('离开会丢失尚未保存的修改。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const SiteText('继续编辑'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const SiteText('放弃并离开'),
            ),
          ],
        ),
      );
      if (result != true) return false;
    }
    return true;
  }

  Future<void> _leave({bool returnToRoom = false}) async {
    if (busy || !await _confirmLeave()) return;
    if (mounted) {
      setState(() => allowPop = true);
      if (returnToRoom) {
        Navigator.popUntil(context, (route) => route.isFirst);
      } else {
        Navigator.pop(context);
      }
    }
  }

  void _select(String id) {
    setState(() {
      section = id;
      mobileMenu = false;
      notice = '';
    });
    if (scroll.hasClients) {
      scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    c.removeListener(_controllerChanged);
    testing?.cancel();
    testVoice?.dispose();
    for (final f in fields.values) {
      f.dispose();
    }
    scroll.dispose();
    debugInput.dispose();
    super.dispose();
  }

  Widget _field(
    String key,
    String label, {
    int lines = 1,
    bool secret = false,
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: TextField(
      key: Key('setting-$key'),
      controller: fields[key],
      enabled: !busy,
      obscureText: secret && !showKey,
      maxLines: secret ? 1 : lines,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: secret
            ? IconButton(
                tooltip: showKey ? '隐藏密钥' : '显示密钥',
                onPressed: () => setState(() => showKey = !showKey),
                icon: Icon(
                  showKey ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                ),
              )
            : null,
      ),
    ),
  );
  Widget _toggle(
    String key,
    String title, {
    bool fallback = false,
    String? detail,
  }) => SwitchListTile.adaptive(
    contentPadding: EdgeInsets.zero,
    value: options[key] as bool? ?? fallback,
    title: Text(title),
    subtitle: detail == null
        ? null
        : Text(detail, style: const TextStyle(fontSize: 12)),
    onChanged: busy ? null : (v) => setState(() => options[key] = v),
  );
  Widget _selectOption(
    String key,
    String label,
    Map<String, String> values, {
    String fallback = '',
  }) {
    final value = '${options[key] ?? fallback}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: DropdownButtonFormField<String>(
        key: ValueKey('$key:$value'),
        initialValue: values.containsKey(value) ? value : values.keys.first,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: values.entries
            .map(
              (e) => DropdownMenuItem(
                value: e.key,
                child: Text(e.value, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
        onChanged: busy ? null : (v) => setState(() => options[key] = v),
      ),
    );
  }

  Widget _button(
    String label,
    Future<void> Function() task, {
    bool primary = false,
  }) => primary
      ? FilledButton(
          onPressed: busy ? null : () => _run(task),
          child: Text(label),
        )
      : OutlinedButton(
          onPressed: busy ? null : () => _run(task),
          child: Text(label),
        );
  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        height: 1.7,
        color: RoomStyle(context).muted,
      ),
    ),
  );
  void _preset(Map<String, dynamic> preset, {bool tts = false}) {
    setState(() {
      if (tts) {
        speak = true;
        options['ttsProvider'] = preset['provider'];
        for (final pair in {
          'apiUrl': 'ttsUrl',
          'model': 'ttsModel',
          'voice': 'voice',
          'refAudioPath': 'refAudioPath',
          'gptWeightPath': 'gptWeightPath',
          'sovitsWeightPath': 'sovitsWeightPath',
        }.entries) {
          if (preset[pair.key] != null) {
            fields[pair.value]!.text = '${preset[pair.key]}';
          }
        }
        for (final key in ['textLang', 'promptLang']) {
          if (preset[key] != null) options[key] = preset[key];
        }
        options['ttsProxy'] = preset['useProxy'] == true;
      } else {
        demo = false;
        fields['llmUrl']!.text = '${preset['apiUrl']}';
        fields['model']!.text = '${preset['model']}';
        options['llmProxy'] = preset['useProxy'] == true;
        testStatus = '尚未测试连接';
      }
    });
  }

  Future<void> _testLlm() async {
    final s = _value().copyWith(demo: false);
    final client = LlmClient()..siteCookie = c.site.cookie;
    testing = client;
    setState(() => testStatus = '正在测试连接');
    try {
      final text = await client
          .reply(s, [], '请只回复：连接成功')
          .join()
          .timeout(const Duration(seconds: 60));
      if (mounted) {
        setState(() {
          testStatus = '连接测试通过';
          notice = '模型回复：${text.substring(0, text.length.clamp(0, 300))}';
        });
      }
    } catch (_) {
      if (mounted) setState(() => testStatus = '连接测试失败');
      rethrow;
    } finally {
      client.cancel();
      testing = null;
    }
  }

  Future<void> _catalog() async {
    final r = await c.workspace.request('GET', '/api/room/models/openrouter');
    catalog = jsonRows(r['data'] is List ? r['data'] : r['data']?['models']);
    if (mounted) {
      setState(() => notice = '已同步 ${catalog.length} 个模型，可选择或输入服务商的模型名');
    }
  }

  Widget _llm() {
    final local = fields['llmUrl']!.text.contains('11434');
    final presets = {
      ...RoomReference.map('llmPresets'),
      for (final e in RoomReference.map('aliyunPresets').entries)
        'aliyun:${e.key}': e.value,
      for (final e in RoomReference.map('mimoPresets').entries)
        'mimo:${e.key}': e.value,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _mode(
                '云端 API',
                '无需安装 · 使用服务商密钥',
                CupertinoIcons.cloud,
                !local,
                () => _preset(jsonMap(presets['openaiChat'])),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _mode(
                '本机 Ollama',
                '已安装本机模型 · 无需密钥',
                CupertinoIcons.layers,
                local,
                () => _preset(jsonMap(presets['ollama'])),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const SiteText('服务商', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, box) {
            final controls = <Widget>[
              for (final entry in {
                'deepseek': 'DeepSeek',
                'openaiChat': 'OpenAI',
                'aliyun:${RoomReference.map('aliyunPresets').keys.first}':
                    '阿里云百炼',
              }.entries)
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => _preset(jsonMap(presets[entry.key])),
                  child: Text(
                    entry.value,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              DropdownButtonFormField<String>(
                isExpanded: true,
                decoration: InputDecoration(
                  hintText: siteTranslate(context, '更多服务商'),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
                items: presets.entries
                    .map(
                      (e) => DropdownMenuItem(
                        value: e.key,
                        child: Text(
                          '${e.value['label']}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: busy ? null : (v) => _preset(jsonMap(presets[v])),
              ),
            ];
            final columns = box.maxWidth > 580 ? 4 : 2;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: controls
                  .map(
                    (w) => SizedBox(
                      width: (box.maxWidth - 8 * (columns - 1)) / columns,
                      height: 44,
                      child: w,
                    ),
                  )
                  .toList(),
            );
          },
        ),
        const SizedBox(height: 24),
        _field('apiKey', 'API 密钥', secret: true),
        _hint('密钥保存在系统安全存储，调用时发送给所选服务。'),
        Row(
          children: [
            const Expanded(
              child: SiteText(
                '模型',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              onPressed: busy ? null : () => _run(_catalog),
              icon: const Icon(CupertinoIcons.refresh, size: 15),
              label: const SiteText('刷新模型'),
            ),
          ],
        ),
        _field('model', '模型 Model'),
        if (catalog.isNotEmpty)
          DropdownButtonFormField<String>(
            isExpanded: true,
            decoration: InputDecoration(
              labelText: siteTranslate(context, '同步模型目录'),
            ),
            items: catalog
                .where(
                  (v) => '${v['id']}'.toLowerCase().contains(
                    fields['model']!.text.toLowerCase(),
                  ),
                )
                .take(80)
                .map(
                  (v) => DropdownMenuItem(
                    value: '${v['id']}',
                    child: Text('${v['id']}', overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => fields['model']!.text = v ?? ''),
          ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const SiteText('高级连接设置'),
          subtitle: const SiteText(
            'API 端点 · 图片理解 · 代理 · 补充指令',
            style: TextStyle(fontSize: 11),
          ),
          children: [
            _field('llmUrl', 'API 端点'),
            _selectOption('visionMode', '图片理解', {
              'auto': '自动（模型 / MCP）',
              'model': '仅模型视觉',
              'mcp': '仅 MCP 图片理解',
            }, fallback: 'auto'),
            _toggle(
              'llmProxy',
              '通过网站代理请求',
              detail: '开启后，服务地址与 Key 会发送到当前站点，由网站转发。',
            ),
            _field('systemPrompt', '补充聊天指令', lines: 5),
            _hint('聊天固定使用八千代的基础身份；日记人设只用于日记生成。'),
            _field('siteUrl', '月读空间站点'),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const SiteText('离线演示'),
              value: demo,
              onChanged: (v) => setState(() => demo = v),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(testStatus, style: const TextStyle(fontSize: 12)),
            _button('测试连接', _testLlm, primary: true),
          ],
        ),
      ],
    );
  }

  Widget _mode(
    String title,
    String detail,
    IconData icon,
    bool selected,
    VoidCallback onTap,
  ) => Material(
    color: selected ? RoomStyle(context).soft : RoomStyle(context).surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(
        color: selected ? RoomStyle(context).accent : RoomStyle(context).line,
      ),
    ),
    child: InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, box) {
            final label = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: selected ? RoomStyle(context).accent : null,
                  ),
                ),
                const SizedBox(height: 5),
                Text(detail, style: const TextStyle(fontSize: 11, height: 1.5)),
              ],
            );
            final radio = Icon(
              selected
                  ? CupertinoIcons.largecircle_fill_circle
                  : CupertinoIcons.circle,
              size: 18,
              color: RoomStyle(context).accent,
            );
            return box.maxWidth > 190
                ? SizedBox(
                    height: 68,
                    child: Row(
                      children: [
                        Icon(icon, color: RoomStyle(context).accent),
                        const SizedBox(width: 14),
                        Expanded(child: label),
                        radio,
                      ],
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(icon, color: RoomStyle(context).accent),
                          const Spacer(),
                          radio,
                        ],
                      ),
                      const SizedBox(height: 12),
                      label,
                    ],
                  );
          },
        ),
      ),
    ),
  );
  Widget _tts() {
    final provider = '${options['ttsProvider'] ?? 'openai-compatible'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const SiteText('开启语音回复'),
          subtitle: const SiteText('让八千代把回复读给你听。'),
          value: speak,
          onChanged: (v) => setState(() => speak = v),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in RoomReference.map('ttsPresets').entries)
              ActionChip(
                label: Text('${e.value['label']}'),
                onPressed: () => _preset(jsonMap(e.value), tts: true),
              ),
          ],
        ),
        const SizedBox(height: 24),
        _selectOption('ttsProvider', '语音服务', {
          'mimo': 'MiMo',
          'openai': 'OpenAI',
          'openai-compatible': 'OpenAI 兼容',
          'minimax': 'MiniMax',
          'elevenlabs': 'ElevenLabs',
          'gpt-sovits': 'GPT-SoVITS',
          'custom': '自定义',
        }, fallback: 'openai-compatible'),
        if (provider != 'gpt-sovits')
          _field('ttsKey', '语音 API Key', secret: true),
        _field('voice', provider == 'gpt-sovits' ? '默认参考音频（可选）' : '音色 ID'),
        _field('ttsUrl', 'TTS API 地址'),
        _field('ttsModel', '语音模型'),
        _selectOption('textLang', '文本语言', {
          'auto': '自动',
          'zh': '中文',
          'ja': '日语',
          'en': '英语',
          'yue': '粤语',
          'ko': '韩语',
        }, fallback: 'auto'),
        if (provider == 'gpt-sovits') ...[
          const SiteText('本机 GPT-SoVITS 直接连接；公网地址通过网站代理，需要登录。'),
          const SizedBox(height: 10),
          _field('refAudioPath', '参考音频在服务端的路径'),
          _field('promptText', '参考音频文本', lines: 3),
          _selectOption('promptLang', '参考语言', {
            'ja': '日语',
            'zh': '中文',
            'en': '英语',
            'yue': '粤语',
            'ko': '韩语',
            'auto': '自动',
          }, fallback: 'ja'),
          _field('gptWeightPath', 'GPT 权重路径'),
          _field('sovitsWeightPath', 'SoVITS 权重路径'),
        ] else
          _toggle('ttsProxy', '通过网站代理生成语音'),
        DropdownButtonFormField<String>(
          initialValue: fields['ttsFormat']!.text,
          decoration: InputDecoration(
            labelText: siteTranslate(context, 'OpenAI 兼容音频格式'),
          ),
          items: const [
            DropdownMenuItem(value: 'wav', child: SiteText('WAV · 支持音量口型')),
            DropdownMenuItem(value: 'mp3', child: SiteText('MP3')),
          ],
          onChanged: (v) => setState(() => fields['ttsFormat']!.text = v!),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          children: [
            _button('语音试听', () async {
              testVoice ??= AudioVoice();
              testVoice!.siteCookie = c.site.cookie;
              await testVoice!.speak(_value(), '你好，我是八千代。今天也一起慢慢聊吧。');
              if (mounted) setState(() => notice = '试听已开始');
            }, primary: true),
            OutlinedButton(
              onPressed: () async {
                await testVoice?.stop();
              },
              child: const SiteText('停止试听'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _slider(
    String key,
    String title,
    double min,
    double max,
    double fallback,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$title  ${(options[key] as num? ?? fallback).round()}'),
      Slider(
        value: (options[key] as num? ?? fallback).toDouble().clamp(min, max),
        min: min,
        max: max,
        onChanged: (v) => setState(() => options[key] = v),
      ),
    ],
  );
  Widget _model() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _slider('modelScale', '角色大小（%）', 60, 160, 100),
      _slider('modelX', '水平位置', -240, 240, 0),
      _slider('modelY', '垂直位置', -180, 180, 0),
      _button('恢复默认角色布局', () async {
        setState(() {
          options.addAll({'modelScale': 100, 'modelX': 0, 'modelY': 0});
        });
      }),
      const SizedBox(height: 16),
      _button('重置浮窗布局', () async {
        setState(() => options['panelLayout'] = {});
        notice = '浮窗位置已重置，保存后生效';
      }),
    ],
  );
  Future<void> _saveKnowledge() async {
    final value = c.settings.copyWith(
      options: {...c.settings.options, 'knowledge': options['knowledge']},
    );
    await c.storage.saveSettings(value);
    c.settings = value;
    final saved = jsonMap(jsonDecode(savedSnapshot));
    saved['options'] = {
      ...jsonMap(saved['options']),
      'knowledge': options['knowledge'],
    };
    savedSnapshot = jsonEncode(saved);
    c.workspace.changed();
  }

  Future<void> _editKnowledge([Map<String, dynamic>? entry]) async {
    final result = await showRoomRecordEditor(
      context,
      title: entry == null ? '添加知识' : '编辑知识',
      value: {
        'title': '',
        'content': '',
        'tags': '',
        'enabled': true,
        ...?entry,
      },
      knowledge: true,
    );
    if (result == null) return;
    final id = entry?['id'] ?? newTurnId();
    setState(
      () => options['knowledge'] = [
        ...jsonRows(options['knowledge']).where((v) => v['id'] != id),
        {...result, 'id': id},
      ],
    );
    await _saveKnowledge();
  }

  Widget _knowledge() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _toggle('knowledgeEnabled', '启用角色知识库', fallback: true),
      _hint('按对话相关性注入角色资料。知识库保存在此设备，条目单独保存立即生效。'),
      Wrap(
        spacing: 10,
        children: [
          _button('添加条目', () => _editKnowledge(), primary: true),
          _button('恢复默认知识', () async {
            if (await roomConfirm(context, '恢复网站默认知识库？', '当前知识条目将被默认条目替换。')) {
              setState(
                () => options['knowledge'] = RoomReference.rows('knowledge'),
              );
              await _saveKnowledge();
            }
          }),
        ],
      ),
      const SizedBox(height: 18),
      for (final item in jsonRows(options['knowledge']))
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SiteCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${item['title']}'),
                  value: item['enabled'] != false,
                  onChanged: busy
                      ? null
                      : (v) => _run(() async {
                          setState(
                            () => options['knowledge'] =
                                jsonRows(options['knowledge'])
                                    .map(
                                      (e) => e['id'] == item['id']
                                          ? {...e, 'enabled': v}
                                          : e,
                                    )
                                    .toList(),
                          );
                          await _saveKnowledge();
                        }),
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    '${item['tags']}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  children: [SelectableText('${item['content']}')],
                ),
                Wrap(
                  spacing: 10,
                  children: [
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => _run(() => _editKnowledge(item)),
                      child: const SiteText('编辑'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => _run(() async {
                              if (await roomConfirm(
                                context,
                                '删除知识条目？',
                                '删除后立即生效。',
                              )) {
                                setState(
                                  () => options['knowledge'] =
                                      jsonRows(options['knowledge'])
                                          .where((v) => v['id'] != item['id'])
                                          .toList(),
                                );
                                await _saveKnowledge();
                              }
                            }),
                      child: const SiteText('删除'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
    ],
  );
  Widget _mcp() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _toggle('mcpEnabled', '启用 MCP 工具'),
      _selectOption('mcpProvider', '工具服务', {
        'custom': '自定义',
        'minimax-global': 'MiniMax Global',
        'minimax-mainland': 'MiniMax Mainland',
        'minimax-token-plan': 'MiniMax Token Plan',
      }, fallback: 'custom'),
      _button('应用所选预设', () async {
        final type = options['mcpProvider'];
        setState(() {
          options['mcpEnabled'] = true;
          fields['mcpAuthHeader']!.text = 'Authorization';
          if (type == 'minimax-token-plan') {
            fields['mcpEndpoint']!.text = '/api/mcp/token-plan';
            fields['mcpApiHost']!.text = 'https://api.minimaxi.com';
            fields['mcpAllowlist']!.text = 'web_search,understand_image';
          } else {
            fields['mcpApiHost']!.text = type == 'minimax-mainland'
                ? 'https://api.minimax.chat'
                : 'https://api.minimaxi.chat';
            fields['mcpAllowlist']!.text = 'text_to_audio,list_voices,voice_clone,voice_design,music_generation,generate_video,image_to_video,query_video_generation,text_to_image';
          }
        });
      }),
      const SizedBox(height: 18),
      _field('mcpEndpoint', 'MCP REST 端点'),
      _field('mcpKey', 'MCP API Key', secret: true),
      _field('mcpAuthHeader', '鉴权 Header'),
      _field('mcpApiHost', 'API Host'),
      _field('mcpBasePath', 'Base Path'),
      _selectOption('mcpResourceMode', '资源模式', {
        'url': 'URL',
        'local': 'Local',
      }, fallback: 'url'),
      _field('mcpAllowlist', '工具白名单（逗号分隔）'),
      _hint('支持 JSON-RPC tools/list 与 tools/call。搜索和图片理解会按白名单调用；工具结果仅作为参考资料。'),
      _button('测试并发现工具', () async {
        final r = await c.workspace.tools.call(
          _value(),
          'tools/list',
          cookie: c.site.cookie,
        );
        tools = jsonRows(r['tools']);
        if (mounted) setState(() => notice = '发现 ${tools.length} 个工具');
      }, primary: true),
      const SizedBox(height: 12),
      for (final t in tools)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${t['name']}'),
          subtitle: Text('${t['description'] ?? ''}'),
        ),
    ],
  );
  Widget _debug() => AnimatedBuilder(
    animation: c.animation,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _hint('测试指令加入队列，返回房间后由原生 Live2D 播放。'),
        TextField(
          controller: debugInput,
          decoration: InputDecoration(
            labelText: siteTranslate(context, '自定义 Live2D JSON'),
          ),
          minLines: 3,
          maxLines: 8,
        ),
        _button('执行 JSON 指令', () async {
          c.animation.custom(jsonDecode(debugInput.text));
        }),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: expression,
          isExpanded: true,
          decoration: InputDecoration(labelText: siteTranslate(context, '表情')),
          items: jsonRows(RoomReference.map('live2d')['expressions'])
              .map(
                (v) => DropdownMenuItem(
                  value: '${v['id']}',
                  child: Text(
                    '${v['label']} / ${v['id']}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: (v) => setState(() => expression = v!),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: motion,
          isExpanded: true,
          decoration: InputDecoration(labelText: siteTranslate(context, '动作')),
          items: [
            const DropdownMenuItem(value: '', child: SiteText('不触发动作')),
            ...jsonRows(RoomReference.map('live2d')['motions']).map(
              (v) => DropdownMenuItem(
                value: '${v['id']}',
                child: Text('${v['label']}', overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
          onChanged: (v) => setState(() => motion = v!),
        ),
        Text('恢复时间 ${duration.round()} ms'),
        Slider(
          value: duration,
          min: 800,
          max: 12000,
          onChanged: (v) => setState(() => duration = v),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _button('测试当前组合', () async {
              c.animation.enqueue({
                'expression': expression,
                'motion': motion,
                'durationMs': duration,
              });
            }),
            for (final e in {
              '问候': 'smile',
              '害羞': 'bsmile',
              '落泪': 'tears',
            }.entries)
              _button('${e.key}队列', () async {
                c.animation.enqueue({
                  'expression': e.value,
                  'motion': 'nod',
                  'durationMs': 3000,
                });
                c.animation.enqueue({
                  'expression': 'neutral',
                  'motion': 'sway',
                  'durationMs': 2000,
                });
              }),
            _button('清空队列', () async {
              c.animation.clear();
            }),
            _button('复制调试 JSON', () async {
              await Clipboard.setData(
                ClipboardData(
                  text: const JsonEncoder.withIndent('  ')
                      .convert(c.animation.debug),
                ),
              );
              notice = '已复制调试状态';
            }),
          ],
        ),
        const SizedBox(height: 20),
        SelectableText(
          const JsonEncoder.withIndent('  ').convert(c.animation.debug),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
      ],
    ),
  );
  Widget _content() => switch (section) {
    'llm' => _llm(),
    'tts' => _tts(),
    'memory' => Column(
      children: [
        _toggle('memoryEnabled', '启用长期记忆', fallback: true),
        RoomMemoryManager(key: ValueKey(c.scope), controller: c),
      ],
    ),
    'knowledge' => _knowledge(),
    'model' => _model(),
    'diary' => RoomDiaryPanel(
      key: ValueKey(c.scope),
      controller: c,
      settingsMode: true,
    ),
    'mcp' => _mcp(),
    _ => _debug(),
  };
  Widget _nav() => SiteCard(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          decoration: InputDecoration(
            hintText: siteTranslate(context, '搜索设置'),
            prefixIcon: Icon(CupertinoIcons.search, size: 16),
            isDense: true,
          ),
          onChanged: (v) => setState(() => search = v),
        ),
        const SizedBox(height: 14),
        for (final group in ['基础与陪伴', '房间个性化', '进阶功能']) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
            child: Text(group, style: const TextStyle(fontSize: 11)),
          ),
          for (final e in roomSections.entries.where(
            (e) =>
                e.value.$3 == group &&
                ('${e.value.$1} ${e.key}').toLowerCase().contains(
                  search.toLowerCase(),
                ),
          ))
            ListTile(
              dense: true,
              selected: e.key == section,
              selectedTileColor: RoomStyle(context).soft,
              shape: const StadiumBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              leading: Icon(e.value.$2, size: 18),
              title: Text(e.value.$1, style: const TextStyle(fontSize: 12)),
              onTap: () => _select(e.key),
            ),
        ],
        TextButton(
          onPressed: () => setState(() => guide = true),
          child: const SiteText('查看配置指引'),
        ),
      ],
    ),
  );
  Widget _summary() => Column(
    children: [
      SiteCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SiteText(
              '当前房间',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 20),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(CupertinoIcons.chat_bubble, size: 20),
              title: const SiteText('聊天模型', style: TextStyle(fontSize: 12)),
              subtitle: Text(
                c.settings.model.isEmpty ? '待配置' : c.settings.model,
                style: const TextStyle(fontSize: 11),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(CupertinoIcons.waveform, size: 20),
              title: const SiteText('语音朗读', style: TextStyle(fontSize: 12)),
              subtitle: Text(
                c.settings.speak ? c.settings.voice : '先用文字，也很好',
                style: const TextStyle(fontSize: 11),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(CupertinoIcons.bookmark, size: 20),
              title: const SiteText('长期记忆', style: TextStyle(fontSize: 12)),
              subtitle: Text(
                c.workspace.usesLocalMemory ? '本机记忆' : '账号私有记忆',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      SiteCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SiteText(
              'A LITTLE REMINDER',
              style: TextStyle(fontSize: 10, letterSpacing: 1.5),
            ),
            const SizedBox(height: 18),
            const SiteText(
              '先聊起来，\n再慢慢变成你的房间。',
              style: TextStyle(
                fontSize: 22,
                fontFamily: RoomStyle.serif,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 15),
            _hint('大部分选项保持默认就好，之后随时可以回来调整。'),
          ],
        ),
      ),
      const SizedBox(height: 22),
      SiteCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SiteText('数据存在哪里？'),
            const SizedBox(height: 15),
            _hint('密钥保存在系统安全存储；接口与知识库保存在此设备。记忆、日记和日记人设在登录后使用网站账号数据。'),
          ],
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final p = RoomStyle(context), current = roomSections[section]!;
    return PopScope(
      canPop: allowPop || !dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset('assets/images/moonlit-lake.png', fit: BoxFit.cover),
            ColoredBox(color: p.surface.withValues(alpha: .80)),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, box) {
                  final mobile = box.maxWidth <= 860;
                  return Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          controller: scroll,
                          padding: EdgeInsets.fromLTRB(
                            mobile ? 14 : 32,
                            mobile ? 12 : 16,
                            mobile ? 14 : 32,
                            40,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                height: mobile ? 60 : 68,
                                child: RoomNavigation(
                                  title: '房间设置',
                                  mobile: mobile,
                                  width: box.maxWidth,
                                  accountLabel: c.sessionExpired
                                      ? '重新登录'
                                      : c.account?.displayName ?? '登录',
                                  onAccount: () => showSiteLogin(context, c),
                                  onSearch: () =>
                                      showRoomSearch(context, c, _go),
                                  onSettings: () {},
                                  onTheme: widget.onTheme,
                                  onGo: _go,
                                ),
                              ),
                              SizedBox(height: mobile ? 26 : 38),
                              const SiteText(
                                '私人居所  ›  房间设置',
                                style: TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  const Expanded(
                                    child: SiteText(
                                      '房间设置',
                                      style: TextStyle(
                                        fontSize: 28,
                                        height: 1.2,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => _leave(returnToRoom: true),
                                    style: TextButton.styleFrom(
                                      minimumSize: const Size(0, 40),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 8,
                                      ),
                                      backgroundColor: p.glass,
                                      shape: const StadiumBorder(),
                                    ),
                                    icon: const Icon(
                                      CupertinoIcons.arrow_left,
                                      size: 16,
                                    ),
                                    label: const SiteText('返回房间'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _hint('先连接聊天模型，其他功能可以稍后设置。'),
                              RoomMemorySourcePanel(controller: c),
                              if (guide)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: 8,
                                    bottom: 26,
                                  ),
                                  child: SiteCard(
                                    padding: EdgeInsets.all(mobile ? 18 : 22),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(
                                            color: p.soft,
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                          child: Icon(
                                            CupertinoIcons.sparkles,
                                            color: p.accent,
                                            size: 22,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const SiteText(
                                                '只需连接一个模型，就能开始聊天',
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const SizedBox(height: 7),
                                              SiteText(
                                                '语音、记忆和外观按需调整，不必一次填完所有设置。',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  height: 1.7,
                                                  color: p.muted,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (!mobile)
                                          const Padding(
                                            padding: EdgeInsets.all(12),
                                            child: SiteText(
                                              '① 选择服务    ② 填写密钥    ③ 测试连接',
                                              style: TextStyle(fontSize: 11),
                                            ),
                                          ),
                                        IconButton(
                                          constraints: const BoxConstraints(
                                            minWidth: 24,
                                            minHeight: 24,
                                          ),
                                          padding: EdgeInsets.zero,
                                          tooltip: siteTranslate(
                                            context,
                                            '收起配置提示',
                                          ),
                                          onPressed: () =>
                                              setState(() => guide = false),
                                          icon: const Icon(
                                            CupertinoIcons.xmark,
                                            size: 16,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              if (mobile) ...[
                                SiteCard(
                                  padding: EdgeInsets.zero,
                                  child: ListTile(
                                    dense: true,
                                    minTileHeight: 50,
                                    leading: Icon(current.$2, size: 20),
                                    title: Text(
                                      current.$1,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                    trailing: const SiteText(
                                      '全部设置 ﹀',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                    onTap: () => setState(
                                      () => mobileMenu = !mobileMenu,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                if (mobileMenu)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 20),
                                    child: _nav(),
                                  ),
                              ],
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (!mobile) ...[
                                    SizedBox(width: 204, child: _nav()),
                                    const SizedBox(width: 24),
                                  ],
                                  Expanded(
                                    child: SiteCard(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: mobile ? 18 : 28,
                                        vertical: mobile ? 22 : 28,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.all(
                                                  12,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: p.soft,
                                                  borderRadius:
                                                      BorderRadius.circular(14),
                                                ),
                                                child: Icon(
                                                  current.$2,
                                                  color: p.accent,
                                                  size: 23,
                                                ),
                                              ),
                                              const SizedBox(width: 14),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      current.$1,
                                                      style: const TextStyle(
                                                        fontSize: 22,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 8),
                                                    Text(
                                                      section == 'llm'
                                                          ? '连接一个模型，让八千代开始回应你。'
                                                          : section == 'debug'
                                                          ? '排查表情、动作与队列。'
                                                          : '把相处的细节，调整成你喜欢的样子。',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        height: 1.7,
                                                        color: p.muted,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                          const Padding(
                                            padding: EdgeInsets.symmetric(
                                              vertical: 24,
                                            ),
                                            child: Divider(height: 1),
                                          ),
                                          if (busy)
                                            const LinearProgressIndicator(),
                                          if (notice.isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 18,
                                              ),
                                              child: SelectableText(
                                                notice,
                                                style: TextStyle(
                                                  color: p.accent,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                          _content(),
                                          const SizedBox(height: 30),
                                          Center(
                                            child: SiteText(
                                              'TSUKUYOMI SPACE · ROOM SETTINGS',
                                              style: TextStyle(
                                                fontSize: 9,
                                                letterSpacing: 1.5,
                                                color: p.muted,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (box.maxWidth > 1180) ...[
                                    const SizedBox(width: 24),
                                    SizedBox(width: 252, child: _summary()),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: p.surface,
                          border: Border(top: BorderSide(color: p.line)),
                        ),
                        padding: EdgeInsets.symmetric(
                          horizontal: mobile ? 14 : 32,
                          vertical: 14,
                        ),
                        child: Row(
                          children: [
                            if (!mobile)
                              Expanded(
                                child: Text(
                                  dirty ? '有尚未保存的修改' : '所有修改已保存',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: p.muted,
                                  ),
                                ),
                              ),
                            if (mobile && !dirty)
                              Expanded(
                                child: SiteText(
                                  '所有修改已保存',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: p.muted,
                                  ),
                                ),
                              ),
                            TextButton(
                              onPressed: !dirty || busy
                                  ? null
                                  : () async {
                                      if (await roomConfirm(
                                        context,
                                        '放弃尚未保存的修改？',
                                        '已保存的记忆、日记与人设不会撤销。',
                                      )) {
                                        setState(_restore);
                                      }
                                    },
                              child: const SiteText('放弃修改'),
                            ),
                            if (mobile && dirty) const Spacer(),
                            if (dirty)
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => _run(() async {
                                        await _save();
                                      }),
                                child: const SiteText('保存全部'),
                              ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              onPressed: busy
                                  ? null
                                  : () => _run(() async {
                                      if (await _save() && context.mounted) {
                                        setState(() => allowPop = true);
                                        Navigator.popUntil(
                                          context,
                                          (route) => route.isFirst,
                                        );
                                      }
                                    }),
                              icon: const Icon(
                                CupertinoIcons.arrow_right,
                                size: 17,
                              ),
                              label: Text(dirty ? '保存并进入房间' : '返回房间'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
