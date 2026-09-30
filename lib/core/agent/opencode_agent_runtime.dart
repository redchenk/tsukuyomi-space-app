import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

import '../models.dart';
import 'agent_types.dart';
import 'agent_tools.dart';
import 'agent_binaries.dart';
import 'agent_bridge.dart';
import 'agent_provider.dart';

class OpenCodeAgentRuntime implements AgentRuntime {
  OpenCodeAgentRuntime(
    this.binaries,
    this.gateway,
    this.settings, {
    http.Client Function()? clientFactory,
    String? dataDirectory,
  }) : _factory = clientFactory ?? http.Client.new,
       dataDirectory = dataDirectory ?? _defaultDataDirectory();
  final AgentBinaries binaries;
  final ToolGateway gateway;
  final RoomSettings settings;
  final http.Client Function() _factory;
  final String dataDirectory;
  Process? _process;
  Directory? _private;
  AgentBridge? _bridge;
  http.Client? _client, _eventsClient;
  Uri? _uri;
  String _password = '', _stderr = '';
  int? _exitCode;
  AgentSession? _session;
  bool _cancelled = false, _disposed = false;
  static String _defaultDataDirectory() {
    final home =
        Platform.environment[Platform.isWindows ? 'LOCALAPPDATA' : 'HOME'] ??
        Directory.systemTemp.path;
    return '$home${Platform.isMacOS
        ? '/Library/Application Support'
        : Platform.isWindows
        ? ''
        : '/.local/share'}/tsukuyomi-space/agent';
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Authorization':
        'Basic ${base64Encode(utf8.encode('opencode:$_password'))}',
  };

  Future<dynamic> _request(String method, String path, [dynamic body]) async {
    final req = http.Request(method, _uri!.resolve(path))
      ..followRedirects = false
      ..headers.addAll(_headers);
    if (body != null) req.body = jsonEncode(body);
    final response = await _client!
        .send(req)
        .timeout(const Duration(seconds: 30));
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > 2 * 1024 * 1024) {
        throw const ApiFailure('Agent 服务返回内容过大');
      }
    }
    if (response.statusCode >= 300) {
      throw ApiFailure('Agent 服务请求失败：${response.statusCode}');
    }
    return bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
  }

  @override
  Future<void> start(AgentSession session) async {
    if (_disposed) throw const ApiFailure('Agent 已关闭');
    _session = session;
    if (_process == null) await _boot(session);
    if (session.nativeId != null) {
      try {
        await _request('GET', '/session/${session.nativeId!}');
        return;
      } catch (_) {}
    }
    final recovering = session.nativeId != null;
    final result = await _request('POST', '/session', {'title': 'Room Agent'});
    session.nativeId = result['id'] as String;
    if (recovering) {
      var transcript = session.events
          .where((event) => event.type == 'user' || event.type == 'assistant')
          .map((event) => '${event.type}: ${event.text}')
          .join('\n');
      if (transcript.length > 24000) {
        transcript = transcript.substring(transcript.length - 24000);
      }
      if (transcript.isNotEmpty) {
        // noReply stores context only: it never calls the model or tools.
        await _request('POST', '/session/${session.nativeId}/message', {
          'noReply': true,
          'parts': [
            {
              'type': 'text',
              'text':
                  'Recovered conversation context. Previously completed operations must never be replayed.\n$transcript',
            },
          ],
        });
      }
    }
  }

  @override
  Future<void> resume(AgentSession session) => start(session);

  Future<void> _boot(AgentSession session) async {
    _private = await Directory.systemTemp.createTemp('tsukuyomi-opencode-');
    final bridge = AgentBridge(gateway, AgentProviderBridge(settings));
    _bridge = bridge;
    await bridge.start();
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    _uri = Uri.parse('http://127.0.0.1:$port');
    _password = List.generate(
      32,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final scopedData =
        '$dataDirectory/${sha256.convert(utf8.encode('${session.owner}:${session.workspace}'))}';
    final config = {
      'autoupdate': false,
      'share': 'disabled',
      'snapshot': false,
      'plugin': [],
      'instructions': <String>[],
      'enabled_providers': ['tsukuyomi'],
      'model': 'tsukuyomi/room',
      'provider': {
        'tsukuyomi': {
          'npm': '@ai-sdk/openai-compatible',
          'name': 'Room',
          'options': {
            'baseURL': bridge.uri.resolve('/model/v1').toString(),
            'apiKey': bridge.token,
          },
          'models': {
            'room': {
              'name': settings.model,
              'limit': {'context': 32768, 'output': 8192},
            },
          },
        },
      },
      'permission': {'*': 'deny', 'tsukuyomi_*': 'allow'},
      'tools': {
        for (final name in [
          'bash',
          'read',
          'write',
          'edit',
          'glob',
          'grep',
          'webfetch',
          'task',
          'question',
          'todowrite',
          'todoread',
          'apply_patch',
          'codesearch',
          'websearch',
          'list',
        ])
          name: false,
      },
      'agent': {
        'room': {
          'mode': 'primary',
          'description': 'Native Room Agent',
          'steps': 20,
          'prompt':
              'Use only tsukuyomi MCP tools. All tools are already routed through the native permission gateway. Do not retry declined operations by another tool. Work only on the user task and report actual results. The workspace is ${session.workspace}. Your process directory is private runtime storage.',
        },
      },
      'default_agent': 'room',
      'mcp': {
        'tsukuyomi': {
          'type': 'remote',
          'url': bridge.uri.resolve('/mcp').toString(),
          'headers': {'Authorization': 'Bearer ${bridge.token}'},
          'oauth': false,
          'enabled': true,
          'timeout': 900000,
        },
      },
      'formatter': false,
      'lsp': false,
    };
    final env = <String, String>{
      for (final key in [
        'PATH',
        'SystemRoot',
        'WINDIR',
        'COMSPEC',
        'PATHEXT',
        'LANG',
        'LC_ALL',
      ])
        if (Platform.environment[key] != null) key: Platform.environment[key]!,
      'XDG_CONFIG_HOME': '${_private!.path}/config',
      'XDG_CACHE_HOME': '${_private!.path}/cache',
      'XDG_DATA_HOME': scopedData,
      'OPENCODE_CONFIG_CONTENT': jsonEncode(config),
      'OPENCODE_SERVER_PASSWORD': _password,
      'OPENCODE_DISABLE_PROJECT_CONFIG': 'true',
      'OPENCODE_DISABLE_MODELS_FETCH': 'true',
      'OPENCODE_DISABLE_DEFAULT_PLUGINS': 'true',
      'OPENCODE_DISABLE_AUTOUPDATE': 'true',
      'OPENCODE_DISABLE_LSP_DOWNLOAD': 'true',
      'OPENCODE_DISABLE_CLAUDE_CODE': 'true',
      'OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER': 'true',
    };
    _client = _factory();
    _process = await Process.start(
      binaries.opencode,
      ['serve', '--hostname', '127.0.0.1', '--port', port.toString()],
      workingDirectory: _private!.path,
      environment: env,
      includeParentEnvironment: false,
    );
    _exitCode = null;
    _stderr = '';
    _process!.stdout.drain<void>();
    _process!.stderr.transform(utf8.decoder).listen((chunk) {
      _stderr += chunk;
      if (_stderr.length > 16384) {
        _stderr = _stderr.substring(_stderr.length - 16384);
      }
    });
    unawaited(_process!.exitCode.then((code) => _exitCode = code));
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (_disposed) throw const ApiFailure('Agent 已关闭');
      if (_exitCode != null) {
        throw ApiFailure('Agent 启动失败（$_exitCode）：${_sanitize(_stderr)}');
      }
      try {
        final health = await _request('GET', '/global/health');
        if (health['version'] != '1.18.33') {
          throw const ApiFailure('Agent 运行时版本不匹配');
        }
        if (health['healthy'] == true) return;
      } on ApiFailure {
        rethrow;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const ApiFailure('桌面 Agent 启动超时');
  }

  @override
  Future<void> send(
    AgentSession session,
    String message,
    RoomSettings settings,
    AgentEmit emit,
  ) async {
    _cancelled = false;
    await start(session);
    if (_cancelled) throw const ApiFailure('Agent 已停止');
    final done = Completer<void>();
    unawaited(
      done.future.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {},
      ),
    );
    final client = _factory();
    _eventsClient = client;
    final parts = <String, String>{};
    final eventRequest = http.Request('GET', _uri!.resolve('/event'))
      ..headers.addAll(_headers);
    final stream = await client
        .send(eventRequest)
        .timeout(const Duration(seconds: 15));
    if (stream.statusCode != 200) throw const ApiFailure('Agent 事件连接失败');
    final subscription = stream.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (!line.startsWith('data: ')) return;
            try {
              final event = jsonDecode(line.substring(6)) as Map;
              final prop = event['properties'] as Map? ?? {};
              if (prop['sessionID'] != session.nativeId &&
                  (prop['part'] as Map?)?['sessionID'] != session.nativeId) {
                return;
              }
              if (event['type'] == 'message.part.updated') {
                final part = prop['part'] as Map;
                if (part['type'] == 'text' && part['text'] is String) {
                  parts[part['id'] as String] = part['text'] as String;
                  emit(
                    AgentEvent(
                      'assistant',
                      part['text'] as String,
                      id: part['id'] as String,
                    ),
                  );
                }
              } else if (event['type'] == 'message.part.delta') {
                final id = prop['partID'] as String;
                if (prop['field'] == 'text') {
                  parts[id] = (parts[id] ?? '') + (prop['delta'] as String);
                  emit(AgentEvent('assistant', parts[id]!, id: id));
                }
              } else if (event['type'] == 'session.error' &&
                  !done.isCompleted) {
                done.completeError(
                  ApiFailure(_sanitize(jsonEncode(prop['error']))),
                );
              } else if (event['type'] == 'session.status' &&
                  prop['status']?['type'] == 'idle' &&
                  !done.isCompleted) {
                done.complete();
              }
            } catch (_) {}
          },
          onError: (Object error) {
            if (!done.isCompleted) done.completeError(error);
          },
          onDone: () {
            if (!done.isCompleted) {
              done.completeError(const ApiFailure('Agent 事件连接已断开'));
            }
          },
        );
    try {
      await _request('POST', '/session/${session.nativeId!}/prompt_async', {
        'model': {'providerID': 'tsukuyomi', 'modelID': 'room'},
        'agent': 'room',
        'parts': [
          {'type': 'text', 'text': message},
        ],
      });
      await done.future.timeout(const Duration(minutes: 30));
      if (_cancelled) throw const ApiFailure('Agent 已停止');
      final messages = await _request(
        'GET',
        '/session/${session.nativeId!}/message?limit=20',
      ) as List;
      final assistant = messages.reversed.cast<Map>().firstWhere(
        (m) => m['info']?['role'] == 'assistant',
        orElse: () => {},
      );
      if (assistant['info']?['error'] != null) {
        throw ApiFailure(_sanitize(jsonEncode(assistant['info']['error'])));
      }
      for (final part in assistant['parts'] as List? ?? []) {
        if (part['type'] == 'text') {
          emit(
            AgentEvent(
              'assistant',
              part['text'] as String,
              id: part['id'] as String,
            ),
          );
        }
      }
    } finally {
      await subscription.cancel();
      client.close();
      if (identical(_eventsClient, client)) _eventsClient = null;
    }
  }

  String _sanitize(String text) {
    for (final key in [
      settings.apiKey,
      settings.mcpKey,
      _password,
      _bridge?.token ?? '',
    ]) {
      if (key.isNotEmpty) text = text.replaceAll(key, '[redacted]');
    }
    return text;
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    gateway.cancel();
    _bridge?.provider.cancel();
    if (_process != null && _session?.nativeId != null) {
      try {
        await _request('POST', '/session/${_session!.nativeId!}/abort');
      } catch (_) {}
    }
    _eventsClient?.close();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    try {
      await cancel().timeout(const Duration(seconds: 3));
    } catch (_) {}
    _client?.close();
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 3));
      }
    }
    await _bridge?.dispose();
    if (_private != null && await _private!.exists()) {
      await _private!.delete(recursive: true);
    }
  }
}
