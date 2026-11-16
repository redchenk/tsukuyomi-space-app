import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../../core/site_localization.dart';
import 'management_service.dart';
import 'official_service_admin.dart';
import 'site_widgets.dart';

class _TerminalLlm implements OfficialDataService {
  _TerminalLlm(this.api);
  final ManagementService api;
  @override
  Future<Map<String, dynamic>> officialRequest(
    String site,
    String method,
    String path, {
    String? account,
    Map<String, dynamic>? body,
  }) async {
    if (api.client is! SiteClient || account == null) {
      throw const ApiFailure('请重新登录管理终端');
    }
    final result = await (api.client as SiteClient).terminalOfficialRequest(
      site,
      method,
      path.split('/').last,
      account,
      body,
    );
    return Map<String, dynamic>.from(result['data'] as Map);
  }
}

class OfficialServicesManager extends StatefulWidget {
  const OfficialServicesManager({
    super.key,
    required this.api,
    required this.onGo,
  });
  final ManagementService api;
  final ValueChanged<String> onGo;
  @override
  State<OfficialServicesManager> createState() =>
      _OfficialServicesManagerState();
}

class _OfficialServicesManagerState extends State<OfficialServicesManager> {
  String tab = 'tts', engine = 'default', account = '', error = '', notice = '';
  Map<String, dynamic> config = {},
      primary = {},
      fish = {},
      health = {},
      usage = {};
  final secret = TextEditingController(),
      voice = TextEditingController(),
      end = TextEditingController();
  int days = 30, epoch = 0;
  bool busy = false;
  Map<String, dynamic> get draft => engine == 'default' ? primary : fish;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    epoch++;
    secret.dispose();
    voice.dispose();
    end.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function(int) action) async {
    if (busy) return;
    final current = ++epoch;
    setState(() {
      busy = true;
      error = '';
      notice = '';
    });
    try {
      await action(current);
    } catch (e) {
      if (mounted && current == epoch) {
        setState(() => error = e is ApiFailure ? e.message : '操作失败，请重新读取');
      }
    } finally {
      if (mounted && current == epoch) setState(() => busy = false);
    }
  }

  void apply(Map<String, dynamic> data) {
    config = data;
    primary = Map.from(data['primary']);
    fish = Map.from(data['fish']);
    fish['models'] = List<String>.from(fish['models']);
    voice.text = '${fish['voice']}';
    secret.clear();
    health = {};
  }

  Future<void> load() => run((current) async {
    final path = tab == 'llm'
        ? '/official-services/llm/me'
        : tab == 'tts'
        ? '/official-services/tts'
        : '/official-usage?days=$days${end.text.isEmpty ? '' : '&end=${Uri.encodeComponent(end.text)}'}';
    final data = Map<String, dynamic>.from(await widget.api.data('GET', path));
    if (!mounted || epoch != current) return;
    setState(() {
      if (tab == 'llm') {
        account = '${data['account']}';
      } else if (tab == 'tts') {
        apply(data);
      } else {
        usage = data;
        end.text = '${data['to']}';
      }
    });
  });
  Future<void> save() => run((current) async {
    final body = <String, dynamic>{
      'revision': config['revision'],
      'engine': engine,
      'enabled': draft['enabled'],
      'language': draft['language'],
      if (engine == 'fish-audio') ...{
        'voice': voice.text.trim(),
        'model': fish['model'],
        'models': fish['models'],
        if (secret.text.trim().isNotEmpty) 'apiKey': secret.text.trim(),
      },
    };
    final result = Map<String, dynamic>.from(
      await widget.api.data('PUT', '/official-services/tts', body),
    );
    if (!mounted || current != epoch) return;
    setState(() {
      apply(result);
      notice = '语音配置已保存，新朗读请求使用新设置。';
    });
  });
  Widget speech() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 8,
        children: [
          for (final value in ['default', 'fish-audio'])
            ChoiceChip(
              label: Text(
                value == 'default'
                    ? '${config['primary']?['protocol'] ?? '主音源'}'
                    : 'Fish Audio',
              ),
              selected: engine == value,
              onSelected: busy
                  ? null
                  : (_) => setState(() {
                      engine = value;
                      secret.clear();
                    }),
            ),
        ],
      ),
      if (config.isNotEmpty) ...[
        SwitchListTile(
          title: const SiteText('启用此音源'),
          value: draft['enabled'] == true,
          onChanged: busy ? null : (v) => setState(() => draft['enabled'] = v),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('$engine:${config['revision']}:language'),
          initialValue: '${draft['language']}',
          decoration: const InputDecoration(labelText: '朗读语言'),
          items: [
            for (final v in config['languages'] as List)
              DropdownMenuItem(value: '$v', child: Text('$v')),
          ],
          onChanged: busy ? null : (v) => setState(() => draft['language'] = v),
        ),
        if (engine == 'fish-audio') ...[
          TextField(
            controller: voice,
            enabled: !busy,
            maxLength: 32,
            decoration: const InputDecoration(labelText: '音色 ID'),
          ),
          DropdownButtonFormField<String>(
            key: ValueKey('${config['revision']}:${fish['model']}'),
            initialValue: '${fish['model']}',
            decoration: const InputDecoration(labelText: '默认模型'),
            items: [
              for (final v in config['availableModels'] as List)
                DropdownMenuItem(value: '$v', child: Text('$v')),
            ],
            onChanged: busy
                ? null
                : (v) => setState(() {
                    fish['model'] = v;
                    if (!(fish['models'] as List).contains(v)) {
                      (fish['models'] as List).add(v);
                    }
                  }),
          ),
          const SiteText('向普通用户开放的模型'),
          Wrap(
            spacing: 8,
            children: [
              for (final v in config['availableModels'] as List)
                FilterChip(
                  label: Text('$v'),
                  selected: (fish['models'] as List).contains(v),
                  onSelected: busy || fish['model'] == v
                      ? null
                      : (selected) => setState(() {
                          if (selected) {
                            (fish['models'] as List).add(v);
                          } else {
                            (fish['models'] as List).remove(v);
                          }
                        }),
                ),
            ],
          ),
          TextField(
            controller: secret,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: '更换 Fish 密钥',
              hintText: '留空保留现有密钥',
            ),
          ),
          SiteText(fish['hasKey'] == true ? '已配置密钥' : '尚未配置密钥'),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: busy ? null : save,
              child: const SiteText('保存音源设置'),
            ),
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => run((current) async {
                      final result = Map<String, dynamic>.from(
                        await widget.api.data(
                          'GET',
                          '/official-services/tts/status',
                        ),
                      );
                      if (mounted && current == epoch) {
                        setState(() => health = result);
                      }
                    }),
              child: const SiteText('检测音源'),
            ),
          ],
        ),
        if (health.isNotEmpty)
          Text(
            '主音源：${health['primary']?['online'] == true ? '在线' : '离线'} · Fish Audio：${health['fish']?['online'] == true ? '在线' : '离线'}',
          ),
      ],
    ],
  );
  Widget statistics() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SiteText('官方服务每日调用 · 北京时间（UTC+8）'),
      Wrap(
        spacing: 8,
        children: [
          for (final v in [7, 30, 90])
            ChoiceChip(
              label: Text('$v 天'),
              selected: days == v,
              onSelected: busy
                  ? null
                  : (_) {
                      setState(() => days = v);
                      load();
                    },
            ),
        ],
      ),
      TextField(
        controller: end,
        enabled: !busy,
        decoration: const InputDecoration(labelText: '截至日期 YYYY-MM-DD'),
        onSubmitted: (_) => load(),
      ),
      if (usage.isNotEmpty) ...[
        Text('${usage['from']} — ${usage['to']}'),
        for (final kind in ['llm', 'tts'])
          Text(
            '${kind.toUpperCase()} · 今日 ${usage['today']?[kind]?['total'] ?? 0} · 所选时段 ${usage['total']?[kind]?['total'] ?? 0} 次',
          ),
        for (final row in rowsOf(usage['rows']))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${row['date']}'),
            subtitle: Text(
              [
                for (final kind in ['llm', 'tts'])
                  '${kind.toUpperCase()} ${row[kind]['total']} · 完成 ${row[kind]['completed']} · 未完成 ${row[kind]['incomplete']} · 待确认 ${row[kind]['pending']}',
              ].join('\n'),
            ),
          ),
        const SiteText(
          '按服务已接纳的唯一请求计数，包含免扣费调用。重试与语音缓存回放不重复计数；自带 API 和接纳前被拒绝的请求不计入。',
        ),
      ],
    ],
  );
  @override
  Widget build(BuildContext context) => SiteCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final item in [
              ('llm', '语言模型'),
              ('tts', '语音合成'),
              ('usage', '调用统计'),
            ])
              ChoiceChip(
                label: SiteText(item.$2),
                selected: tab == item.$1,
                onSelected: busy
                    ? null
                    : (_) {
                        setState(() {
                          tab = item.$1;
                          secret.clear();
                        });
                        load();
                      },
              ),
          ],
        ),
        if (busy) const LinearProgressIndicator(),
        if (error.isNotEmpty)
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (notice.isNotEmpty) Text(notice),
        TextButton(
          onPressed: busy ? null : load,
          child: const SiteText('重新读取配置'),
        ),
        if (tab == 'tts') speech(),
        if (tab == 'usage') statistics(),
        if (tab == 'llm' && account.isNotEmpty)
          OfficialServiceAdmin(
            key: ValueKey(account),
            client: _TerminalLlm(widget.api),
            site: widget.api.site,
            account: account,
            onUpdated: () async {},
            onGo: widget.onGo,
          ),
      ],
    ),
  );
}
