import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../room/room_controller.dart';

Future<void> showRoomSettings(
  BuildContext context,
  RoomController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => SettingsDialog(controller: controller),
);

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.controller});
  final RoomController controller;
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> fields;
  late bool demo, speak;
  bool saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    final s = widget.controller.settings;
    fields = {
      for (final e in {
        'site': s.siteUrl,
        'llm': s.llmUrl,
        'model': s.model,
        'key': s.apiKey,
        'tts': s.ttsUrl,
        'ttsKey': s.ttsKey,
        'ttsModel': s.ttsModel,
        'voice': s.voice,
      }.entries)
        e.key: TextEditingController(text: e.value),
    };
    demo = s.demo;
    speak = s.speak;
  }

  @override
  void dispose() {
    for (final f in fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  Widget field(
    String key,
    String label, {
    bool secret = false,
    bool url = false,
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      controller: fields[key],
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: !secret,
      decoration: InputDecoration(labelText: label, hintText: hint),
      validator: (value) {
        if (url &&
            (key == 'site' || key == 'llm' && !demo || key == 'tts' && speak)) {
          try {
            endpointUri(value ?? '');
          } catch (_) {
            return '请输入 HTTPS 地址，本机可使用 HTTP';
          }
        }
        if (key == 'model' && !demo && (value ?? '').trim().isEmpty) {
          return '请填写模型名称';
        }
        return null;
      },
    ),
  );
  Future<void> save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      String read(String key) => fields[key]!.text.trim();
      await widget.controller.configure(
        RoomSettings(
          siteUrl: read('site'),
          llmUrl: read('llm'),
          model: read('model'),
          apiKey: read('key'),
          ttsUrl: read('tts'),
          ttsKey: read('ttsKey'),
          ttsModel: read('ttsModel'),
          voice: read('voice'),
          demo: demo,
          speak: speak,
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => error = e is ApiFailure ? e.message : '保存失败，请检查系统安全存储');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '房间设置',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '关闭',
                  onPressed: saving ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('离线演示'),
                        subtitle: const Text('使用示例回复，不连接模型，也不上传会话。'),
                        value: demo,
                        onChanged: (v) => setState(() => demo = v),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        '模型连接',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 14),
                      field('llm', 'Chat Completions 完整地址', url: true),
                      field('model', '模型名称', hint: '例如你的 Ollama 模型名称'),
                      field('key', '模型 API Key（本机服务可留空）', secret: true),
                      const Text(
                        '支持兼容 Chat Completions 的 SSE 接口。手机的 localhost 指向手机自身。',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xffa7aec4),
                        ),
                      ),
                      const SizedBox(height: 24),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('语音回复'),
                        subtitle: const Text('兼容语音接口，使用 PCM WAV 分析口型。'),
                        value: speak,
                        onChanged: (v) => setState(() => speak = v),
                      ),
                      if (speak) ...[
                        field('tts', 'Speech 完整地址', url: true),
                        field('ttsModel', '语音模型'),
                        field('voice', '音色 ID'),
                        field('ttsKey', '语音 API Key', secret: true),
                      ],
                      const SizedBox(height: 24),
                      const Text(
                        '账号同步',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 14),
                      field('site', '月读空间服务地址', url: true),
                      const Text(
                        '保存设置后，点击房间右上角登录。已登录的真实对话会同步到该站点，并由现有后端捕获长期记忆。',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xffa7aec4),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'API Key 和会话凭据使用系统安全存储；对话缓存保存在当前设备。',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xffa7aec4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: saving ? null : save,
                icon: const Icon(Icons.check, size: 18),
                label: Text(saving ? '正在保存…' : '保存设置'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> showAccountDialog(
  BuildContext context,
  RoomController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => _AccountDialog(controller),
);

class _AccountDialog extends StatefulWidget {
  const _AccountDialog(this.controller);
  final RoomController controller;
  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  final username = TextEditingController(), password = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    username.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.controller.account == null || widget.controller.sessionExpired
          ? '登录月读空间'
          : '账号',
    ),
    content: SizedBox(
      width: 340,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.controller.settings.siteUrl,
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 20),
            if (widget.controller.account == null ||
                widget.controller.sessionExpired) ...[
              TextField(
                controller: username,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(labelText: '用户名或邮箱'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '密码'),
              ),
            ] else
              Text('已登录：${widget.controller.account!.username}'),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: busy
            ? null
            : () async {
                setState(() {
                  busy = true;
                  error = null;
                });
                try {
                  if (widget.controller.account == null ||
                      widget.controller.sessionExpired) {
                    await widget.controller.login(
                      username.text.trim(),
                      password.text,
                    );
                  } else {
                    await widget.controller.logout();
                  }
                  if (context.mounted) Navigator.pop(context);
                } catch (e) {
                  if (mounted) {
                    setState(
                      () =>
                          error = e is ApiFailure ? e.message : '登录失败，请检查网络和账号',
                    );
                  }
                } finally {
                  if (mounted) setState(() => busy = false);
                }
              },
        child: Text(
          busy
              ? '请稍候…'
              : widget.controller.account == null ||
                    widget.controller.sessionExpired
              ? '登录'
              : '退出登录',
        ),
      ),
    ],
  );
}
