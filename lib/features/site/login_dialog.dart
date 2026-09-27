import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/site_client.dart';
import '../room/room_controller.dart';
import '../room/room_style.dart';
import 'site_widgets.dart';

Future<void> showSiteLogin(BuildContext context, RoomController controller) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _LoginDialog(controller),
    );

class _LoginDialog extends StatefulWidget {
  const _LoginDialog(this.controller);
  final RoomController controller;
  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  final _name = TextEditingController(),
      _password = TextEditingController(),
      _email = TextEditingController(),
      _code = TextEditingController();
  String _mode = 'password', _error = '';
  bool _busy = false;
  int _cooldown = 0;
  Timer? _timer;
  RoomController get c => widget.controller;
  @override
  void dispose() {
    _timer?.cancel();
    for (final v in [_name, _password, _email, _code]) {
      v.dispose();
    }
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (_busy || _cooldown > 0 || c.site is! SiteDataService) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await (c.site as SiteDataService).request(
        c.settings.siteUrl,
        'POST',
        '/api/auth/email-code',
        {
          'email': _mode == 'code' ? _name.text.trim() : _email.text.trim(),
          'purpose': _mode == 'register'
              ? 'register'
              : _mode == 'reset'
              ? 'password_reset'
              : 'login',
        },
      );
      if (!mounted) return;
      setState(() {
        _cooldown = 60;
        _error = '验证码已发送，请查看邮箱';
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _cooldown--);
        if (_cooldown == 0) timer.cancel();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      if (_mode == 'password') {
        await c.login(_name.text.trim(), _password.text);
      } else {
        final body = switch (_mode) {
          'code' => {
            'loginMethod': 'code',
            'username': _name.text.trim(),
            'emailCode': _code.text.trim(),
          },
          'reset' => {
            'email': _email.text.trim(),
            'emailCode': _code.text.trim(),
            'newPassword': _password.text,
          },
          _ => {
            'username': _name.text.trim(),
            'email': _email.text.trim(),
            'emailCode': _code.text.trim(),
            'password': _password.text,
          },
        };
        await c.login(
          '',
          '',
          credentials: body,
          authPath: switch (_mode) {
            'register' => '/api/auth/register',
            'reset' => '/api/auth/password/reset',
            _ => '/api/auth/login',
          },
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = RoomStyle(context);
    final form = SiteCard(
      padding: const EdgeInsets.all(32),
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '☾  TSUKUYOMI GATE',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.4,
                color: p.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              switch (_mode) {
                'register' => '加入月读空间',
                'reset' => '重设密码',
                _ => '欢迎回来',
              },
              style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(_mode == 'register' ? '开始记录你的月下旅程' : '欢迎回来，请登录你的账号'),
            const SizedBox(height: 20),
            if (_mode == 'password' || _mode == 'code') ...[
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'password', label: Text('密码登录')),
                  ButtonSegment(value: 'code', label: Text('验证码登录')),
                ],
                selected: {_mode},
                showSelectedIcon: false,
                onSelectionChanged: _busy
                    ? null
                    : (v) => setState(() {
                        _mode = v.first;
                        _error = '';
                      }),
              ),
              const SizedBox(height: 24),
            ],
            if (_mode != 'reset')
              TextField(
                controller: _name,
                enabled: !_busy,
                autofillHints: const [AutofillHints.username],
                decoration: InputDecoration(
                  labelText: _mode == 'code' ? '邮箱' : '用户名 / 邮箱',
                ),
              ),
            if (_mode == 'register' || _mode == 'reset') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _email,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: '邮箱'),
              ),
            ],
            if (_mode != 'password') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: '邮箱验证码',
                  suffixIcon: TextButton(
                    onPressed: _busy || _cooldown > 0 ? null : _sendCode,
                    child: Text(_cooldown > 0 ? '${_cooldown}s' : '发送验证码'),
                  ),
                ),
              ),
            ],
            if (_mode != 'code') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: true,
                onSubmitted: (_) {
                  if (!_busy) _submit();
                },
                decoration: InputDecoration(
                  labelText: _mode == 'reset' ? '新密码' : '密码',
                ),
              ),
            ],
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(
                _busy
                    ? '正在连接…'
                    : _mode == 'register'
                    ? '注册并登录'
                    : _mode == 'reset'
                    ? '重设并登录'
                    : '登录',
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                for (final item in const {
                  'register': '注册',
                  'reset': '忘记密码',
                }.entries)
                  if (item.key != _mode)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _mode = item.key;
                              _error = '';
                            }),
                      child: Text(item.value),
                    ),
              ],
            ),
            if (_mode == 'register' || _mode == 'reset')
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() => _mode = 'password'),
                child: const Text('返回登录'),
              ),
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('返回首页'),
            ),
          ],
        ),
      ),
    );
    return Dialog.fullscreen(
      child: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/images/moonlit-lake.png',
              fit: BoxFit.cover,
            ),
          ),
          Positioned.fill(
            child: ColoredBox(color: p.background.withValues(alpha: .78)),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, box) {
                final desktop = box.maxWidth >= 860;
                final content = desktop
                    ? Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 48,
                                vertical: 40,
                              ),
                              color: p.surface.withValues(alpha: .65),
                              child: form,
                            ),
                          ),
                          const SizedBox(width: 64),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Chip(
                                  label: Text(
                                    '☾ TSUKUYOMI SPACE',
                                    style: TextStyle(
                                      fontSize: 11,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  '月读空间',
                                  style: TextStyle(
                                    fontFamily: RoomStyle.serif,
                                    fontSize: 64,
                                    color: p.ink,
                                    letterSpacing: 4,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                const Text(
                                  '探索、记录、分享',
                                  style: TextStyle(
                                    fontSize: 16,
                                    letterSpacing: 3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : form;
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: box.maxHeight),
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: desktop ? 48 : 20,
                          vertical: desktop ? 30 : 24,
                        ),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: desktop ? 1080 : 440,
                          ),
                          child: content,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
