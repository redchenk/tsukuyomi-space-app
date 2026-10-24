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
import '../../core/room_tools.dart';
import '../../core/room_reference.dart';
import '../../core/room_knowledge.dart';
import '../../core/model_runtime.dart';
import '../../core/model_catalog.dart';
import '../../core/official_api.dart';
import '../../core/official_tts.dart';
import '../../core/site_client.dart';
import 'model_runtime_panel.dart';
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
import 'official_tts_panel.dart';

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
    this.guidedSetup = false,
    this.onTheme,
  });
  final RoomController controller;
  final VoidCallback? onTheme;
  final String initialSection;
  final bool guidedSetup;
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
  late bool guided;
  int setupStep = 1;
  String testedSnapshot = '';
  String get connectionStatus =>
      testedSnapshot.isNotEmpty && testedSnapshot != _snapshot()
      ? '尚未测试连接'
      : testStatus;
  String search = '', notice = '', testStatus = '尚未测试连接', savedSnapshot = '';
  List<Map<String, dynamic>> catalog = [], tools = [];
  String expression = 'smile', motion = '';
  double duration = 5000;
  final ModelCatalog _modelCatalog = ModelCatalog();
  String _catalogOwner = '';
  LlmClient? testing;
  AudioVoice? testVoice;
  Map<String, dynamic> _officialTtsStatus = {};
  String _voiceOwner = '';
  @override
  void initState() {
    super.initState();
    guided = widget.guidedSetup;
    section = guided ? 'llm' : widget.initialSection;
    _restore();
    _catalogOwner = c.scope;
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
    final owner = '${c.account?.id}|${c.site.cookie}|${c.sessionExpired}';
    if (_voiceOwner != owner) {
      _voiceOwner = owner;
      unawaited(testVoice?.stop());
    }
    if (_catalogOwner != c.scope) {
      _catalogOwner = c.scope;
      _modelCatalog.cancel();
      catalog = [];
    }
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
      'aliyunWorkspaceId',
      'anthropicWorkspaceId',
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
    options['knowledge'] = roomKnowledgeEntries(s);
    options['knowledgeBuiltinVersion'] = RoomReference.data['knowledgeVersion'];
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
      'aliyunWorkspaceId',
      'anthropicWorkspaceId',
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
      var s = _value();
      if (!s.demo) ModelRuntime(s).resolveParameters();
      endpointUri(s.siteUrl);
      if (!s.demo) {
        roomChatEndpoint(s.llmUrl);
        if (s.model.isEmpty) throw const ApiFailure('请填写聊天模型');
      }
      if (s.option('ttsProvider') == 'official') {
        if (s.speak &&
            (c.account == null ||
                !c.sessionVerified ||
                c.sessionExpired ||
                c.account!.scope == 'admin')) {
          throw const ApiFailure('请登录后使用官方语音');
        }
        final account = c.account, cookie = c.site.cookie;
        if (account != null && s.speak) {
          final verified = await c.site.me(s.siteUrl);
          if (verified.id != account.id ||
              c.account?.id != account.id ||
              c.site.cookie != cookie) {
            throw const ApiFailure('账号已变化，请重新保存官方语音设置');
          }
        }
        s = s.copyWith(
          options: {
            ...s.options,
            'officialTtsAccount': account?.id ?? '',
            'officialTtsOrigin': endpointUri(s.siteUrl).origin,
            'textLang': '${_officialTtsStatus['language'] ?? 'ja'}',
          },
        );
      } else if (s.speak) {
        endpointUri(s.ttsUrl);
        if (s.option('ttsProvider') == 'gpt-sovits' &&
            s.option('refAudioPath').isEmpty &&
            s.voice.isEmpty) {
          throw const ApiFailure('请填写 GPT-SoVITS 参考音频路径');
        }
      }
      if (s.flag('mcpEnabled') &&
          s.option('mcpEndpoint') != '/api/mcp/token-plan') {
        roomMcpEndpoint(s);
      }
      // Saving voice settings must not activate a stored paid chat endpoint
      // while the user has explicitly kept chat in demo mode.
      final effective = !s.demo && s.usesOfficialApi
          ? await _verifiedOfficial(s)
          : s;
      await c.configure(effective);
      if (effective.usesOfficialApi ||
          effective.option('ttsProvider') == 'official') {
        options = {...effective.options};
      }
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
    _modelCatalog.close();
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
      onChanged: (_) {
        if ([
          'llmUrl',
          'apiKey',
          'aliyunWorkspaceId',
          'anthropicWorkspaceId',
        ].contains(key)) {
          _modelCatalog.cancel();
          catalog = [];
        }
        if (key == 'model' && _value().usesOfficialApi) {
          _applyOfficialModel();
        }
        setState(() {});
      },
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
    bool numeric = false,
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
        onChanged: busy
            ? null
            : (v) => setState(
                () => options[key] = numeric ? int.tryParse(v ?? '') : v,
              ),
      ),
    );
  }

  Widget _button(
    String label,
    Future<void> Function() task, {
    bool primary = false,
    bool enabled = true,
  }) => primary
      ? FilledButton(
          onPressed: busy || !enabled ? null : () => _run(task),
          child: Text(label),
        )
      : OutlinedButton(
          onPressed: busy || !enabled ? null : () => _run(task),
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
        catalog = [];
        demo = false;
        options.remove('llmConnection');
        options.remove('officialProvider');
        if (Uri.tryParse(fields['llmUrl']!.text)?.host !=
            Uri.tryParse('${preset['apiUrl']}')?.host) {
          fields['apiKey']!.clear();
        }
        fields['llmUrl']!.text = '${preset['apiUrl']}';
        fields['model']!.text = '${preset['model']}';
        options['llmProxy'] = preset['useProxy'] == true;
        testStatus = '尚未测试连接';
      }
    });
  }

  Future<void> _testLlm() async {
    final s = _value().copyWith(demo: false);
    final client = LlmClient()
      ..siteCookie = c.site.cookie
      ..siteAccountId = c.account?.id;
    testing = client;
    testedSnapshot = _snapshot();
    setState(() => testStatus = '正在测试连接');
    try {
      final text = await client
          .reply(s, [], '请只回复：连接成功')
          .join()
          .timeout(const Duration(seconds: 60));
      if (mounted) {
        setState(() {
          testStatus = text.trim().isEmpty ? '已响应，未返回文本' : '连接测试通过';
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
    final settings = _value(), owner = c.scope;
    if (settings.usesOfficialApi) {
      await _connectOfficial();
      return;
    }
    catalogPlan(settings); // Validate before any credential relay.
    final rows = <Map<String, dynamic>>[];
    if (settings.flag('llmProxy')) {
      var cursor = '';
      final cursors = <String>{};
      for (var page = 0; page < 8; page++) {
        final result = jsonMap(
          (await c.workspace.request('POST', '/api/room/models/list', {
            'apiUrl': settings.llmUrl,
            'apiKey': settings.apiKey,
            'workspaceId': catalogWorkspaceId(settings),
            'cursor': cursor,
          }))['data'],
        );
        if (!mounted || owner != c.scope) return;
        rows.addAll(jsonRows(result['models']));
        if (rows.length > 2000) throw const ApiFailure('模型列表数量超过限制');
        cursor = '${result['nextCursor'] ?? ''}';
        if (cursor.isEmpty) break;
        if (!cursors.add(cursor) || page == 7) {
          throw const ApiFailure('模型列表分页超过限制');
        }
      }
    } else {
      rows.addAll(await _modelCatalog.load(settings, refresh: true));
    }
    if (!mounted ||
        owner != c.scope ||
        settings.llmUrl != fields['llmUrl']!.text.trim() ||
        settings.apiKey != fields['apiKey']!.text.trim()) {
      return;
    }
    final runtime = ModelRuntime(settings);
    final config = normalizeModelRuntime(options['runtimeConfig']);
    final declarations = config['declarations'] as Map;
    for (final item in rows) {
      if (declarations.length >= 64) break;
      declarations['${runtime.providerKey}#${item['id']}'] =
          item['capabilities'] ?? {};
    }
    setState(() {
      catalog = rows;
      options['runtimeConfig'] = config;
      notice = '已同步 ${catalog.length} 个模型，可选择或输入服务商的模型名';
    });
  }

  Future<Map<String, dynamic>> _officialDashboard() async {
    // Demo controls chat generation, independently of the authenticated account.
    if (c.account == null || !c.sessionVerified || c.sessionExpired) {
      throw const ApiFailure('请先登录月读空间，再使用站内直供');
    }
    if (c.site is! OfficialDataService) throw const ApiFailure('站内直供接口暂不可用');
    final user = c.account!.id,
        cookie = c.site.cookie,
        site = c.settings.siteUrl;
    if (endpointUri(_value().siteUrl).origin != endpointUri(site).origin) {
      throw const ApiFailure('请先保存站点地址并重新登录，再选择站内直供');
    }
    final data = await (c.site as OfficialDataService).officialRequest(
      site,
      'GET',
      '/api/dashboard',
    );
    if (!mounted ||
        c.account?.id != user ||
        c.site.cookie != cookie ||
        c.settings.siteUrl != site ||
        c.sessionExpired) {
      throw const ApiFailure('账号已切换，请刷新后重试');
    }
    return officialDashboard(data, user);
  }

  Future<RoomSettings> _verifiedOfficial(RoomSettings settings) async =>
      officialRoomSettings(settings, await _officialDashboard());

  Future<void> _connectOfficial() async {
    if (c.account == null || c.sessionExpired || !c.sessionVerified) {
      await showSiteLogin(context, c);
      if (!mounted) return;
    }
    final data = await _officialDashboard();
    final models = (data['models'] as List)
        .whereType<Map>()
        .where(
          (row) =>
              row['enabled'] == true &&
              row['id'] is String &&
              row['max_output_tokens'] is int &&
              row['max_output_tokens'] >= 16,
        )
        .toList();
    if (models.isEmpty || data['enabled'] != true) {
      throw const ApiFailure('站内直供暂未开放，请稍后再试');
    }
    final model = models.any((row) => row['id'] == fields['model']!.text)
        ? fields['model']!.text
        : '${models.first['id']}';
    final next = officialRoomSettings(_value().copyWith(model: model), data);
    if (!mounted) return;
    setState(() {
      fields['llmUrl']!.text = next.llmUrl;
      fields['model']!.text = next.model;
      fields['apiKey']!.clear();
      demo = false;
      options = {...next.options};
      catalog = models.map((row) => <String, dynamic>{...row}).toList();
      notice = '使用当前登录账号，无需填写 API 密钥。保存后生效。';
    });
  }

  Map<String, dynamic>? get _selectedOfficialModel {
    for (final row in catalog) {
      if (row['id'] == fields['model']!.text.trim()) return row;
    }
    return null;
  }

  void _applyOfficialModel() {
    if (_selectedOfficialModel == null) return;
    final next = officialRoomSettings(_value(), {
      'enabled': true,
      'models': catalog,
    });
    options = {...next.options};
  }

  Widget _officialLlm() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _mode(
        '站内直供',
        '账号直接使用 · 统一余额计费',
        CupertinoIcons.moon,
        true,
        () => _run(_connectOfficial),
      ),
      const SizedBox(height: 16),
      const SiteText('使用当前月读空间账号和网站余额，无需填写供应商密钥。'),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          OutlinedButton(
            onPressed: busy ? null : () => _run(_connectOfficial),
            child: const SiteText('刷新直供模型'),
          ),
          OutlinedButton(
            onPressed: busy ? null : () => _go('/payments'),
            child: const SiteText('余额、充值与订单'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      _field('model', '模型 Model'),
      if (catalog.isNotEmpty)
        DropdownButtonFormField<String>(
          key: ValueKey('official-model-${fields['model']!.text}'),
          initialValue: _selectedOfficialModel?['id'] as String?,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '可用直供模型'),
          items: [
            for (final row in catalog)
              DropdownMenuItem(
                value: '${row['id']}',
                child: Text(
                  '${row['id']} · ${officialModelSupportsImages(row) ? '文字与图片' : '文字'}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: busy
              ? null
              : (value) => setState(() {
                  fields['model']!.text = value ?? '';
                  _applyOfficialModel();
                }),
        ),
      _hint('按公布的最终 Token 用量结算；余额不足时可到支付中心充值。'),
      _hint(
        _selectedOfficialModel == null
            ? '刷新直供模型后可查看图片能力。支持图片的模型可在聊天中直接发送图片。'
            : officialModelSupportsImages(_selectedOfficialModel!)
            ? '支持文字、图片与工具调用。图片会自动压缩，图片与文字按实际 Token 用量统一计费。'
            : '当前模型支持文字聊天和工具调用；发送图片请切换支持图片的模型，或选择 MCP 图片理解。',
      ),
      _selectOption('visionMode', '图片理解', {
        'auto': '自动（模型 / MCP）',
        'model': '仅模型视觉',
        'mcp': '仅 MCP 图片理解',
      }, fallback: 'auto'),
      _field('systemPrompt', '补充聊天指令', lines: 5),
      ModelRuntimePanel(
        settings: _value(),
        onChanged: (value) => setState(() => options['runtimeConfig'] = value),
      ),
      if (!guided)
        OutlinedButton(
          onPressed: busy ? null : () => _run(_testLlm),
          child: const SiteText('测试模型连接'),
        ),
      SiteText(connectionStatus),
      const SizedBox(height: 20),
      Wrap(
        spacing: 12,
        children: [
          TextButton(
            onPressed: busy
                ? null
                : () => _preset(
                    jsonMap(RoomReference.map('llmPresets')['openaiChat']),
                  ),
            child: const SiteText('切换云端 API'),
          ),
          TextButton(
            onPressed: busy
                ? null
                : () => _preset(
                    jsonMap(RoomReference.map('llmPresets')['ollama']),
                  ),
            child: const SiteText('切换本机 Ollama'),
          ),
        ],
      ),
    ],
  );

  bool get setupReady {
    final s = _value();
    try {
      roomChatEndpoint(s.llmUrl);
      final host = Uri.parse(s.llmUrl).host;
      final local = [
        'localhost',
        '127.0.0.1',
        '::1',
        '[::1]',
        '10.0.2.2',
      ].contains(host);
      return s.model.trim().isNotEmpty &&
          (s.usesOfficialApi || local || s.apiKey.trim().isNotEmpty);
    } catch (_) {
      return false;
    }
  }

  void _setupStep(int value) {
    setState(() {
      setupStep = value;
      notice = '';
    });
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  Widget _guidedLlm() {
    if (setupStep == 2) return _llm();
    if (setupStep == 3) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            siteTranslate(
              context,
              '当前模型：{model}',
            ).replaceAll('{model}', fields['model']!.text),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          const SiteText(
            '测试会调用所选服务，可能产生用量。通过后保存，回到房间发一句话，收到回复后就能继续聊了。也可以跳过测试。',
            style: TextStyle(height: 1.7),
          ),
          const SizedBox(height: 16),
          SiteText(connectionStatus, key: const Key('setup-connection-status')),
          if (connectionStatus == '连接测试失败')
            const SiteText('请查看上方失败原因，可以回到上一步修改；填写的内容会保留。'),
          _button('测试连接', _testLlm, primary: true),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SiteText(
          '选择适合你的聊天服务',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        _mode(
          '站内直供',
          '需要登录账号与可用额度，无需服务商密钥',
          CupertinoIcons.moon,
          _value().usesOfficialApi,
          () => _run(() async {
            await _connectOfficial();
            if (mounted && _value().usesOfficialApi) _setupStep(2);
          }),
        ),
        const SizedBox(height: 12),
        _mode('云端 API', '已有服务商账号与密钥，连接自己的服务', CupertinoIcons.cloud, false, () {
          _preset(jsonMap(RoomReference.map('llmPresets')['deepseek']));
          _setupStep(2);
        }),
        const SizedBox(height: 12),
        _mode('本机 Ollama', '已安装并启动本机模型，无需密钥', CupertinoIcons.layers, false, () {
          _preset(jsonMap(RoomReference.map('llmPresets')['ollama']));
          _setupStep(2);
        }),
        if (fields['model']!.text.trim().isNotEmpty)
          TextButton(
            onPressed: () => _setupStep(2),
            child: const SiteText('继续使用当前连接'),
          ),
      ],
    );
  }

  Widget _setupFooter() => Wrap(
    alignment: WrapAlignment.end,
    spacing: 8,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(
        siteTranslate(
          context,
          '第 {step} / 3 步',
        ).replaceAll('{step}', '$setupStep'),
      ),
      if (setupStep > 1)
        TextButton(
          onPressed: busy ? null : () => _setupStep(setupStep - 1),
          child: const SiteText('上一步'),
        ),
      if (setupStep == 2)
        FilledButton(
          onPressed: busy || !setupReady ? null : () => _setupStep(3),
          child: const SiteText('下一步'),
        ),
      if (setupStep == 3)
        FilledButton(
          onPressed: busy || !setupReady
              ? null
              : () => _run(() async {
                  if (await _save() && mounted) {
                    setState(() => allowPop = true);
                    Navigator.popUntil(context, (route) => route.isFirst);
                  }
                }),
          child: SiteText(
            connectionStatus == '连接测试通过' ? '保存，去说第一句话' : '跳过测试并保存',
          ),
        ),
    ],
  );

  Widget _llm() {
    if (_value().usesOfficialApi) return _officialLlm();
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
        _mode(
          '站内直供',
          '账号直接使用 · 统一余额计费',
          CupertinoIcons.moon,
          false,
          () => _run(_connectOfficial),
        ),
        const SizedBox(height: 12),
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
                      height:
                          44 *
                          (MediaQuery.textScalerOf(context).scale(14) / 14),
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
        Wrap(
          spacing: 14,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const SiteText('模型', style: TextStyle(fontWeight: FontWeight.w600)),
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
            onChanged: (v) => setState(() {
              fields['model']!.text = v ?? '';
              final runtime = ModelRuntime(_value());
              final config = normalizeModelRuntime(options['runtimeConfig']);
              final declarations = config['declarations'] as Map;
              if (!declarations.containsKey(runtime.modelKey) &&
                  declarations.length >= 64) {
                declarations.remove(declarations.keys.first);
              }
              declarations[runtime.modelKey] =
                  catalog.firstWhere((row) => row['id'] == v)['capabilities'] ??
                  {};
              options['runtimeConfig'] = config;
            }),
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
            if (catalogProvider(fields['llmUrl']!.text.trim()) == 'anthropic')
              _field(
                'anthropicWorkspaceId',
                'Anthropic 工作区 ID（可选，密钥未绑定工作区时填写）',
                hint: 'wrkspc_…',
              )
            else
              _field('aliyunWorkspaceId', '百炼工作空间 ID'),
            _field('siteUrl', '月读空间站点'),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const SiteText('离线演示'),
              value: demo,
              onChanged: (v) => setState(() => demo = v),
            ),
          ],
        ),
        Builder(
          builder: (context) {
            try {
              final current = _value();
              ModelRuntime(current).resolveParameters();
              return ModelRuntimePanel(
                settings: current,
                onChanged: (value) =>
                    setState(() => options['runtimeConfig'] = value),
              );
            } catch (_) {
              return const SiteText(
                '填写有效的 API 端点后可设置模型参数',
                style: TextStyle(fontSize: 12),
              );
            }
          },
        ),
        const SizedBox(height: 16),
        if (!guided)
          Wrap(
            spacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SiteText(connectionStatus, style: const TextStyle(fontSize: 12)),
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
                    height:
                        68 * (MediaQuery.textScalerOf(context).scale(14) / 14),
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
    final official = provider == 'official';
    final loggedIn =
        c.account != null &&
        c.account!.scope != 'admin' &&
        c.sessionVerified &&
        !c.sessionExpired;
    final ready = _officialTtsStatus['online'] == true;
    var price = '0.05';
    try {
      price = moneyAtoms(_officialTtsStatus['priceAtoms'] ?? '50000000');
    } catch (_) {
      // Keep the published price hint if readiness data is incomplete.
    }
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
        OfficialTtsPanel(
          controller: c,
          onStatus: (status) {
            if (mounted) setState(() => _officialTtsStatus = status);
          },
          onPayments: () => unawaited(_go('/payments')),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ActionChip(
              key: const ValueKey('official-tts-preset'),
              label: const Text('官方直供 · 八千代语音'),
              onPressed: !loggedIn || !ready || busy
                  ? null
                  : () => setState(() {
                      options['ttsProvider'] = 'official';
                      speak = true;
                    }),
            ),
            for (final e in RoomReference.map('ttsPresets').entries)
              if (e.value['provider'] != 'official')
                ActionChip(
                  label: Text('${e.value['label']}'),
                  onPressed: () => _preset(jsonMap(e.value), tts: true),
                ),
          ],
        ),
        const SizedBox(height: 24),
        _selectOption('ttsProvider', '语音服务', {
          'official': '官方直供 · 八千代语音',
          'mimo': 'MiMo',
          'openai': 'OpenAI',
          'openai-compatible': 'OpenAI 兼容',
          'minimax': 'MiniMax',
          'elevenlabs': 'ElevenLabs',
          'gpt-sovits': 'GPT-SoVITS',
          'custom': '自定义',
        }, fallback: 'openai-compatible'),
        if (official) ...[
          _hint('官方音色采用日语朗读。中文回复会先通过当前聊天模型翻译，翻译按该模型的规则计费；固定日文试听不发起翻译。'),
          if (!loggedIn)
            TextButton(
              onPressed: () => showSiteLogin(context, c),
              child: const SiteText('登录月读空间'),
            ),
          _hint('无需填写供应商地址、模型、API Key 或权重。仅保存设置不会合成或扣费。'),
        ] else ...[
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
        ],
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          children: [
            if (official)
              _button('仅保存设置', () async {
                await _save();
              }),
            _button(
              official ? '保存并试听 · ¥$price' : '语音试听',
              () async {
                if (official && !await _save()) return;
                testVoice ??= AudioVoice();
                testVoice!
                  ..siteCookie = c.site.cookie
                  ..siteAccountId = c.account?.id
                  ..siteService = c.site;
                await testVoice!.speak(
                  _value(),
                  official ? officialTtsPreview : '你好，我是八千代。今天也一起慢慢聊吧。',
                );
                if (mounted) setState(() => notice = '试听已开始');
              },
              primary: true,
              enabled: !official || (loggedIn && ready && speak),
            ),
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
      _selectOption('live2dRenderer', siteTr(context, 'nativeLive2dRenderer'), {
        'auto': siteTr(context, 'nativeLive2dRendererAuto'),
        'canvas': siteTr(context, 'nativeLive2dRendererCanvas'),
      }, fallback: 'auto'),
      _selectOption(
        'live2dRenderQuality',
        siteTr(context, 'nativeLive2dQuality'),
        {
          'auto': siteTr(context, 'nativeLive2dQualityAuto'),
          'economy': siteTr(context, 'nativeLive2dQualityEconomy'),
          'full': siteTr(context, 'nativeLive2dQualityFull'),
        },
        fallback: 'auto',
      ),
      _selectOption(
        'live2dFrameRate',
        siteTr(context, 'nativeLive2dFrameRate'),
        {
          '0': siteTr(context, 'nativeLive2dFrameAuto'),
          '30': '30 fps',
          '60': '60 fps',
        },
        fallback: '0',
        numeric: true,
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Text(
          siteTr(context, 'nativeLive2dPerformanceHint'),
          style: const TextStyle(fontSize: 12),
        ),
      ),
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
      options: {
        ...c.settings.options,
        'knowledge': options['knowledge'],
        'knowledgeBuiltinVersion': RoomReference.data['knowledgeVersion'],
      },
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
          options['mcpTransport'] = 'rest';
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
      _field('mcpEndpoint', siteTr(context, 'nativeMcpEndpoint')),
      _selectOption('mcpTransport', siteTr(context, 'nativeMcpTransport'), {
        'rest': siteTr(context, 'nativeMcpRest'),
        'streamable-http': 'Streamable HTTP',
      }, fallback: 'rest'),
      _field('mcpKey', 'MCP API Key', secret: true),
      _field('mcpAuthHeader', '鉴权 Header'),
      _field('mcpApiHost', 'API Host'),
      _field('mcpBasePath', 'Base Path'),
      _selectOption('mcpResourceMode', '资源模式', {
        'url': 'URL',
        'local': 'Local',
      }, fallback: 'url'),
      _field('mcpAllowlist', '工具白名单（逗号分隔）'),
      _hint(siteTr(context, 'nativeMcpHint')),
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
    'llm' => guided ? _guidedLlm() : _llm(),
    'tts' => _tts(),
    'memory' => Column(
      children: [
        _toggle('memoryEnabled', '启用长期记忆', fallback: true),
        _hint('每轮检索数量（1–30），多条记忆共享 3000 字上下文预算。'),
        Slider(
          min: 1,
          max: 30,
          divisions: 29,
          value: memoryRetrievalLimit(_value()).toDouble(),
          label: '${memoryRetrievalLimit(_value())}',
          onChanged: (value) =>
              setState(() => options['memoryRetrievalLimit'] = value.round()),
        ),
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
            const Positioned.fill(
              child: SiteBackground(child: SizedBox.shrink()),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, box) {
                  final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                  final mobile = box.maxWidth <= 860 * scale;
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
                                height: (mobile ? 60 : 68) * scale,
                                child: RoomNavigation(
                                  title: '房间设置',
                                  mobile: mobile,
                                  width: box.maxWidth,
                                  accountLabel: c.sessionExpired
                                      ? '重新登录'
                                      : c.account?.displayName ?? '登录',
                                  onAccount: () {
                                    if (c.account != null &&
                                        !c.sessionExpired) {
                                      unawaited(_go('/user'));
                                    } else {
                                      unawaited(showSiteLogin(context, c));
                                    }
                                  },
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
                              Wrap(
                                spacing: 16,
                                runSpacing: 12,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  const SiteText(
                                    '房间设置',
                                    style: TextStyle(
                                      fontSize: 28,
                                      height: 1.2,
                                      fontWeight: FontWeight.w600,
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
                              if (guided)
                                SiteCard(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const SiteText(
                                        '第一次聊天，跟着这三步就好',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        siteTranslate(
                                              context,
                                              '第 {step} / 3 步 · {label}',
                                            )
                                            .replaceAll('{step}', '$setupStep')
                                            .replaceAll(
                                              '{label}',
                                              siteTranslate(
                                                context,
                                                [
                                                  '选择服务',
                                                  '填写连接信息',
                                                  '测试并保存',
                                                ][setupStep - 1],
                                              ),
                                            ),
                                      ),
                                      const SiteText(
                                        '语音、记忆和外观可以稍后设置。',
                                        style: TextStyle(height: 1.7),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            setState(() => guided = false),
                                        child: const SiteText('查看全部设置'),
                                      ),
                                    ],
                                  ),
                                ),
                              if (guide && !guided)
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
                              if (mobile && !guided) ...[
                                SiteCard(
                                  padding: EdgeInsets.zero,
                                  child: InkWell(
                                    onTap: () => setState(
                                      () => mobileMenu = !mobileMenu,
                                    ),
                                    borderRadius: BorderRadius.circular(20),
                                    child: Padding(
                                      padding: const EdgeInsets.all(14),
                                      child: Wrap(
                                        spacing: 12,
                                        runSpacing: 8,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Icon(current.$2, size: 20),
                                          Text(
                                            current.$1,
                                            style: const TextStyle(
                                              fontSize: 13,
                                            ),
                                          ),
                                          const SiteText(
                                            '全部设置 ﹀',
                                            style: TextStyle(fontSize: 12),
                                          ),
                                        ],
                                      ),
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
                                  if (!mobile && !guided) ...[
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
                                  if (!mobile &&
                                      !guided &&
                                      box.maxWidth > 1180 * scale) ...[
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
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SiteText(
                              dirty ? '有尚未保存的修改' : '所有修改已保存',
                              style: TextStyle(fontSize: 12, color: p.muted),
                            ),
                            const SizedBox(height: 8),
                            if (guided)
                              _setupFooter()
                            else
                              Wrap(
                                alignment: WrapAlignment.end,
                                spacing: 8,
                                runSpacing: 8,
                                children: [
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
                                  if (dirty)
                                    TextButton(
                                      onPressed: busy
                                          ? null
                                          : () => _run(() async {
                                              await _save();
                                            }),
                                      child: const SiteText('保存全部'),
                                    ),
                                  FilledButton.icon(
                                    onPressed: busy
                                        ? null
                                        : () => _run(() async {
                                            if (await _save() &&
                                                context.mounted) {
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
                                    label: SiteText(dirty ? '保存并进入房间' : '返回房间'),
                                  ),
                                ],
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
