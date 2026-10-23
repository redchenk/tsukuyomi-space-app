import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/official_api.dart';
import '../../core/official_tts.dart';
import '../../core/site_client.dart';
import '../room/room_controller.dart';

class OfficialTtsHistory extends StatefulWidget {
  const OfficialTtsHistory({super.key, required this.controller, this.client});
  final RoomController controller;
  final OfficialTtsClient? client;
  @override
  State<OfficialTtsHistory> createState() => _OfficialTtsHistoryState();
}

class _OfficialTtsHistoryState extends State<OfficialTtsHistory> {
  late final OfficialTtsClient _client;
  int _epoch = 0;
  String _error = '';
  bool _loading = false;
  List<Map<String, dynamic>> _rows = [];
  RoomController get c => widget.controller;
  String get _identity =>
      '${c.scope}|${c.account?.id}|${c.site.cookie}|${c.sessionVerified}|${c.sessionExpired}';
  late String _owner;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? OfficialTtsClient(site: c.site);
    _owner = _identity;
    c.addListener(_changed);
    // Automatic reads use the native session transport. Other transports can
    // supply a client explicitly.
    if (widget.client != null || c.site is SiteClient) unawaited(_refresh());
  }

  void _changed() {
    if (_owner == _identity) return;
    _owner = _identity;
    _epoch++;
    _client.cancel();
    _rows = [];
    _error = '';
    _loading = false;
    if (mounted) {
      setState(() {});
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final epoch = ++_epoch, owner = _identity, account = c.account;
    if (account == null ||
        !c.sessionVerified ||
        c.sessionExpired ||
        account.scope == 'admin') {
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final rows = await _client.history(c.settings.siteUrl, account.id);
      if (mounted && epoch == _epoch && owner == _identity) {
        setState(() => _rows = rows);
      }
    } catch (e) {
      if (mounted && epoch == _epoch && owner == _identity) {
        setState(() => _error = e is ApiFailure ? e.message : '暂时无法读取语音账单');
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _epoch++;
    c.removeListener(_changed);
    _client.cancel();
    super.dispose();
  }

  String _time(dynamic value) => value is num
      ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
            .toLocal()
            .toString()
            .split('.')
            .first
      : '';
  String _amount(dynamic value) {
    try {
      return moneyAtoms(value);
    } catch (_) {
      return '—';
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 12),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                '官方语音账单',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              TextButton(
                onPressed: _loading ? null : _refresh,
                child: const Text('刷新语音记录'),
              ),
            ],
          ),
          const Text('与聊天共用网站余额，显示最近 30 条合成记录。'),
          if (_loading) const LinearProgressIndicator(),
          if (_error.isNotEmpty) Text(_error),
          if (!_loading && _error.isEmpty && _rows.isEmpty)
            const Text('暂无语音记录。'),
          for (final row in _rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('八千代语音 · ¥${_amount(row['chargedAtoms'])}'),
                  Text(switch (row['state']) {
                    'processing' => '合成中，金额预留',
                    'ready' => '已合成',
                    'failed' => '失败，未扣费',
                    'expired' => '已合成，缓存过期',
                    _ => '状态待核对',
                  }),
                  Text(_time(row['createdAt'])),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
