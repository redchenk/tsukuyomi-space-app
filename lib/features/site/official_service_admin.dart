import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/official_api.dart';
import '../../core/site_client.dart';
import 'native_site_shell.dart';

/// Uses the plugin's operator permission, independently of main-site roles.
class OfficialServiceAdmin extends StatefulWidget {
  const OfficialServiceAdmin({
    super.key,
    required this.client,
    required this.site,
    required this.account,
    required this.onUpdated,
    required this.onGo,
  });
  final OfficialDataService client;
  final String site, account;
  final Future<void> Function() onUpdated;
  final ValueChanged<String> onGo;
  @override
  State<OfficialServiceAdmin> createState() => _OfficialServiceAdminState();
}

class _OfficialServiceAdminState extends State<OfficialServiceAdmin> {
  Map<String, dynamic> _settings = {}, _draft = {};
  List<Map<String, dynamic>> _reviews = [];
  final _fields = <String, TextEditingController>{};
  final _proofs = <String, TextEditingController>{};
  final _key = TextEditingController();
  bool _busy = false, _replace = false, _remove = false;
  String _error = '', _notice = '';
  int _epoch = 0;
  static const _limits = {
    'maxInputTokens': ('输入 Token 上限', 4096, 262144),
    'maxOutputTokens': ('输出 Token 上限', 16, 16384),
    'perUserConcurrent': ('每人并发数', 1, 4),
    'requestsPerMinute': ('每分钟请求数', 1, 60),
  };
  static const _rates = {
    'input_uncached': '未缓存输入',
    'input_cached': '缓存输入',
    'output': '输出',
  };
  Future<Map<String, dynamic>> _api(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) => widget.client.officialRequest(
    widget.site,
    method,
    '/api/admin/$path',
    account: widget.account,
    body: body,
  );
  void _apply(Map<String, dynamic> data) {
    _settings = data;
    _draft = {...data};
    for (final name in ['model', ..._limits.keys, ..._rates.keys]) {
      final value = _rates.containsKey(name)
          ? moneyAtoms((data['rates'] as Map)[name])
          : '${data[name]}';
      _fields.putIfAbsent(name, TextEditingController.new).text = value;
    }
    final apps = Map<String, dynamic>.from(data['deepseekApps'] as Map? ?? {});
    _draft['deepseekApps'] = apps;
    for (final entry in {
      'markupNumerator': '11',
      'markupDenominator': '10',
      'reservationAtoms': '1000000000',
      'input_uncached': '2200000000',
      'input_cached': '44000000',
      'output': '8800000000',
    }.entries) {
      final value = _rates.containsKey(entry.key)
          ? (apps['tokenRates'] as Map? ?? {})[entry.key] ?? entry.value
          : apps[entry.key] ?? entry.value;
      _fields
          .putIfAbsent('deepseek:${entry.key}', TextEditingController.new)
          .text = entry.key.startsWith('markup')
          ? '$value'
          : moneyAtoms(value);
    }
    _key.clear();
    _replace = false;
    _remove = false;
  }

  Future<void> _run(Future<void> Function(int) action) async {
    if (_busy) return;
    final epoch = ++_epoch;
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });
    try {
      await action(epoch);
    } catch (e) {
      if (mounted && epoch == _epoch) {
        setState(() => _error = e is ApiFailure ? e.message : '配置操作失败，请刷新后重试');
      }
    } finally {
      if (mounted && epoch == _epoch) {
        setState(() {
          _busy = false;
          _key.clear();
        });
      }
    }
  }

  Future<void> _load() => _run((epoch) async {
    final data = await Future.wait([_api('settings'), _api('reconciliation')]);
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _apply(data[0]);
      _reviews = (data[1]['items'] as List)
          .whereType<Map>()
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
    });
  });
  Future<void> _save() => _run((epoch) async {
    final model = _fields['model']!.text.trim();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$').hasMatch(model)) {
      throw const ApiFailure('请填写有效的模型 ID');
    }
    final body = <String, dynamic>{
      for (final key in [
        'revision',
        'enabled',
        'provider',
        'published',
        'usageVerified',
        'boundVerified',
      ])
        key: _draft[key],
      'model': model,
      'paymentsEnabled': _draft['paymentsEnabled'] == true,
      'rates': {
        for (final key in _rates.keys)
          key: rateAtoms(_fields[key]!.text.trim()),
      },
    };
    for (final entry in _limits.entries) {
      final value = int.tryParse(_fields[entry.key]!.text.trim());
      if (value == null || value < entry.value.$2 || value > entry.value.$3) {
        throw ApiFailure('${entry.value.$1}超出范围');
      }
      body[entry.key] = value;
    }
    final numerator = int.tryParse(_fields['deepseek:markupNumerator']!.text),
        denominator = int.tryParse(_fields['deepseek:markupDenominator']!.text);
    if (numerator == null ||
        denominator == null ||
        numerator < 1 ||
        denominator < 1) {
      throw const ApiFailure('工具费倍率须为正整数');
    }
    body['deepseekApps'] = {
      'enabled': _draft['deepseekApps']['enabled'] == true,
      'markupNumerator': '$numerator',
      'markupDenominator': '$denominator',
      'reservationAtoms': rateAtoms(
        _fields['deepseek:reservationAtoms']!.text.trim(),
      ),
      'tokenRates': {
        for (final name in _rates.keys)
          name: rateAtoms(_fields['deepseek:$name']!.text.trim()),
      },
    };
    if (_replace && _key.text.isNotEmpty) body['apiKey'] = _key.text;
    if (_remove) body['removeKey'] = true;
    final data = await _api('settings', method: 'POST', body: body);
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _apply(data);
      _notice = '服务配置已保存，新请求采用新设置。';
    });
    await widget.onUpdated();
  });
  Future<void> _reconcile(Map<String, dynamic> item) => _run((epoch) async {
    final id = '${item['request_id']}', proof = _proofs[id]?.text.trim() ?? '';
    if (!RegExp(r'^[A-Za-z0-9._:/-]{8,200}$').hasMatch(proof)) {
      throw const ApiFailure('请填写可追溯的供应商核对凭据编号');
    }
    final data = await _api(
      'reconcile',
      method: 'POST',
      body: {
        'request_id': id,
        'action': item['final_usage'] != null || item['observed_usage'] != null
            ? 'settle'
            : 'release',
        'proof_ref': proof,
      },
    );
    final reviews = await _api('reconciliation');
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _reviews = (reviews['items'] as List)
          .whereType<Map>()
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
      _notice = data['status'] == 'settled'
          ? '核对完成，最终用量已结算。'
          : data['status'] == 'released'
          ? '冻结已释放，核对凭据已留档。'
          : '核对证据已记录，冻结仍保留。';
    });
    await widget.onUpdated();
  });
  Widget _field(String name, String label, {bool number = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: TextField(
      controller: _fields[name],
      enabled: !_busy,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      decoration: InputDecoration(labelText: label),
    ),
  );
  @override
  void dispose() {
    _epoch++;
    _key.dispose();
    for (final field in [..._fields.values, ..._proofs.values]) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NativeSiteSection(
    title: '直供服务管理',
    subtitle: '仅维护者可见',
    child: ExpansionTile(
      title: const Text('供应商、售价与待核对请求'),
      onExpansionChanged: (value) {
        if (value && _settings.isEmpty) _load();
      },
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error.isNotEmpty)
          Text(
            _error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_notice.isNotEmpty) Text(_notice),
        Wrap(
          spacing: 12,
          children: [
            TextButton(
              onPressed: _busy ? null : _load,
              child: const Text('重新读取配置'),
            ),
            TextButton(
              onPressed: _busy ? null : widget.onUpdated,
              child: const Text('更新页面用量'),
            ),
            TextButton(
              onPressed: () => widget.onGo('/terminal?panel=payments'),
              child: const Text('管理充值商品'),
            ),
          ],
        ),
        if (_draft.isNotEmpty) ...[
          DropdownButtonFormField<String>(
            key: ValueKey(
              'provider:${_settings['revision']}:${_draft['provider']}',
            ),
            initialValue: '${_draft['provider']}',
            isExpanded: true,
            decoration: const InputDecoration(labelText: '供应商'),
            items: [
              for (final provider
                  in (_settings['providers'] as List).whereType<Map>())
                DropdownMenuItem(
                  value: '${provider['id']}',
                  child: Text(
                    '${provider['name']} · ${provider['hasKey'] == true ? '已保存密钥' : '未配置密钥'}',
                  ),
                ),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _draft['provider'] = value;
                    _fields['model']!.clear();
                    _key.clear();
                    _replace = false;
                    _remove = false;
                  }),
          ),
          _field('model', '模型 ID'),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('更换供应商密钥'),
            value: _replace,
            onChanged: _busy || _settings['simulation'] == true || _remove
                ? null
                : (v) => setState(() {
                    _replace = v!;
                    _key.clear();
                  }),
          ),
          if (_replace)
            TextField(
              controller: _key,
              obscureText: true,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '新供应商密钥',
                hintText: '留空保留原密钥',
              ),
            ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('删除所选供应商密钥'),
            value: _remove,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _remove = v!;
                    _replace = false;
                    _key.clear();
                  }),
          ),
          for (final rate in _rates.entries)
            _field(rate.key, '${rate.value} · 元 / 百万 Token', number: true),
          ExpansionTile(
            title: const Text('DeepSeek 对话与工具'),
            children: [
              SwitchListTile(
                title: const Text('开放 DeepSeek 应用能力'),
                value: _draft['deepseekApps']['enabled'] == true,
                onChanged: _busy
                    ? null
                    : (v) =>
                          setState(() => _draft['deepseekApps']['enabled'] = v),
              ),
              const Text('使用已保存的 DeepSeek 密钥。工具费按倍率收取，Token 售价包含加价。'),
              _field('deepseek:markupNumerator', '工具倍率分子', number: true),
              _field('deepseek:markupDenominator', '工具倍率分母', number: true),
              _field('deepseek:reservationAtoms', '每次预留金额（元）', number: true),
              for (final rate in _rates.entries)
                _field(
                  'deepseek:${rate.key}',
                  'DeepSeek ${rate.value} · 元 / 百万 Token',
                  number: true,
                ),
            ],
          ),
          for (final limit in _limits.entries)
            _field(
              limit.key,
              '${limit.value.$1}（${limit.value.$2}–${limit.value.$3}）',
              number: true,
            ),
          for (final flag in {
            'published': '公布售价',
            'usageVerified': '已核验供应商最终用量协议',
            'boundVerified': '已核验请求费用上限',
            'enabled': '启用站内直供',
          }.entries)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(flag.value),
              value: _draft[flag.key] == true,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _draft[flag.key] = v),
            ),
          const Text('保存后仅影响新请求。充值金额、商品和支付开关沿用网站支付管理。'),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: const Text('保存服务配置'),
          ),
          const SizedBox(height: 16),
          const Text('待核对请求', style: TextStyle(fontSize: 20)),
          if (_reviews.isEmpty) const Text('目前没有待核对的请求。'),
          for (final item in _reviews)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('${item['model']} · ${usageStatus(item['state'])}'),
                  SelectableText('${item['request_id']}'),
                  Text(
                    '冻结 ¥${moneyAtoms(item['hold_atoms'])} · ${item['error_code'] ?? ''}',
                  ),
                  if (item['final_usage'] != null ||
                      item['observed_usage'] != null)
                    Text('${item['final_usage'] ?? item['observed_usage']}'),
                  TextField(
                    controller: _proofs.putIfAbsent(
                      '${item['request_id']}',
                      TextEditingController.new,
                    ),
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: '供应商核对凭据编号'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _reconcile(item),
                    child: Text(
                      item['final_usage'] != null ||
                              item['observed_usage'] != null
                          ? '按凭据结算'
                          : '凭未消费证明释放',
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    ),
  );
}
