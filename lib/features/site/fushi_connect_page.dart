import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../room/room_controller.dart';
import 'login_dialog.dart';
import 'native_site_shell.dart';
import 'site_widgets.dart';

String? fushiConfirmation(Uri callback, Uri site) {
  final q = callback.queryParametersAll;
  if (q.containsKey('error') ||
      !['code', 'state', 'iss'].every((k) => q[k]?.length == 1) ||
      q['iss']!.single != site.origin) {
    return null;
  }
  final token = RegExp(r'^[A-Za-z0-9_-]{43}$');
  if (!token.hasMatch(q['code']!.single) ||
      !token.hasMatch(q['state']!.single)) {
    return null;
  }
  final data = {
    for (final k in ['code', 'state', 'iss']) k: q[k]!.single,
  };
  return '/Fushi确认 ${base64Url.encode(utf8.encode(jsonEncode(data))).replaceAll('=', '')}';
}

class FushiConnectPage extends StatefulWidget {
  const FushiConnectPage({
    super.key,
    required this.room,
    required this.path,
    required this.onGo,
    this.onTheme,
  });
  final RoomController room;
  final Uri path;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  @override
  State<FushiConnectPage> createState() => _FushiState();
}

class _FushiState extends State<FushiConnectPage> {
  bool busy = false, copied = false;
  String error = '';
  late final String origin = endpointUri(widget.room.settings.siteUrl).origin;
  Future<void> authorize(bool approve) async {
    if (busy || widget.room.sessionExpired || widget.room.account == null) {
      return;
    }
    final account = widget.room.account?.id;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final q = widget.path.queryParameters;
      final response = await (widget.room.site as SiteDataService).request(
        origin,
        'POST',
        '/api/fushi/oauth/authorize',
        {...q, 'approve': approve},
      );
      if (!mounted ||
          account != widget.room.account?.id ||
          origin != endpointUri(widget.room.settings.siteUrl).origin) {
        return;
      }
      final redirect = Uri.tryParse(
            textOf(mapOf(response['data']), 'redirect'),
          ),
          expected = Uri.tryParse(q['redirect_uri'] ?? '');
      if (redirect == null ||
          expected == null ||
          !expected.hasAuthority ||
          redirect.scheme != 'https' ||
          redirect.userInfo.isNotEmpty ||
          redirect.origin != expected.origin ||
          redirect.path != expected.path) {
        throw const ApiFailure('授权返回地址无效');
      }
      widget.onGo(redirect.toString());
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final callback = widget.path.path.endsWith('/callback'),
        command = fushiConfirmation(widget.path, Uri.parse(origin));
    return NativeSiteShell(
      controller: widget.room,
      title: 'Fushi',
      onGo: widget.onGo,
      onTheme: widget.onTheme,
      maxWidth: 760,
      child: ListenableBuilder(
        listenable: widget.room,
        builder: (context, _) {
          if (origin != endpointUri(widget.room.settings.siteUrl).origin) {
            return const Text('站点已更改，请重新打开授权链接。');
          }
          return NativeSiteSection(
            title: callback
                ? (command != null
                      ? '最后一步，回到机器人私聊'
                      : widget.path.queryParameters['error'] == 'access_denied'
                      ? '已取消连接'
                      : '授权链接已失效')
                : '连接社区助手',
            subtitle: callback
                ? 'FUSHI × ASTRBOT'
                : 'FUSHI · COMMUNITY ASSISTANT',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (callback) ...[
                  if (command != null) ...[
                    const Text(
                      '复制下方指令，在发起登录的机器人私聊中发送。请在 90 秒内完成，超时后重新发送 /Fushi登录。',
                    ),
                    SelectableText(command),
                    FilledButton(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: command));
                        if (mounted) setState(() => copied = true);
                      },
                      child: Text(copied ? '已复制' : '复制确认指令'),
                    ),
                  ] else
                    const Text('返回机器人私聊，发送 /Fushi登录 后重新打开授权页面。'),
                ] else ...[
                  Text(
                    '允许 ${widget.path.queryParameters['client_id'] == 'tsukuyomi-fushi-astrbot' ? 'AstrBot' : '社区助手客户端'} 使用 Fushi 专属账号处理相关讨论。',
                  ),
                  const ListTile(title: Text('读取其他用户对 Fushi 内容的公开回复和讨论上下文。')),
                  const ListTile(title: Text('以 Fushi 提交普通回复，遵循现有内容审核。')),
                  if ((widget.path.queryParameters['scope'] ?? '')
                      .split(' ')
                      .contains('fushi:events'))
                    const ListTile(title: Text('订阅已审核通过的回复事件。')),
                  const ListTile(title: Text('查询回复是否已保存。')),
                  const Text(
                    '访问令牌有效 15 分钟，插件自动刷新。连续 180 天未续期后需要重新连接。可撤销授权或修改账号密码以终止访问。',
                  ),
                  if (error.isNotEmpty) Text(error),
                  if (widget.room.account == null || widget.room.sessionExpired)
                    FilledButton(
                      onPressed: () => showSiteLogin(context, widget.room),
                      child: const Text('登录 Fushi 账号'),
                    )
                  else
                    Wrap(
                      children: [
                        OutlinedButton(
                          onPressed: busy ? null : () => authorize(false),
                          child: const Text('取消授权'),
                        ),
                        FilledButton(
                          onPressed: busy ? null : () => authorize(true),
                          child: Text(busy ? '正在处理…' : '确认连接'),
                        ),
                      ],
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
