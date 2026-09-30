import '../../core/site_localization.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../room/room_controller.dart';
import 'site_widgets.dart';

String sanitizeAuthRedirect(String? value, [String fallback = '/hub']) {
  final raw = (value ?? '').trim();
  if (!raw.startsWith('/') ||
      raw.startsWith('//') ||
      RegExp(r'[\r\n\\]').hasMatch(raw)) {
    return fallback;
  }
  try {
    final uri = Uri.parse('https://tsukuyomi.local').resolve(raw);
    final pathname = uri.path.replaceAll(RegExp(r'/+$'), '');
    if (uri.host != 'tsukuyomi.local' ||
        ['', '/access', '/login', '/register'].contains(pathname)) {
      return fallback;
    }
    return '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}${uri.hasFragment ? '#${uri.fragment}' : ''}';
  } catch (_) {
    return fallback;
  }
}

class QQOAuthTarget {
  const QQOAuthTarget(this.start, this.configuredSite);
  final Uri start, configuredSite;
  String get origin => start.origin;
  static QQOAuthTarget fromSettings(
    String site,
    Map settings,
    String redirect,
  ) {
    final configured = endpointUri(site),
        raw = '${settings['qqOAuthStartUrl'] ?? ''}';
    final local = ['localhost', '127.0.0.1', '::1'].contains(configured.host);
    final endpoint = local
        ? configured.resolve('/api/auth/oauth/qq/start')
        : Uri.tryParse(raw);
    if (endpoint == null ||
        !endpoint.hasAuthority ||
        endpoint.userInfo.isNotEmpty ||
        (!local && endpoint.scheme != 'https') ||
        !['http', 'https'].contains(endpoint.scheme) ||
        endpoint.path != '/api/auth/oauth/qq/start') {
      throw const ApiFailure('QQ 授权入口配置无效');
    }
    return QQOAuthTarget(
      endpoint.replace(
        queryParameters: {'redirect': sanitizeAuthRedirect(redirect)},
        fragment: '',
      ),
      configured,
    );
  }

  bool permits(Uri uri) =>
      uri.userInfo.isEmpty &&
      (uri.scheme == 'https' ||
          (uri.scheme == 'http' &&
              start.scheme == 'http' &&
              uri.origin == origin)) &&
      (uri.origin == origin ||
          uri.origin == configuredSite.origin ||
          uri.host == 'qq.com' ||
          uri.host.endsWith('.qq.com'));
}

/// Ephemeral OAuth transport. Browser-binding cookies never enter the ordinary
/// SiteClient cookie jar, disk caches, or logs. Only the server-issued session
/// is passed to RoomController after /me verification at the configured site.
class QQOAuthHttp {
  QQOAuthHttp(this.origin, {http.Client? client})
    : _client = client ?? http.Client();
  final String origin;
  final http.Client _client;
  final _cookies = <String, String>{};
  static const cookieNames = {
    'tsukuyomi_session',
    '__Host-tsukuyomi_qq_oauth',
    'tsukuyomi_qq_oauth',
  };
  static const paths = {
    '/api/auth/oauth/qq/pending',
    '/api/auth/oauth/qq/email',
    '/api/auth/oauth/qq/bind',
    '/api/auth/oauth/qq/create',
    '/api/auth/email-code',
  };
  String? get sessionCookie => _cookies['tsukuyomi_session'] == null
      ? null
      : 'tsukuyomi_session=${_cookies['tsukuyomi_session']}';
  bool get hasBinding =>
      _cookies.keys.where((key) => key.endsWith('qq_oauth')).length == 1;
  void importCookies(Iterable<MapEntry<String, String>> cookies) {
    _cookies.clear();
    for (final cookie in cookies) {
      if (cookieNames.contains(cookie.key) &&
          RegExp(r'^[A-Za-z0-9._~\-]+$').hasMatch(cookie.value)) {
        _cookies[cookie.key] = cookie.value;
      }
    }
  }

  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = Uri.parse(origin).resolve(path);
    if (uri.origin != origin ||
        !paths.contains(uri.path) ||
        !['GET', 'POST'].contains(method)) {
      throw const ApiFailure('授权接口地址无效');
    }
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll({
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Origin': origin,
        'X-Requested-With': 'XMLHttpRequest',
        'Cache-Control': 'no-cache',
        'Cookie': _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      });
    if (body != null) request.body = jsonEncode(body);
    try {
      final response = await (() async {
        final stream = await _client.send(request), bytes = <int>[];
        await for (final chunk in stream.stream) {
          bytes.addAll(chunk);
          if (bytes.length > 1024 * 1024) throw const ApiFailure('授权响应过大');
        }
        return http.Response.bytes(
          bytes,
          stream.statusCode,
          headers: stream.headers,
        );
      })().timeout(const Duration(seconds: 25));
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is! Map ||
          response.statusCode >= 300 ||
          value['success'] != true) {
        throw ApiFailure(
          value is Map ? '${value['message'] ?? 'QQ 授权请求失败'}' : 'QQ 授权响应异常',
          status: response.statusCode,
        );
      }
      final setCookie = response.headers['set-cookie'] ?? '';
      for (final match in RegExp(
        r'(?:^|,\s*)(tsukuyomi_session|__Host-tsukuyomi_qq_oauth|tsukuyomi_qq_oauth)=([^;,\s]*)',
      ).allMatches(setCookie)) {
        final name = match[1]!, value = match[2]!;
        if (value.isEmpty) {
          _cookies.remove(name);
        } else if (RegExp(r'^[A-Za-z0-9._~\-]+$').hasMatch(value)) {
          _cookies[name] = value;
        }
      }
      return Map<String, dynamic>.from(value);
    } on TimeoutException {
      throw const ApiFailure('QQ 授权连接超时，请重试');
    } on FormatException {
      throw const ApiFailure('QQ 授权响应异常');
    } on http.ClientException {
      throw const ApiFailure('QQ 授权网络连接失败');
    }
  }

  void dispose() {
    _cookies.clear();
    _client.close();
  }
}

class QQAuthGrant {
  const QQAuthGrant({
    required this.target,
    required this.transport,
    this.ticket = '',
    this.redirect = '/hub',
  });
  final QQOAuthTarget target;
  final QQOAuthHttp transport;
  final String ticket, redirect;
}

const qqOAuthErrors = {
  'qq_not_configured': 'QQ 登录暂未配置，请稍后再试',
  'qq_start_failed': 'QQ 登录启动失败，请稍后再试',
  'qq_denied': 'QQ 授权已取消',
  'qq_missing_code': 'QQ 回调缺少授权码，请重新登录',
  'qq_invalid_state': 'QQ 登录状态已过期，请重新授权',
  'qq_callback_failed': 'QQ 回调处理失败，请稍后再试',
};

Future<QQAuthGrant?> showQQAuthorization(
  BuildContext context,
  RoomController controller, {
  String redirect = '/hub',
  bool bindCurrentAccount = false,
}) async {
  if (kIsWeb ||
      ![
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ].contains(defaultTargetPlatform)) {
    throw const ApiFailure('当前平台没有支持 QQ 浏览器绑定 Cookie 的授权容器，请使用密码或邮箱验证码登录');
  }
  final site = controller.settings.siteUrl, account = controller.account?.id;
  final response = await (controller.site as SiteDataService).request(
    site,
    'GET',
    '/api/settings',
  );
  final target = QQOAuthTarget.fromSettings(
    site,
    mapOf(response['data']),
    redirect,
  );
  if (endpointUri(controller.settings.siteUrl).origin !=
          target.configuredSite.origin ||
      account != controller.account?.id) {
    throw const ApiFailure('账号或站点已切换，请重新授权');
  }
  if (bindCurrentAccount && target.origin != target.configuredSite.origin) {
    throw const ApiFailure('绑定 QQ 需要当前站点与授权入口同源；请在授权入口对应站点登录后绑定');
  }
  if (!context.mounted) return null;
  final grant = await showDialog<QQAuthGrant>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _QQBrowser(
      controller: controller,
      target: target,
      redirect: sanitizeAuthRedirect(redirect),
      seedSession: bindCurrentAccount ? controller.site.cookie : null,
    ),
  );
  if (endpointUri(controller.settings.siteUrl).origin !=
          target.configuredSite.origin ||
      account != controller.account?.id) {
    grant?.transport.dispose();
    throw const ApiFailure('账号或站点已切换，请重新授权');
  }
  return grant;
}

class _QQBrowser extends StatefulWidget {
  const _QQBrowser({
    required this.controller,
    required this.target,
    required this.redirect,
    this.seedSession,
  });
  final RoomController controller;
  final QQOAuthTarget target;
  final String redirect;
  final String? seedSession;
  @override
  State<_QQBrowser> createState() => _QQBrowserState();
}

class _QQBrowserState extends State<_QQBrowser> {
  CookieManager? _cookies;
  WebViewEnvironment? _environment;
  Directory? _temporary;
  InAppWebViewController? _browser;
  String _error = '';
  int _progress = 0;
  bool _ready = false, _finishing = false;
  Future<void>? _preparation;
  @override
  void initState() {
    super.initState();
    _preparation = _prepare();
  }

  Future<void> _clearOAuthCookies(CookieManager manager) async {
    final url = WebUri('${widget.target.origin}/');
    final cookies = await manager.getCookies(url: url);
    for (final cookie in cookies.where(
      (cookie) =>
          QQOAuthHttp.cookieNames.contains(cookie.name) ||
          cookie.name == 'tsukuyomi_admin_session',
    )) {
      await manager.deleteCookie(
        url: url,
        name: cookie.name,
        path: cookie.path ?? '/',
        domain: cookie.domain,
      );
    }
  }

  Future<void> _prepare() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.windows &&
          _environment == null) {
        _temporary = await Directory.systemTemp.createTemp('tsukuyomi-qq-');
        _environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: _temporary!.path,
          ),
        );
      }
      final manager = CookieManager.instance(webViewEnvironment: _environment);
      _cookies = manager;
      final url = WebUri('${widget.target.origin}/');
      await _clearOAuthCookies(manager);
      if (!mounted) return;
      final match = RegExp(r'(?:^|;\s*)tsukuyomi_session=([A-Za-z0-9._~\-]+)')
          .firstMatch(widget.seedSession ?? '');
      if (match != null &&
          widget.target.origin == widget.target.configuredSite.origin) {
        await manager.setCookie(
          url: url,
          name: 'tsukuyomi_session',
          value: match[1]!,
          isHttpOnly: true,
          isSecure: widget.target.start.scheme == 'https',
          sameSite: HTTPCookieSameSitePolicy.LAX,
        );
      }
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '无法创建 QQ 授权窗口：$e');
    }
  }

  Future<void> _check(WebUri? webUri) async {
    if (_finishing || webUri == null || !mounted) return;
    final uri = Uri.tryParse(webUri.toString());
    if (uri == null) return;
    if (uri.origin != widget.target.origin &&
        uri.origin != widget.target.configuredSite.origin) {
      return;
    }
    final error = uri.queryParameters['oauth_error'];
    if (uri.path == '/login' && error != null) {
      setState(() => _error = qqOAuthErrors[error] ?? 'QQ 登录失败，请重试');
      return;
    }
    final ticket = uri.path == '/login' && uri.queryParameters['oauth'] == 'qq'
        ? uri.queryParameters['ticket'] ?? ''
        : '';
    final expected = Uri.parse(widget.redirect);
    if (ticket.isEmpty && uri.path != expected.path) return;
    if (ticket.isNotEmpty &&
        (uri.origin != widget.target.origin ||
            !RegExp(r'^[a-f0-9]{48}$').hasMatch(ticket))) {
      setState(() => _error = 'QQ 授权站点或票据不匹配，请重新授权');
      return;
    }
    _finishing = true;
    QQOAuthHttp? transport;
    try {
      final cookies = await _cookies!.getCookies(
        url: WebUri('${widget.target.origin}/'),
      );
      transport = QQOAuthHttp(widget.target.origin)
        ..importCookies(cookies.map((c) => MapEntry(c.name, c.value)));
      if (ticket.isNotEmpty && !transport.hasBinding) {
        throw const ApiFailure('授权浏览器绑定已丢失，请重新授权');
      }
      if (ticket.isEmpty && transport.sessionCookie == null) {
        transport.dispose();
        _finishing = false;
        return;
      }
      if (!mounted) {
        transport.dispose();
        return;
      }
      Navigator.pop(
        context,
        QQAuthGrant(
          target: widget.target,
          transport: transport,
          ticket: ticket,
          redirect: widget.redirect,
        ),
      );
    } catch (e) {
      transport?.dispose();
      if (mounted) {
        setState(() {
          _error = '$e';
          _finishing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    unawaited(_releaseBrowser());
    super.dispose();
  }

  Future<void> _releaseBrowser() async {
    // HttpOnly OAuth cookies require CookieManager's native cookie store. The
    // incognito WebKit store is different, so clear these scoped cookies when
    // the grant is copied or canceled rather than leaving a browser session.
    try {
      await _preparation;
      if (_cookies != null) await _clearOAuthCookies(_cookies!);
    } catch (_) {
      /* A closed platform view may already have removed its cookie store. */
    } finally {
      try {
        await _environment?.dispose();
      } catch (_) {}
      final directory = _temporary;
      if (directory != null) {
        try {
          await directory.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(12),
    child: SizedBox(
      width: 960,
      height: MediaQuery.sizeOf(context).height * .88,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Expanded(child: SiteText('QQ 授权 · 完成后返回原生应用')),
                IconButton(
                  tooltip: '取消授权',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          if (_progress < 100)
            LinearProgressIndicator(value: _ready ? _progress / 100 : null),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Text(_error),
                  TextButton(
                    onPressed: () {
                      setState(() => _error = '');
                      if (_browser != null) {
                        _browser!.loadUrl(
                          urlRequest: URLRequest(
                            url: WebUri(widget.target.start.toString()),
                          ),
                        );
                      } else {
                        _preparation = _prepare();
                      }
                    },
                    child: const SiteText('重新授权'),
                  ),
                ],
              ),
            ),
          if (_ready)
            Expanded(
              child: InAppWebView(
                webViewEnvironment: _environment,
                initialUrlRequest: URLRequest(
                  url: WebUri(widget.target.start.toString()),
                ),
                initialSettings: InAppWebViewSettings(
                  useShouldOverrideUrlLoading: true,
                  javaScriptEnabled: true,
                  javaScriptCanOpenWindowsAutomatically: true,
                  supportMultipleWindows: true,
                  thirdPartyCookiesEnabled: true,
                ),
                onWebViewCreated: (view) => _browser = view,
                onProgressChanged: (_, progress) {
                  if (mounted) setState(() => _progress = progress);
                },
                onLoadStop: (_, url) => _check(url),
                onUpdateVisitedHistory: (_, url, _) => _check(url),
                shouldOverrideUrlLoading: (_, action) async {
                  final uri = Uri.tryParse(
                    action.request.url?.toString() ?? '',
                  );
                  return uri != null && widget.target.permits(uri)
                      ? NavigationActionPolicy.ALLOW
                      : NavigationActionPolicy.CANCEL;
                },
                onCreateWindow: (view, action) async {
                  final url = action.request.url,
                      uri = Uri.tryParse(url?.toString() ?? '');
                  if (url == null ||
                      uri == null ||
                      !widget.target.permits(uri)) {
                    return false;
                  }
                  await view.loadUrl(urlRequest: URLRequest(url: url));
                  return true;
                },
                onReceivedError: (_, request, error) {
                  if (request.isForMainFrame == true && mounted) {
                    setState(() => _error = 'QQ 授权页面加载失败：${error.description}');
                  }
                },
              ),
            )
          else
            const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      ),
    ),
  );
}
