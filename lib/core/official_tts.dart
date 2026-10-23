import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'site_client.dart';

const officialTtsPreview = 'こんにちは。今夜も、月がきれいですね。';

/// The main site's fixed-price voice jobs. Supplier configuration stays on
/// the server; only text and a stable request key are submitted by this client.
class OfficialTtsClient {
  OfficialTtsClient({
    SiteService? site,
    http.Client Function()? clientFactory,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
    this.pollTimeout = const Duration(seconds: 110),
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _now = now ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed {
    this.site = site;
  }

  SiteService? _site;
  final http.Client Function() _clientFactory;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;
  final Duration pollTimeout;
  // The Room player and settings audition share one site's session cache.
  // Expando does not retain a disposed site transport or persist private text.
  static final _caches = Expando<_VoiceCache>();
  http.Client? _active;
  Completer<void>? _cancelled;
  int _generation = 0;

  set site(SiteService? value) {
    if (identical(value, _site)) return;
    cancel();
    _site = value;
  }

  void cancel() {
    _generation++;
    _active?.close();
    _active = null;
    if (_cancelled?.isCompleted == false) _cancelled!.complete();
    _cancelled = null;
    // Stopping playback cannot cancel or refund a server-side job. Retain its
    // key and prepared text so the next explicit click can recover that job.
  }

  Future<Map<String, dynamic>> status(String siteUrl) async {
    final client = _clientFactory();
    try {
      return await _json(
        client,
        endpointUri(siteUrl).resolve('/api/tts/official/status'),
      );
    } finally {
      client.close();
    }
  }

  String _owner(SiteService site, String origin) => sha256
      .convert(
        utf8.encode(
          '$origin|${identityHashCode(site)}|${site.cookie}|'
          '${site is SiteClient ? site.sessionRevision : 0}',
        ),
      )
      .toString();

  Future<Uint8List> synthesize(
    RoomSettings settings,
    String text, {
    Future<String> Function(String text, String language)? prepareText,
  }) async {
    cancel();
    final generation = _generation, site = _site;
    final base = endpointUri(settings.siteUrl);
    final account = settings.option('officialTtsAccount');
    if (site == null || site.cookie == null || account.isEmpty) {
      throw const ApiFailure('请登录后重新保存官方语音设置', status: 401);
    }
    if (settings.option('officialTtsOrigin') != base.origin) {
      throw const ApiFailure('站点已变化，请重新保存官方语音设置', status: 409);
    }
    if (text.trim().isEmpty || text.runes.length > 1000) {
      throw const ApiFailure('官方语音每条最多 1,000 字，请缩短文本');
    }
    final owner = _owner(site, base.origin);
    void check() {
      if (generation != _generation) throw const ApiFailure('语音已停止');
      if (!identical(site, _site) || owner != _owner(site, base.origin)) {
        throw const ApiFailure('登录账号已变化，请重新保存官方语音设置', status: 409);
      }
    }

    final verified = await site.me(settings.siteUrl);
    check();
    if (verified.id != account || verified.scope == 'admin') {
      throw const ApiFailure('登录账号已变化，请重新保存官方语音设置', status: 409);
    }
    final cache = _caches[site] ??= _VoiceCache();
    if (cache.owner != owner) {
      cache.records.clear();
      cache.owner = owner;
    }
    final records = cache.records;
    final fingerprint = sha256
        .convert(utf8.encode('$account\n$text'))
        .toString();
    var saved = records[fingerprint];
    if (saved == null ||
        _now().difference(saved.created) >= const Duration(hours: 24)) {
      saved = _VoiceRequest(newTurnId(), _now());
      records[fingerprint] = saved;
      if (records.length > 100) records.remove(records.keys.first);
    }
    final record = saved;
    final client = _clientFactory();
    final cancelled = Completer<void>();
    _active = client;
    _cancelled = cancelled;
    final headers = <String, String>{
      'Cookie': site.cookie!,
      'X-TTS-Account': account,
    };
    Future<Map<String, dynamic>> json(
      String path, {
      Map<String, dynamic>? body,
    }) async {
      check();
      final data = await _json(
        client,
        base.resolve('/api/tts/official$path'),
        headers: headers,
        body: body,
      );
      check();
      return data;
    }

    try {
      Map<String, dynamic> job;
      if (record.jobId != null) {
        job = await json('/jobs/${record.jobId}');
      } else {
        final status = await json('/status');
        if (status['online'] != true) {
          throw const ApiFailure('官方语音算力离线，未发起翻译或合成，请稍后重试');
        }
        final language = '${status['language'] ?? 'ja'}';
        if (record.prepared == null) {
          final preparing = record.preparing ??= Future.sync(
            () => prepareText == null ? text : prepareText(text, language),
          );
          try {
            record.prepared = await preparing;
          } catch (_) {
            if (identical(preparing, record.preparing)) record.preparing = null;
            rethrow;
          }
        }
        check();
        final prepared = record.prepared!;
        final max = status['maxCharacters'] is int
            ? status['maxCharacters'] as int
            : 1000;
        if (prepared.trim().isEmpty ||
            prepared.runes.length > max ||
            prepared.runes.length > 1000) {
          throw const ApiFailure('翻译后的语音文本为空或超过 1,000 字，未发起合成');
        }
        job = await json(
          '/jobs',
          body: {'text': prepared, 'requestKey': record.key},
        );
      }
      final deadline = _now().add(pollTimeout);
      while (true) {
        final id = job['id'];
        if (id is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
            (record.jobId != null && record.jobId != id)) {
          throw const ApiFailure('官方语音任务信息异常，请稍后重试');
        }
        record.jobId = id;
        final state = job['state'];
        if (state == 'ready') break;
        if (state == 'failed' || state == 'expired') {
          records.remove(fingerprint);
          throw ApiFailure(
            state == 'expired'
                ? '这条语音的缓存已过期；再次点击将重新生成并按新的一条计费'
                : '${job['message'] ?? '语音未能合成，预留金额已退回'}',
          );
        }
        if (state != 'processing') throw const ApiFailure('官方语音任务状态异常，请稍后重试');
        if (!_now().isBefore(deadline)) {
          throw const ApiFailure('语音仍在处理中，请稍后再次点击，同一请求不会重复扣费');
        }
        await Future.any([
          _delay(const Duration(seconds: 2)),
          cancelled.future,
        ]);
        check();
        job = await json('/jobs/$id');
      }
      check();
      final response = await _response(
        client,
        base.resolve('/api/tts/official/jobs/${record.jobId}/audio'),
        headers: headers,
        audio: true,
      );
      check();
      if (response.statusCode == 410) records.remove(fingerprint);
      _checkResponse(response);
      if (!(response.headers['content-type'] ?? '').toLowerCase().startsWith(
        'audio/',
      )) {
        throw const ApiFailure('官方语音未返回音频，请重试；有效缓存不会重复扣费');
      }
      return response.bodyBytes;
    } on TimeoutException {
      throw const ApiFailure('官方语音响应超时，请重试；同一请求不会重复扣费');
    } on http.ClientException {
      check();
      throw const ApiFailure('无法连接官方语音，请重试；同一请求不会重复扣费');
    } finally {
      client.close();
      if (identical(client, _active)) _active = null;
      if (!cancelled.isCompleted) cancelled.complete();
      if (identical(cancelled, _cancelled)) _cancelled = null;
    }
  }

  Future<List<Map<String, dynamic>>> history(
    String siteUrl,
    String account,
  ) async {
    cancel();
    final generation = _generation;
    final site = _site, base = endpointUri(siteUrl);
    if (site == null || site.cookie == null || account.isEmpty) {
      throw const ApiFailure('请登录后查看官方语音账单', status: 401);
    }
    final owner = _owner(site, base.origin);
    final verified = await site.me(siteUrl);
    if (verified.id != account ||
        verified.scope == 'admin' ||
        generation != _generation ||
        owner != _owner(site, base.origin)) {
      throw const ApiFailure('账号已切换，请刷新语音记录', status: 409);
    }
    final client = _clientFactory();
    _active = client;
    try {
      final response = await _response(
        client,
        base.resolve('/api/tts/official/jobs'),
        headers: {'Cookie': site.cookie!, 'X-TTS-Account': account},
      );
      if (generation != _generation ||
          owner != _owner(site, base.origin) ||
          !identical(site, _site)) {
        throw const ApiFailure('账号已切换，请刷新语音记录', status: 409);
      }
      _checkResponse(response);
      final body = _decode(response);
      if (body['success'] != true || body['data'] is! List) {
        throw const ApiFailure('官方语音账单响应异常');
      }
      return (body['data'] as List)
          .whereType<Map>()
          .take(30)
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
    } finally {
      client.close();
      if (identical(client, _active)) _active = null;
    }
  }

  Future<Map<String, dynamic>> _json(
    http.Client client,
    Uri uri, {
    Map<String, String> headers = const {},
    Map<String, dynamic>? body,
  }) async {
    final response = await _response(client, uri, headers: headers, body: body);
    _checkResponse(response);
    final decoded = _decode(response);
    if (decoded['success'] != true || decoded['data'] is! Map) {
      throw const ApiFailure('官方语音响应异常，请稍后重试');
    }
    return Map<String, dynamic>.from(decoded['data'] as Map);
  }

  Future<http.Response> _response(
    http.Client client,
    Uri uri, {
    Map<String, String> headers = const {},
    Map<String, dynamic>? body,
    bool audio = false,
  }) async {
    final request = http.Request(body == null ? 'GET' : 'POST', uri)
      ..followRedirects = false
      ..headers.addAll({
        'Accept': audio ? 'audio/*' : 'application/json',
        'Content-Type': 'application/json',
        'Origin': uri.origin,
        'X-Requested-With': 'XMLHttpRequest',
        'Cache-Control': 'no-store',
        ...headers,
      });
    if (body != null) request.body = jsonEncode(body);
    return (() async {
      final response = await client.send(request);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length >
            (audio ? 24 * 1024 * 1024 : 256 * 1024)) {
          throw const ApiFailure('官方语音响应过大，请缩短文本或稍后重试');
        }
        bytes.add(chunk);
      }
      return http.Response.bytes(
        bytes.takeBytes(),
        response.statusCode,
        headers: response.headers,
      );
    })().timeout(Duration(seconds: audio ? 30 : 15));
  }

  Map<String, dynamic> _decode(http.Response response) {
    try {
      return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
    } catch (_) {
      throw const ApiFailure('官方语音响应异常，请稍后重试');
    }
  }

  void _checkResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode == 401) {
      throw const ApiFailure('登录已过期，请重新登录后使用官方语音', status: 401);
    }
    if (response.statusCode == 402) {
      throw const ApiFailure('余额不足，请前往支付中心充值，未扣费', status: 402);
    }
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw const ApiFailure('官方语音不允许跳转到其他地址');
    }
    String? message;
    try {
      message = _decode(response)['message'] as String?;
    } catch (_) {}
    throw ApiFailure(
      message?.isNotEmpty == true ? message! : '官方语音暂不可用，请稍后重试',
      status: response.statusCode,
    );
  }
}

class _VoiceRequest {
  _VoiceRequest(this.key, this.created);
  final String key;
  final DateTime created;
  String? prepared, jobId;
  Future<String>? preparing;
}

class _VoiceCache {
  String owner = '';
  final records = <String, _VoiceRequest>{};
}
