import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/official_api.dart';
import '../../core/site_client.dart';
import '../room/room_controller.dart';

/// Public readiness only. This never creates a voice job or charges a wallet.
class OfficialTtsPanel extends StatefulWidget {
  const OfficialTtsPanel({
    super.key,
    required this.controller,
    required this.onStatus,
    required this.onPayments,
  });
  final RoomController controller;
  final ValueChanged<Map<String, dynamic>> onStatus;
  final VoidCallback onPayments;
  @override
  State<OfficialTtsPanel> createState() => _OfficialTtsPanelState();
}

class _OfficialTtsPanelState extends State<OfficialTtsPanel>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _status;
  bool _checking = false, _foreground = true;
  int _epoch = 0;
  Timer? _timer;
  String get _site => endpointUri(widget.controller.settings.siteUrl).origin;
  late String _origin;

  @override
  void initState() {
    super.initState();
    _origin = _site;
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    unawaited(_refresh());
    if (widget.controller.site is SiteDataService) {
      _timer = Timer.periodic(const Duration(seconds: 15), (_) {
        if (_foreground && (ModalRoute.of(context)?.isCurrent ?? true)) {
          unawaited(_refresh());
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant OfficialTtsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_origin != _site ||
        !identical(oldWidget.controller.site, widget.controller.site)) {
      _origin = _site;
      _epoch++;
      _checking = false;
      _status = null;
      unawaited(_refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && (ModalRoute.of(context)?.isCurrent ?? true)) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (_checking) return;
    final epoch = ++_epoch, origin = _site;
    setState(() => _checking = true);
    Map<String, dynamic> status;
    try {
      final site = widget.controller.site;
      if (site is! SiteDataService) throw const ApiFailure('状态暂不可用');
      final result = await (site as SiteDataService)
          .request(origin, 'GET', '/api/tts/official/status')
          .timeout(const Duration(seconds: 8));
      status = Map<String, dynamic>.from(result['data'] as Map);
    } catch (_) {
      status = {'online': false, 'reason': 'offline'};
    }
    if (!mounted || epoch != _epoch || origin != _site) return;
    setState(() {
      _status = status;
      _checking = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && epoch == _epoch) widget.onStatus(status);
    });
  }

  @override
  void dispose() {
    _epoch++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final online = _status?['online'] == true;
    String price = '0.05';
    try {
      price = moneyAtoms(_status?['priceAtoms'] ?? '50000000');
    } catch (_) {
      /* Keep the published fixed-price hint. */
    }
    return Card(
      key: const ValueKey('official-tts-status'),
      margin: const EdgeInsets.symmetric(vertical: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  '官方直供 · 八千代语音',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  online
                      ? '算力在线'
                      : _status == null
                      ? '检测中'
                      : '算力离线',
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text('¥$price / 条 · 使用网站余额，无需 API 密钥。成功合成后扣费，失败不收费；超级管理员沿用无限额度。'),
            const SizedBox(height: 10),
            const Text(
              '每条最多 1,000 字。本次语音会话内有效缓存重播不重复扣费，缓存最长保留 24 小时。停止播放不会撤销已提交的合成任务。',
            ),
            const SizedBox(height: 10),
            Text(
              online
                  ? '可选用官方直供；离线时暂停新合成，恢复后可继续使用。'
                  : '官方算力暂不可用，也可以使用自己配置的语音服务。',
            ),
            Wrap(
              spacing: 10,
              children: [
                TextButton(
                  onPressed: _checking ? null : _refresh,
                  child: Text(_checking ? '正在检测…' : '检测算力'),
                ),
                TextButton(
                  onPressed: widget.onPayments,
                  child: const Text('余额与语音账单'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
