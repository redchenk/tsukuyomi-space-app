import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../room/room_controller.dart';
import 'qq_auth.dart';

/// Google authorizes in the system browser. A one-time device grant transfers
/// only the site session after explicit browser confirmation, never Google tokens.
Future<QQAuthGrant?> showGoogleAuthorization(
  BuildContext context,
  RoomController controller, {
  String redirect = '/hub',
  bool bindCurrentAccount = false,
}) async {
  final owner = controller.scope;
  final grant = await showDialog<QQAuthGrant>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _GoogleLogin(controller, bindCurrentAccount),
  );
  if (owner != controller.scope) {
    grant?.transport.dispose();
    throw const ApiFailure('账号已切换，请重新登录');
  }
  return grant;
}

Future<bool> showNativeGoogleBinding(
  BuildContext context,
  RoomController controller,
) async {
  final account = controller.account?.id, owner = controller.scope;
  final grant = await showGoogleAuthorization(
    context,
    controller,
    bindCurrentAccount: true,
  );
  if (grant == null) return false;
  final verifier = SiteClient()
    ..setSessionCookie(
      grant.target.configuredSite.toString(),
      grant.transport.sessionCookie,
    );
  try {
    final user = await verifier.me(grant.target.configuredSite.toString());
    if (user.id != account || controller.scope != owner) {
      throw const ApiFailure('绑定账号不匹配');
    }
    await controller.acceptSiteSession(
      grant.target.configuredSite.toString(),
      grant.transport.sessionCookie!,
    );
    if (controller.account?.id != account) throw const ApiFailure('绑定账号不匹配');
    return true;
  } finally {
    verifier.dispose();
    grant.transport.dispose();
  }
}

class _GoogleLogin extends StatefulWidget {
  const _GoogleLogin(this.controller, this.bind);
  final RoomController controller;
  final bool bind;
  @override
  State<_GoogleLogin> createState() => _GoogleLoginState();
}

class _GoogleLoginState extends State<_GoogleLogin> {
  final client = http.Client();
  late final site = endpointUri(widget.controller.settings.siteUrl);
  late final owner = widget.controller.scope;
  late final secret = List.generate(
    32,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  String id = '', code = '', error = '';
  Uri? authorize;
  Timer? timer;
  bool polling = false, completed = false;
  DateTime? deadline;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _start();
  }

  void _changed() {
    if (widget.controller.scope != owner && mounted) Navigator.pop(context);
  }

  Future<http.Response> _request(String path, Map<String, dynamic> body) async {
    final req = http.Request('POST', site.resolve('/api/auth/native/$path'))
      ..followRedirects = false
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Origin': site.origin,
        'X-Requested-With': 'XMLHttpRequest',
        if (widget.bind &&
            path == 'start' &&
            widget.controller.site.cookie != null)
          'Cookie': widget.controller.site.cookie!,
      })
      ..body = jsonEncode(body);
    final response = await client
        .send(req)
        .timeout(const Duration(seconds: 15));
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > 65536) throw const ApiFailure('登录响应无效');
    }
    return http.Response.bytes(
      bytes,
      response.statusCode,
      headers: response.headers,
    );
  }

  Map<String, dynamic> _data(http.Response response) {
    if (response.statusCode == 404) {
      throw const ApiFailure('当前站点尚未更新 App 浏览器登录接口，请使用密码或邮箱登录');
    }
    final data = jsonDecode(response.body);
    if (response.statusCode != 200 ||
        data is! Map ||
        data['success'] != true ||
        data['data'] is! Map) {
      throw ApiFailure(
        data is Map ? '${data['message'] ?? '登录请求失败'}' : '登录响应无效',
      );
    }
    return Map<String, dynamic>.from(data['data']);
  }

  Future<void> _start() async {
    try {
      final data = _data(
        await _request('start', {
          'provider': 'google',
          'secret': secret,
          'action': widget.bind ? 'bind' : 'login',
        }),
      );
      if (!mounted || owner != widget.controller.scope) return;
      final path = '${data['authorizePath'] ?? ''}', uri = site.resolve(path);
      if (!RegExp(r'^[a-f0-9]{48}$').hasMatch('${data['id']}') ||
          !RegExp(r'^\d{6}$').hasMatch('${data['code']}') ||
          uri.origin != site.origin ||
          uri.path != '/api/auth/oauth/google/start' ||
          !path.startsWith('/api/')) {
        throw const ApiFailure('登录入口校验失败');
      }
      setState(() {
        id = data['id'];
        code = data['code'];
        authorize = uri;
      });
      deadline = DateTime.now().add(const Duration(minutes: 5));
      timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw const ApiFailure('无法打开系统浏览器，请点击重试');
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e is ApiFailure ? e.message : '无法开始 Google 登录');
      }
    }
  }

  Future<void> _poll() async {
    if (polling || completed || !mounted) return;
    if (owner != widget.controller.scope || DateTime.now().isAfter(deadline!)) {
      timer?.cancel();
      setState(() => error = '登录已过期，请关闭后重新开始');
      return;
    }
    polling = true;
    try {
      final response = await _request('poll', {'id': id, 'secret': secret}),
          data = _data(response);
      if (!mounted || owner != widget.controller.scope) return;
      if (data['status'] != 'complete') return;
      final match = RegExp(r'(?:^|,\s*)tsukuyomi_session=([A-Za-z0-9._~-]+)')
          .firstMatch(response.headers['set-cookie'] ?? '');
      if (match == null) throw const ApiFailure('站点没有返回登录会话');
      if (widget.bind &&
          '${data['user']?['id']}' != widget.controller.account?.id) {
        throw const ApiFailure('绑定账号不匹配');
      }
      completed = true;
      timer?.cancel();
      final transport = QQOAuthHttp(site.origin, provider: 'google')
        ..importCookies([MapEntry('tsukuyomi_session', match[1]!)]);
      Navigator.pop(
        context,
        QQAuthGrant(
          target: QQOAuthTarget(
            site.resolve('/api/auth/oauth/google/start'),
            site,
            provider: 'google',
          ),
          transport: transport,
          ticket: '',
          redirect: '/hub',
        ),
      );
    } catch (e) {
      if (mounted) {
        timer?.cancel();
        setState(() => error = e is ApiFailure ? e.message : '登录确认失败，请重新开始');
      }
    } finally {
      polling = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.controller.removeListener(_changed);
    if (!completed && id.isNotEmpty) {
      unawaited(
        _request('poll', {
          'id': id,
          'secret': secret,
          'cancel': true,
        }).catchError((_) => http.Response('', 499)).whenComplete(client.close),
      );
    } else {
      client.close();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Google 登录'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (code.isEmpty && error.isEmpty) const LinearProgressIndicator(),
        if (code.isNotEmpty) ...[
          const Text('请在系统浏览器完成 Google 登录，并核对确认码：'),
          const SizedBox(height: 16),
          SelectableText(
            code,
            style: const TextStyle(fontSize: 30, letterSpacing: 6),
          ),
          const SizedBox(height: 16),
          const Text('浏览器确认后将自动返回 App 登录状态。'),
        ],
        if (error.isNotEmpty) Text(error),
      ],
    ),
    actions: [
      if (authorize != null)
        TextButton(
          onPressed: () =>
              launchUrl(authorize!, mode: LaunchMode.externalApplication),
          child: const Text('打开浏览器'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
