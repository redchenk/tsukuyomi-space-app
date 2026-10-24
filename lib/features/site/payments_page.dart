import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../core/models.dart';
import '../../core/official_api.dart';
import '../../core/payments.dart';
import '../../core/site_client.dart';
import '../room/room_controller.dart';
import 'login_dialog.dart';
import 'native_site_shell.dart';
import 'official_service_admin.dart';
import 'official_tts_history.dart';

class PaymentsPage extends StatefulWidget {
  const PaymentsPage({
    super.key,
    required this.controller,
    required this.onGo,
    this.onTheme,
    this.orderId,
    this.launcher,
  });
  final RoomController controller;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  final String? orderId;
  final AlipayCheckoutLauncher? launcher;
  @override
  State<PaymentsPage> createState() => _PaymentsPageState();
}

class _PaymentsPageState extends State<PaymentsPage>
    with WidgetsBindingObserver {
  RoomController get c => widget.controller;
  PaymentService get payments =>
      PaymentService(c.site as SiteDataService, c.settings.siteUrl);
  String get identity =>
      '${c.scope}|${c.site.cookie}|${c.sessionExpired}|${c.sessionVerified}';
  bool get authenticated =>
      c.account != null &&
      c.account!.scope != 'admin' &&
      c.sessionVerified &&
      !c.sessionExpired &&
      !c.settings.demo;
  String _identity = '',
      _error = '',
      _officialError = '',
      _busy = '',
      _account = '';
  bool _loading = true, _officialLoading = false, _foreground = true;
  int _epoch = 0, _polls = 0;
  Map<String, dynamic> _catalog = {},
      _orders = {},
      _wallet = {},
      _dashboard = {},
      _usage = {},
      _statement = {};
  Map<String, dynamic>? _current;
  String get _channel => mobilePaymentPlatform
      ? (_catalog['appCheckout'] == true &&
                defaultTargetPlatform == TargetPlatform.android
            ? 'app'
            : 'mobile')
      : 'web';
  bool get _mobileReady =>
      !mobilePaymentPlatform ||
      _channel == 'app' ||
      _catalog['mobileCheckout'] == true;
  final _requestKeys = <String, String>{};
  final _month = TextEditingController(
    text: DateTime.now().toUtc().toIso8601String().substring(0, 7),
  );
  Timer? _timer;
  bool valid(int epoch) =>
      mounted && epoch == _epoch && _identity == identity && authenticated;
  List<Map<String, dynamic>> rows(dynamic value) => value is List
      ? value
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList()
      : [];
  String message(Object e) => e is ApiFailure ? e.message : '服务暂时不可用，请稍后重试';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _identity = identity;
    c.addListener(_changed);
    unawaited(_load(initial: true));
  }

  void _changed() {
    if (_identity == identity) return;
    _identity = identity;
    _epoch++;
    _timer?.cancel();
    _requestKeys.clear();
    _current = null;
    _wallet = {};
    _orders = {};
    _dashboard = {};
    _usage = {};
    _statement = {};
    _account = '';
    _busy = '';
    _error = '';
    _officialError = '';
    _officialLoading = false;
    if (mounted) {
      setState(() {});
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _epoch++;
    _timer?.cancel();
    _month.dispose();
    c.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _timer?.cancel();
    if (_foreground &&
        authenticated &&
        ModalRoute.of(context)?.isCurrent == true) {
      _polls = 0;
      if (_current != null && _current!['status'] != 'paid') {
        unawaited(_refresh());
      } else {
        unawaited(_load());
      }
    }
  }

  Future<void> _load({bool initial = false}) async {
    if (_busy.isNotEmpty) return;
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = '';
    });
    if (c.site is! SiteDataService) {
      setState(() {
        _error = '当前客户端无法连接支付服务';
        _loading = false;
      });
      return;
    }
    await Future.wait([
      () async {
        try {
          final data = await payments.request('GET', '/catalog');
          if (mounted && epoch == _epoch) setState(() => _catalog = data);
        } catch (e) {
          if (mounted && epoch == _epoch) setState(() => _error = message(e));
        }
      }(),
      if (authenticated)
        () async {
          try {
            await _history(
              epoch,
              page: initial ? 1 : (_orders['page'] as int? ?? 1),
            );
          } catch (e) {
            if (valid(epoch)) setState(() => _error = message(e));
          }
        }(),
      if (authenticated) _loadOfficial(epoch),
    ]);
    if (!mounted || epoch != _epoch) return;
    setState(() => _loading = false);
    if (initial &&
        authenticated &&
        widget.orderId != null &&
        RegExp(r'^TS[a-f0-9]{32}$').hasMatch(widget.orderId!)) {
      await _run('order', (epoch) async {
        final order = await payments.request(
          'GET',
          '/orders/${widget.orderId}',
        );
        if (!valid(epoch)) return;
        setState(() => _current = order);
        await _refreshCurrent(epoch);
      });
    }
  }

  Future<void> _history(int epoch, {int? page}) async {
    final results = await Future.wait([
      payments.request('GET', '/orders?page=${page ?? _orders['page'] ?? 1}'),
      payments.request('GET', '/wallet'),
    ]);
    if (valid(epoch)) {
      setState(() {
        _orders = results[0];
        _wallet = results[1];
      });
    }
  }

  Future<Map<String, dynamic>> _official(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    if (c.site is! OfficialDataService) throw const ApiFailure('站内直供接口暂不可用');
    return (c.site as OfficialDataService).officialRequest(
      c.settings.siteUrl,
      method,
      path,
      account: _account.isEmpty ? null : _account,
      body: body,
    );
  }

  Future<void> _loadOfficial(int epoch) async {
    setState(() {
      _officialLoading = true;
      _officialError = '';
      _dashboard = {};
      _account = '';
    });
    try {
      final user = c.account!.id;
      final data = officialDashboard(await _official('/api/dashboard'), user);
      if (!valid(epoch)) return;
      setState(() {
        _dashboard = data;
        _account = (data['me'] as Map)['account_id'] as String;
        _usage = Map<String, dynamic>.from(data['usage'] as Map? ?? {});
        _statement = Map<String, dynamic>.from(data['statement'] as Map? ?? {});
        _month.text = '${_statement['month'] ?? _month.text}';
      });
    } catch (e) {
      if (valid(epoch)) {
        setState(() {
          _officialError = message(e);
          _usage = {};
          _statement = {};
        });
      }
    } finally {
      if (valid(epoch)) setState(() => _officialLoading = false);
    }
  }

  Future<void> _run(String name, Future<void> Function(int) action) async {
    if (_busy.isNotEmpty || !authenticated) return;
    final epoch = _epoch;
    setState(() {
      _busy = name;
      _error = '';
    });
    try {
      await action(epoch);
    } catch (e) {
      if (valid(epoch)) setState(() => _error = message(e));
    } finally {
      if (valid(epoch)) setState(() => _busy = '');
    }
  }

  Future<void> _pay(Map<String, dynamic> order, int epoch) async {
    if (!valid(epoch)) return;
    final channel = order['channel'] == 'app'
        ? 'app'
        : mobilePaymentPlatform
        ? 'mobile'
        : 'web';
    if (channel == 'app' && defaultTargetPlatform != TargetPlatform.android) {
      throw const ApiFailure('此订单请在 Android 应用中继续付款');
    }
    if ((channel == 'app' &&
            (_catalog['appCheckout'] != true || !mobilePaymentPlatform)) ||
        (channel == 'mobile' && _catalog['mobileCheckout'] != true)) {
      throw const ApiFailure('此订单的手机支付渠道尚未开放，请联系管理员');
    }
    final result = await payments.request(
      'POST',
      '/orders/${order['id']}/checkout',
      {'channel': channel},
    );
    if (!valid(epoch)) return;
    setState(() => _current = order);
    final launcher = widget.launcher ?? AlipayCheckoutLauncher();
    if (channel == 'app') {
      Object? sdkError;
      try {
        await launcher.payApp(result, order);
      } catch (e) {
        sdkError = e;
      }
      if (valid(epoch)) await _refreshCurrent(epoch);
      if (sdkError != null && _current?['status'] != 'paid') throw sdkError;
    } else {
      await launcher.launch('${result['url']}', mobile: mobilePaymentPlatform);
    }
    if (valid(epoch)) {
      _polls = 0;
      _schedule();
    }
  }

  Future<void> _purchase(Map<String, dynamic> product) =>
      _run('${product['id']}', (epoch) async {
        if (!_mobileReady) throw const ApiFailure('手机支付尚未开放，请联系管理员开通 App 支付');
        final id = '${product['id']}';
        final key = _requestKeys.putIfAbsent(id, newTurnId);
        final order = await payments.request('POST', '/orders', {
          'productId': id,
          'requestKey': key,
          'channel': _channel,
        });
        if (!valid(epoch)) return;
        _requestKeys.remove(id);
        setState(() => _current = order);
        try {
          await _pay(order, epoch);
        } finally {
          if (valid(epoch)) await _history(epoch, page: 1);
        }
      });
  Future<void> _refreshCurrent(int epoch) async {
    final order = _current;
    if (order == null) return;
    final data = await payments.request(
      'POST',
      '/orders/${order['id']}/refresh',
    );
    if (!valid(epoch)) return;
    setState(() => _current = data);
    await _history(epoch);
    _schedule();
  }

  Future<void> _refresh() async {
    await _run('refresh', _refreshCurrent);
    if (mounted) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (_current?['status'] != 'pending' || _polls >= 6 || !authenticated) {
      return;
    }
    _timer = Timer(const Duration(seconds: 10), () {
      if (!mounted ||
          !_foreground ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      _polls++;
      unawaited(_refresh());
    });
  }

  Future<void> _usageMore() => _run('usage', (epoch) async {
    final data = await _official(
      '/api/usage?cursor=${Uri.encodeComponent('${_usage['next_cursor']}')}',
    );
    if (valid(epoch)) {
      setState(
        () => _usage = {
          ...data,
          'items': [...rows(_usage['items']), ...rows(data['items'])],
        },
      );
    }
  });
  Future<void> _statementMonth() => _run('month', (epoch) async {
    if (!RegExp(r'^20\d{2}-(0[1-9]|1[0-2])$').hasMatch(_month.text) ||
        _month.text.compareTo(
              DateTime.now().toUtc().toIso8601String().substring(0, 7),
            ) >
            0) {
      throw const ApiFailure('请输入有效的账单月份，例如 2026-10');
    }
    final data = await _official(
      '/api/statements/monthly?month=${_month.text}',
    );
    if (valid(epoch)) setState(() => _statement = data);
  });
  Widget _section(
    String title,
    List<Widget> children, {
    String subtitle = '',
  }) => NativeSiteSection(
    title: title,
    subtitle: subtitle,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
  Widget _button(String label, VoidCallback action, {bool enabled = true}) =>
      Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: OutlinedButton(
          onPressed: enabled && _busy.isEmpty ? action : null,
          child: Text(label),
        ),
      );
  Widget _money(String label, dynamic atoms) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text('$label  ¥${moneyAtoms(atoms)}'),
  );
  String _date(dynamic value) {
    final date = value is num
        ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
        : DateTime.tryParse('$value');
    return date?.toLocal().toString().split('.').first ?? '';
  }

  @override
  Widget build(BuildContext context) => NativeSiteShell(
    controller: c,
    title: '支付中心',
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    onRefresh: _load,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '充值、订单与聊天用量',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        if (_error.isNotEmpty)
          Text(
            _error,
            key: const Key('payment-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_loading) const LinearProgressIndicator(),
        if (!authenticated)
          _section('登录后查看支付中心', [
            const Text('充值、余额和用量均关联到你的月读空间账号。'),
            _button('登录月读空间', () => showSiteLogin(context, c)),
          ])
        else ...[
          if (_wallet.isNotEmpty)
            _section('网站统一余额', [
              Text(
                _wallet['unlimited'] == true
                    ? '不限额度'
                    : '¥${moneyAtoms(_wallet['available_atoms'])}',
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                ),
              ),
              _money('账面余额', _wallet['balance_atoms']),
              _money('待结算冻结', _wallet['held_atoms']),
              Text(
                _wallet['unlimited'] == true
                    ? '超级管理员免扣余额，用量照常记录。'
                    : '全站共用一份余额，冻结金额尚未扣费。',
              ),
            ]),
          if (_current != null)
            _section(paymentStatus(_current!), [
              Text('${_current!['title']} · ¥${_current!['amount']}'),
              SelectableText('${_current!['id']}'),
              if (_current!['walletCredited'] == true)
                Text('已充值 ¥${_current!['walletCreditAmount']} 到网站余额。'),
              if (_current!['status'] == 'pending')
                const Text('付款后会自动核对结果。返回应用后若未更新，请手动核对。'),
              if (_catalog['enabled'] == true &&
                  _current!['status'] == 'pending' &&
                  _current!['expired'] != true)
                _button(
                  '前往支付宝付款',
                  () => _run('pay', (epoch) => _pay(_current!, epoch)),
                ),
              if (_current!['status'] != 'paid') _button('核对支付结果', _refresh),
            ]),
          _section('充值与服务', [
            if (_catalog['enabled'] != true) const Text('在线收款暂未开放，已有订单仍可查看。'),
            if (mobilePaymentPlatform &&
                _catalog['enabled'] == true &&
                !_mobileReady)
              const Text('手机支付尚未开放，请联系管理员开通 App 支付。'),
            for (final product in rows(_catalog['products']))
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${product['title']}',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text('${product['description'] ?? ''}'),
                      if (product['walletCredit'] == true)
                        Text('支付成功后充值 ¥${product['price']} 到网站余额。'),
                      Text(
                        '¥${product['price']}',
                        style: const TextStyle(fontSize: 24),
                      ),
                      _button(
                        '使用支付宝支付',
                        () => _purchase(product),
                        enabled: _catalog['enabled'] == true && _mobileReady,
                      ),
                    ],
                  ),
                ),
              ),
          ]),
          _section('我的订单', [
            _button('刷新订单与余额', () => _run('history', _history)),
            if (rows(_orders['items']).isEmpty) const Text('暂无订单。'),
            for (final order in rows(_orders['items']))
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('${order['title']} · ¥${order['amount']}'),
                      Text(
                        '${paymentStatus(order)} · ${_date(order['createdAt'])}',
                      ),
                      SelectableText('${order['id']}'),
                      _button('查看并核对', () {
                        setState(() => _current = order);
                        _polls = 0;
                        unawaited(_refresh());
                      }),
                    ],
                  ),
                ),
              ),
            if ((_orders['totalPages'] as int? ?? 1) > 1)
              Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _button(
                    '上一页',
                    () => _run(
                      'history',
                      (e) => _history(e, page: (_orders['page'] as int) - 1),
                    ),
                    enabled: (_orders['page'] as int) > 1,
                  ),
                  Text('${_orders['page']} / ${_orders['totalPages']}'),
                  _button(
                    '下一页',
                    () => _run(
                      'history',
                      (e) => _history(e, page: (_orders['page'] as int) + 1),
                    ),
                    enabled:
                        (_orders['page'] as int) <
                        (_orders['totalPages'] as int),
                  ),
                ],
              ),
          ]),
          OfficialTtsHistory(controller: c),
          _section('站内直供', [
            if (_officialLoading) const LinearProgressIndicator(),
            if (_officialError.isNotEmpty) Text(_officialError),
            _button(
              '刷新模型与用量',
              () => _loadOfficial(_epoch),
              enabled: !_officialLoading,
            ),
            if (_dashboard.isEmpty && !_officialLoading)
              const Text('模型用量暂不可用，充值与订单仍可独立使用。'),
            for (final model in rows(_dashboard['models']))
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${model['id']}',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${model['provider']} · ${officialModelSupportsImages(model) ? '文字与图片' : '文字'} · 最多输出 ${model['max_output_tokens']} Token · ${model['enabled'] == true ? '服务已启用' : '暂未开放'}',
                      ),
                      if (officialModelSupportsImages(model))
                        const Text('Room 可直接发送图片，图片与文字按实际 Token 用量统一计费。'),
                      if (model['price'] is Map) ...[
                        for (final rate in {
                          'input_uncached': '输入 · 未命中缓存',
                          'input_cached': '输入 · 命中缓存',
                          'output': '输出',
                        }.entries)
                          _money(
                            rate.value,
                            (model['price']['rates_per_million_money_atoms']
                                    as Map? ??
                                {})[rate.key],
                          ),
                      ] else
                        const Text('售价尚未公布。'),
                    ],
                  ),
                ),
              ),
            const Text('单价为每百万 Token 的人民币金额。请求接纳时锁定售价，按最终用量结算。'),
            _button(
              '前往聊天模型设置',
              () => widget.onGo('/room/settings?section=llm'),
            ),
          ]),
          _section('用量账单', [
            TextField(
              controller: _month,
              decoration: const InputDecoration(labelText: 'UTC 账单月份（YYYY-MM）'),
              keyboardType: TextInputType.datetime,
              enabled: _busy.isEmpty && _account.isNotEmpty,
            ),
            _button('查询月账单', _statementMonth, enabled: _account.isNotEmpty),
            const Text('按 UTC 自然月统计。余额不按月清零，账单汇总不会再次扣费。'),
            if (_statement.isNotEmpty) ...[
              _money('已结算消费', _statement['charged_atoms']),
              _money('已到账充值', _statement['credited_atoms']),
              _money('待核对冻结', _statement['pending_hold_atoms']),
            ],
            const SizedBox(height: 12),
            const Text('最近使用记录', style: TextStyle(fontSize: 20)),
            if (_dashboard.isNotEmpty && rows(_usage['items']).isEmpty)
              const Text('暂无使用记录。'),
            for (final item in rows(_usage['items']))
              Card(
                child: InkWell(
                  onTap: () => _requestDetail('${item['request_id']}'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${item['model']} · ${usageStatus(item['status'])}',
                        ),
                        Text(
                          '${_date(item['created_at'])}\n${item['request_id']}\n${item['usage'] is Map ? '输入 ${item['usage']['input_uncached']} · 缓存 ${item['usage']['input_cached']} · 输出 ${item['usage']['output']}' : '最终用量待核对'}',
                        ),
                        Text(
                          item['status'] == 'released'
                              ? '未扣费'
                              : item['billing_mode'] == 'sponsored'
                              ? '免扣费'
                              : item['charged_atoms'] != null
                              ? '¥${moneyAtoms(item['charged_atoms'])}'
                              : '尚未结算',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_usage['next_cursor'] != null) _button('加载更多记录', _usageMore),
          ]),
          if ((_dashboard['me'] as Map?)?['operator'] == true)
            OfficialServiceAdmin(
              key: ValueKey(_account),
              client: c.site as OfficialDataService,
              site: c.settings.siteUrl,
              account: _account,
              onUpdated: () => _loadOfficial(_epoch),
              onGo: widget.onGo,
            ),
        ],
      ],
    ),
  );

  Future<void> _requestDetail(String id) => _run('request', (epoch) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id)) return;
    final data = await _official('/api/requests/$id');
    if (!mounted || !valid(epoch)) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('请求详情'),
        content: SingleChildScrollView(
          child: SelectableText(
            '请求编号：$id\n模型：${data['model'] ?? ''}\n状态：${usageStatus(data['state'] ?? data['status'])}\n'
            '费用：${data['charged_atoms'] == null ? '尚未结算' : '¥${moneyAtoms(data['charged_atoms'])}'}\n'
            '用量：${data['final_usage'] ?? data['usage'] ?? '待核对'}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  });
}
