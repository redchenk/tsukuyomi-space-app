import '../../core/site_localization.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../room/room_controller.dart';
import 'native_site_shell.dart';
import 'qq_auth.dart';
import 'site_widgets.dart';

typedef QQAuthorize = Future<QQAuthGrant?> Function(
  BuildContext context,
  RoomController controller, {
  String redirect,
  bool bindCurrentAccount,
});

class NativeAuthPage extends StatefulWidget {
  const NativeAuthPage({
    super.key,
    required this.controller,
    this.path = '/login',
    required this.onGo,
    this.onTheme,
    this.authorize = showQQAuthorization,
    this.authorizeGitHub = showGitHubAuthorization,
    this.autoStartQQ = false,
    this.onAuthenticated,
  });
  final RoomController controller;
  final String path;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  final QQAuthorize authorize, authorizeGitHub;
  final bool autoStartQQ;
  final VoidCallback? onAuthenticated;
  @override
  State<NativeAuthPage> createState() => _NativeAuthPageState();
}

/// Shared native flow for UserCenter's QQ binding action. This completes the
/// provider cookie round trip, optional account/email form and session import.
Future<bool> showNativeQQBinding(
  BuildContext context,
  RoomController controller,
) async {
  var completed = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: SizedBox(
        width: 960,
        height: MediaQuery.sizeOf(dialogContext).height * .9,
        child: Stack(
          children: [
            NativeAuthPage(
              controller: controller,
              path: '/login?redirect=%2Fuser-center',
              autoStartQQ: true,
              onAuthenticated: () => completed = true,
              onGo: (_) {
                Navigator.pop(dialogContext);
              },
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                tooltip: '关闭绑定',
                onPressed: () => Navigator.pop(dialogContext),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  return completed;
}

class _NativeAuthPageState extends State<NativeAuthPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _email = TextEditingController(),
      _password = TextEditingController(),
      _confirm = TextEditingController(),
      _code = TextEditingController(),
      _qqName = TextEditingController();
  final _cooldowns = <String, DateTime>{};
  Timer? _timer;
  String _mode = 'password',
      _message = '',
      _origin = '',
      _qqMode = '',
      _provider = 'qq',
      _bindMethod = 'password';
  bool _busy = false, _failure = false, _showPassword = false;
  int _generation = 0;
  QQAuthGrant? _grant;
  Map<String, dynamic> _qqProfile = {};
  RoomController get c => widget.controller;
  Uri get route => Uri.parse(widget.path);
  String get redirect =>
      sanitizeAuthRedirect(route.queryParameters['redirect']);
  String get title => _grant != null
      ? (_qqMode == 'email' ? '绑定邮箱' : '$providerName 登录确认')
      : switch (_mode) {
          'register' => '创建账号',
          'reset' => '重设密码',
          _ => '欢迎回来',
        };
  String get providerName => _provider == 'github' ? 'GitHub' : 'QQ';
  bool get githubExisting =>
      _provider == 'github' &&
      _qqProfile['hasEmailMatch'] == true &&
      _email.text.trim().toLowerCase() ==
          textOf(_qqProfile, 'email').toLowerCase();
  bool get qq => _grant != null;
  bool get needsCode => qq
      ? _qqMode == 'email' || (_qqMode == 'bind' && _bindMethod == 'code')
      : _mode != 'password';
  bool get needsPassword => qq
      ? (_qqMode == 'email' && !githubExisting) ||
            (_qqMode == 'bind' && _bindMethod == 'password')
      : _mode != 'code';
  bool get newPassword => qq
      ? _qqMode == 'email' && !githubExisting
      : ['register', 'reset'].contains(_mode);
  String get purpose => qq
      ? (_qqMode == 'email' ? 'oauth_bind' : 'login')
      : switch (_mode) {
          'register' => 'register',
          'reset' => 'password_reset',
          _ => 'login',
        };
  String get codeEmail =>
      (qq
              ? (_qqMode == 'email' ? _email : _name)
              : (_mode == 'code' ? _name : _email))
          .text
          .trim();
  String get cooldownKey => '$purpose:${codeEmail.toLowerCase()}';
  int get cooldown =>
      (_cooldowns[cooldownKey]?.difference(DateTime.now()).inSeconds ?? 0)
          .clamp(0, 60);
  static bool validEmail(String value) =>
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.trim()) &&
      !value.trim().toLowerCase().endsWith('@oauth.yachiyo.local');
  String? _emailValidation(String? value) =>
      validEmail(value ?? '') ? null : '请输入真实且有效的邮箱';
  @override
  void initState() {
    super.initState();
    _origin = endpointUri(c.settings.siteUrl).origin;
    _setRoute();
    c.addListener(_originChanged);
    _captureInvite();
    if (widget.autoStartQQ) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startQQ());
    }
  }

  void _setRoute() {
    _mode = route.path == '/register'
        ? 'register'
        : (route.queryParameters['mode'] == 'reset' ||
              route.queryParameters['forgot'] == '1')
        ? 'reset'
        : 'password';
    final oauthError = route.queryParameters['oauth_error'];
    if (oauthError != null) {
      _message = qqOAuthErrors[oauthError] ?? 'QQ 登录失败，请重新授权';
      _failure = true;
    }
    if (route.queryParameters['ticket'] != null) {
      _message = '请在此应用内重新进行 QQ 授权；外部浏览器的授权绑定不能转移到应用。';
      _failure = true;
    }
  }

  @override
  void didUpdateWidget(covariant NativeAuthPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _generation++;
      _clearQQ();
      _message = '';
      _failure = false;
      _busy = false;
      _setRoute();
      _captureInvite();
    }
  }

  void _originChanged() {
    final origin = endpointUri(c.settings.siteUrl).origin;
    if (origin == _origin) return;
    _origin = origin;
    _generation++;
    _clearQQ();
    for (final field in [_name, _email, _password, _confirm, _code, _qqName]) {
      field.clear();
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _message = '站点已切换，请重新登录';
        _failure = true;
      });
    }
  }

  String get referralKey => 'pending-referral:$_origin';
  Future<void> _captureInvite() async {
    final invite = (route.queryParameters['invite'] ?? '').trim().toUpperCase();
    if (RegExp(r'^[A-F0-9]{10}$').hasMatch(invite)) {
      try {
        await c.storage.saveDraft(referralKey, invite);
      } catch (_) {}
    }
  }

  Future<void> _claimInvite() async {
    final key = referralKey, origin = _origin, account = c.account?.id;
    if (account == null) return;
    try {
      final code = await c.storage.draft(key);
      if (!RegExp(r'^[A-F0-9]{10}$').hasMatch(code) ||
          origin != _origin ||
          account != c.account?.id) {
        return;
      }
      await (c.site as SiteDataService).request(
        c.settings.siteUrl,
        'POST',
        '/api/growth/referrals/claim',
        {'code': code},
      );
      await c.storage.saveDraft(key, '');
    } on ApiFailure catch (e) {
      if (e.status != null && e.status! >= 400 && e.status! < 500) {
        await c.storage.saveDraft(key, '');
      }
    } catch (_) {
      /* A transient claim can be retried at the next login. */
    }
  }

  void _clearQQ() {
    _grant?.transport.dispose();
    _grant = null;
    _qqProfile = {};
    _qqMode = '';
    _password.clear();
    _confirm.clear();
    _code.clear();
  }

  void _changeMode(String value) {
    if (_busy) return;
    setState(() {
      if (value == 'reset' && _name.text.trim().contains('@')) {
        _email.text = _name.text.trim();
      }
      _mode = value;
      _message = '';
      _failure = false;
      _password.clear();
      _confirm.clear();
      _code.clear();
    });
  }

  void _startCountdown() {
    _cooldowns[cooldownKey] = DateTime.now().add(const Duration(seconds: 60));
    _timer ??= Timer.periodic(const Duration(seconds: 1), (timer) {
      _cooldowns.removeWhere((_, until) => until.isBefore(DateTime.now()));
      if (!mounted || _cooldowns.isEmpty) {
        timer.cancel();
        _timer = null;
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _sendCode() async {
    if (_busy || cooldown > 0) return;
    if (!validEmail(codeEmail)) {
      setState(() {
        _message = '发送验证码前请填写有效邮箱';
        _failure = true;
      });
      return;
    }
    final ticket = ++_generation, email = codeEmail, requestPurpose = purpose;
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      final body = {'email': email, 'purpose': requestPurpose};
      if (qq) {
        await _grant!.transport.request('POST', '/api/auth/email-code', body);
      } else {
        await (c.site as SiteDataService).request(
          c.settings.siteUrl,
          'POST',
          '/api/auth/email-code',
          body,
        );
      }
      if (!mounted || ticket != _generation) return;
      // Cooldown belongs to the mailbox and purpose that actually received it.
      _cooldowns['$requestPurpose:${email.toLowerCase()}'] = DateTime.now().add(
        const Duration(seconds: 60),
      );
      _startCountdown();
      setState(() {
        _message = '验证码已发送，请查看邮箱';
        _failure = false;
      });
    } catch (e) {
      if (mounted && ticket == _generation) {
        setState(() {
          _message = '$e';
          _failure = true;
        });
      }
    } finally {
      if (mounted && ticket == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _startQQ([String provider = 'qq']) async {
    if (_busy) return;
    final ticket = ++_generation, authorizingAccount = c.account?.id;
    setState(() {
      _busy = true;
      _message = '';
      _clearQQ();
      _provider = provider;
    });
    try {
      final grant =
          await (provider == 'github'
              ? widget.authorizeGitHub
              : widget.authorize)(
            context,
            c,
            redirect: redirect,
            bindCurrentAccount: c.account != null && !c.sessionExpired,
          );
      if (!mounted || ticket != _generation) {
        grant?.transport.dispose();
        return;
      }
      if (authorizingAccount != c.account?.id) {
        grant?.transport.dispose();
        throw const ApiFailure('账号已切换，请重新授权');
      }
      if (grant == null) return;
      if (grant.target.configuredSite.origin != _origin ||
          grant.transport.origin != grant.target.origin) {
        grant.transport.dispose();
        throw const ApiFailure('QQ 授权站点不匹配');
      }
      _grant = grant;
      if (grant.ticket.isEmpty) {
        await _finishQQ(grant, {'redirect': grant.redirect});
        return;
      }
      final response = await grant.transport.request(
        'GET',
        '/api/auth/oauth/$_provider/pending?ticket=${Uri.encodeQueryComponent(grant.ticket)}',
      );
      if (!mounted || ticket != _generation) return;
      setState(() {
        _qqProfile = mapOf(response['data']);
        _qqMode =
            _provider == 'github' || _qqProfile['requiresEmailBinding'] == true
            ? 'email'
            : _qqProfile['hasEmailMatch'] == true
            ? 'bind'
            : 'create';
        _qqName.text = textOf(
          _qqProfile,
          'suggestedUsername',
          textOf(_qqProfile, 'nickname'),
        );
        _email.text = textOf(_qqProfile, 'email');
        _name.text = _email.text;
      });
    } catch (e) {
      if (mounted && ticket == _generation) {
        setState(() {
          _message = '$e';
          _failure = true;
          _clearQQ();
        });
      }
    } finally {
      if (mounted && ticket == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _finishQQ(QQAuthGrant grant, Map response) async {
    final session = grant.transport.sessionCookie;
    if (session == null) throw const ApiFailure('QQ 授权未返回有效会话');
    if (grant.target.configuredSite.origin != _origin ||
        grant.transport.origin != grant.target.origin) {
      throw const ApiFailure('QQ 授权站点不匹配');
    }
    await c.acceptSiteSession(grant.target.configuredSite.toString(), session);
    await _claimInvite();
    if (mounted) {
      widget.onAuthenticated?.call();
      widget.onGo(
        sanitizeAuthRedirect(
          '${response['redirect'] ?? grant.redirect}',
          redirect,
        ),
      );
    }
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    final ticket = ++_generation;
    setState(() {
      _busy = true;
      _message = '';
      _failure = false;
    });
    try {
      if (qq) {
        final grant = _grant!;
        final body = <String, dynamic>{'ticket': grant.ticket};
        final path = '/api/auth/oauth/$_provider/$_qqMode';
        if (_qqMode == 'email') {
          body.addAll({
            'email': _email.text.trim(),
            'emailCode': _code.text.trim(),
            'username': _qqName.text.trim(),
            if (!githubExisting) 'newPassword': _password.text,
          });
        } else if (_qqMode == 'bind') {
          body.addAll({
            'username': _name.text.trim(),
            'password': _password.text,
            'emailCode': _code.text.trim(),
            'loginMethod': _bindMethod,
          });
        } else {
          body['username'] = _qqName.text.trim();
        }
        final response = await grant.transport.request('POST', path, body);
        if (!mounted || ticket != _generation) return;
        await _finishQQ(grant, mapOf(response['data']));
      } else {
        final body = switch (_mode) {
          'register' => {
            'username': _name.text.trim(),
            'email': _email.text.trim(),
            'emailCode': _code.text.trim(),
            'password': _password.text,
          },
          'reset' => {
            'email': _email.text.trim(),
            'emailCode': _code.text.trim(),
            'newPassword': _password.text,
            'redirect': redirect,
          },
          'code' => {
            'username': _name.text.trim(),
            'emailCode': _code.text.trim(),
            'loginMethod': 'code',
          },
          _ => {
            'username': _name.text.trim(),
            'password': _password.text,
            'loginMethod': 'password',
          },
        };
        await c.login(
          _name.text.trim(),
          _password.text,
          credentials: body,
          authPath: switch (_mode) {
            'register' => '/api/auth/register',
            'reset' => '/api/auth/password/reset',
            _ => '/api/auth/login',
          },
        );
        if (!mounted || ticket != _generation) return;
        await _claimInvite();
        if (mounted && ticket == _generation) {
          widget.onAuthenticated?.call();
          widget.onGo(redirect);
        }
      }
    } catch (e) {
      if (mounted && ticket == _generation) {
        setState(() {
          _message = '$e';
          _failure = true;
        });
      }
    } finally {
      if (mounted && ticket == _generation) setState(() => _busy = false);
    }
  }

  String _authPath(String path) => Uri(
    path: path,
    queryParameters: {
      'redirect': redirect,
      if (route.queryParameters['invite'] != null)
        'invite': route.queryParameters['invite']!,
    },
  ).toString();
  Widget _field(
    String key,
    TextEditingController field,
    String label, {
    String? Function(String?)? validator,
    bool secret = false,
    bool email = false,
    int? maxLength,
    List<String>? autofill,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: TextFormField(
      key: Key('auth-$key'),
      controller: field,
      enabled: !_busy,
      validator: (value) {
        final message = validator?.call(value);
        return message == null ? null : siteTranslate(context, message);
      },
      obscureText: secret && !_showPassword,
      maxLength: maxLength,
      autofillHints: autofill,
      onChanged: (_) => setState(() {}),
      keyboardType: email
          ? TextInputType.emailAddress
          : key == 'code'
          ? TextInputType.number
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: siteTranslate(context, label),
        suffixIcon: secret
            ? IconButton(
                tooltip: siteTranslate(
                  context,
                  _showPassword ? '隐藏密码' : '显示密码',
                ),
                onPressed: () => setState(() => _showPassword = !_showPassword),
                icon: Icon(
                  _showPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              )
            : null,
      ),
    ),
  );
  String? _required(String? value) =>
      (value ?? '').trim().isEmpty ? '请填写此项' : null;
  Widget _methods(String value, ValueChanged<String> change) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in {'password': '密码登录', 'code': '验证码登录'}.entries)
          ChoiceChip(
            label: SiteText(entry.value),
            selected: value == entry.key,
            onSelected: _busy ? null : (_) => change(entry.key),
          ),
      ],
    ),
  );
  List<Widget> _fields() => [
    if (qq && _qqMode.isEmpty) const LinearProgressIndicator(),
    if (qq && _qqProfile.isNotEmpty) ...[
      SiteAvatar(
        value: textOf(_qqProfile, 'avatar'),
        name: textOf(_qqProfile, 'nickname', 'QQ 用户'),
        site: _grant!.target.origin,
        size: 72,
      ),
      const SizedBox(height: 12),
      Text(
        textOf(_qqProfile, 'nickname', 'QQ 用户'),
        style: const TextStyle(fontSize: 22),
      ),
      const SizedBox(height: 16),
      SiteText(
        _qqMode == 'email'
            ? '$providerName 授权已完成。请验证邮箱；已注册邮箱绑定已有账号并保留其密码，新邮箱需设置密码。'
            : 'QQ 授权已完成。可以开通新账号，也可以验证并绑定已有站内账号。',
      ),
      const SizedBox(height: 20),
      if (_qqMode != 'email')
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in {'create': 'QQ 一键进入', 'bind': '绑定已有账号'}.entries)
              ChoiceChip(
                label: SiteText(entry.value),
                selected: _qqMode == entry.key,
                onSelected: _busy
                    ? null
                    : (_) => setState(() {
                        _qqMode = entry.key;
                        _password.clear();
                        _code.clear();
                        _message = '';
                      }),
              ),
          ],
        ),
      const SizedBox(height: 16),
    ],
    if (!qq && ['password', 'code'].contains(_mode))
      _methods(_mode, _changeMode),
    if (qq && _qqMode == 'bind')
      _methods(
        _bindMethod,
        (value) => setState(() {
          _bindMethod = value;
          _password.clear();
          _code.clear();
        }),
      ),
    if ((qq && _qqMode == 'bind') || (!qq && _mode != 'reset'))
      _field(
        'name',
        _name,
        (!qq && _mode == 'register')
            ? '用户名'
            : ((qq ? _bindMethod : _mode) == 'code' ? '邮箱' : '用户名 / 邮箱'),
        autofill: const [AutofillHints.username],
        validator: (value) {
          if ((!qq && _mode == 'code') || (qq && _bindMethod == 'code')) {
            return _emailValidation(value);
          }
          if (!qq &&
              _mode == 'register' &&
              ((value ?? '').trim().length > 32 ||
                  RegExp(r'[\x00-\x1f\x7f<>/\\]').hasMatch(value ?? ''))) {
            return '用户名格式无效或超过 32 位';
          }
          return _required(value);
        },
      ),
    if (qq && _qqMode == 'create')
      _field(
        'qq-name',
        _qqName,
        '站内登录用户名',
        maxLength: 24,
        validator: _required,
      ),
    if ((qq && _qqMode == 'email') ||
        (!qq && ['register', 'reset'].contains(_mode)))
      _field(
        'email',
        _email,
        '邮箱',
        email: true,
        autofill: const [AutofillHints.email],
        validator: _emailValidation,
      ),
    if (needsCode) ...[
      _field(
        'code',
        _code,
        '邮箱验证码',
        maxLength: 6,
        autofill: const [AutofillHints.oneTimeCode],
        validator: (value) => RegExp(r'^\d{6}$').hasMatch((value ?? '').trim())
            ? null
            : '请输入 6 位邮箱验证码',
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const Key('auth-send-code'),
          onPressed: _busy || cooldown > 0 ? null : _sendCode,
          child: SiteText(
            cooldown > 0
                ? siteTr(
                    context,
                    'nativeAuthResendSeconds',
                    fallback: '{count}s 后重发',
                    params: {'count': cooldown},
                  )
                : '发送验证码',
          ),
        ),
      ),
      const SizedBox(height: 16),
    ],
    if (needsPassword)
      _field(
        'password',
        _password,
        newPassword ? '新密码' : '密码',
        secret: true,
        autofill: [
          newPassword ? AutofillHints.newPassword : AutofillHints.password,
        ],
        validator: (value) {
          final text = value ?? '';
          if (newPassword && text.length < 8) {
            return '密码至少需要 8 位';
          }
          if (newPassword && (qq || _mode == 'reset') && text.length > 128) {
            return '密码需为 8-128 位';
          }
          return text.isEmpty ? '请输入密码' : null;
        },
      ),
    if (newPassword)
      _field(
        'confirm',
        _confirm,
        '确认密码',
        secret: true,
        autofill: const [AutofillHints.newPassword],
        validator: (value) =>
            value == _password.text && (value ?? '').isNotEmpty
            ? null
            : '两次输入的密码不一致',
      ),
  ];
  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    c.removeListener(_originChanged);
    _grant?.transport.dispose();
    for (final field in [_name, _email, _password, _confirm, _code, _qqName]) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NativeSiteShell(
    showChrome: false,
    controller: c,
    title: title,
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: NativeSiteSection(
          title: title,
          subtitle: qq
              ? '$providerName 授权与账号绑定'
              : _mode == 'register'
              ? '开始记录你的月下旅程'
              : '探索、记录、分享 · Tsukuyomi Gate',
          child: AutofillGroup(
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_message.isNotEmpty)
                    nativeSiteFeedback(context, _message, error: _failure),
                  ..._fields(),
                  FilledButton(
                    key: const Key('auth-submit'),
                    onPressed: _busy || (qq && _qqMode.isEmpty)
                        ? null
                        : _submit,
                    child: SiteText(
                      _busy
                          ? '正在处理…'
                          : qq
                          ? switch (_qqMode) {
                              'email' => '绑定邮箱并进入',
                              'bind' => '绑定并登录',
                              _ => '一键开通并进入',
                            }
                          : switch (_mode) {
                              'register' => '注册并进入',
                              'reset' => '重设密码并登录',
                              _ => '登录',
                            },
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      if (qq)
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _clearQQ();
                                  _message = '';
                                }),
                          child: const SiteText('返回普通登录'),
                        ),
                      if (!qq && _mode != 'reset')
                        TextButton(
                          onPressed: _busy ? null : () => _changeMode('reset'),
                          child: const SiteText('忘记密码'),
                        ),
                      if (!qq && _mode == 'reset')
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _changeMode('password'),
                          child: const SiteText('返回普通登录'),
                        ),
                      if (!qq)
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => widget.onGo(
                                  _authPath(
                                    _mode == 'register'
                                        ? '/login'
                                        : '/register',
                                  ),
                                ),
                          child: SiteText(
                            _mode == 'register' ? '已有账号，去登录' : '还没有账号，去注册',
                          ),
                        ),
                      TextButton(
                        onPressed: _busy ? null : () => widget.onGo('/hub'),
                        child: const SiteText('返回首页'),
                      ),
                    ],
                  ),
                  const Divider(height: 40),
                  OutlinedButton.icon(
                    key: const Key('auth-github'),
                    onPressed: _busy ? null : () => _startQQ('github'),
                    icon: const Icon(Icons.code),
                    label: const SiteText('GitHub 登录 / 授权'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    key: const Key('auth-qq'),
                    onPressed: _busy ? null : _startQQ,
                    icon: const Icon(Icons.account_circle_outlined),
                    label: const SiteText('QQ 登录 / 授权'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
