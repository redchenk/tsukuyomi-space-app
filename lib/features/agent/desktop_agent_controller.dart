import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../core/agent/agent_types.dart';
import '../../core/agent/agent_tools.dart';
import '../../core/agent/agent_binaries.dart';
import '../../core/agent/opencode_agent_runtime.dart';
import '../../core/agent/structured_agent_runtime.dart';
import '../../core/models.dart';
import '../../core/llm_client.dart';
import '../room/room_controller.dart';
import 'native_agent_tools.dart';

bool get desktopAgentSupported =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

class DesktopAgentController extends ChangeNotifier {
  DesktopAgentController(
    this.room, {
    this.runtimeDataDirectory,
    this.nativeResponseTimeout = const Duration(seconds: 30),
  }) {
    _owner = owner;
    _configuration = configuration;
    room.addListener(_accountChanged);
  }
  final RoomController room;
  final String? runtimeDataDirectory;
  final Duration nativeResponseTimeout;
  String workspace = '', error = '', engine = 'auto', status = '';
  String activity = '';
  DateTime? activityAt;
  AgentSession? session;
  AgentRuntime? _runtime;
  ToolGateway? _gateway;
  NativeAgentTools? _nativeTools;
  bool busy = false, _disposed = false;
  int _epoch = 0;
  String _owner = '', _configuration = '';
  final _pending = <({AgentApproval request, Completer<bool> answer})>[];
  Future<void> _saving = Future.value();
  Future<void>? _shutdown;
  Timer? _nativeResponseTimer, _streamRefresh;
  AgentApproval? get approval => _pending.firstOrNull?.request;
  String get owner =>
      '${endpointUri(room.settings.siteUrl).origin}:${room.account?.id ?? 'guest'}:${room.sessionExpired}';
  String get configuration => sha256
      .convert(
        utf8.encode(
          jsonEncode(room.settings.toJson()) +
              room.settings.apiKey +
              room.settings.mcpKey,
        ),
      )
      .toString();
  String get _workspaceKey => 'agent-workspace:$owner';
  String _sessionKey(String path) =>
      'agent-session:$owner:${sha256.convert(utf8.encode(path))}';
  void _changed() {
    _streamRefresh?.cancel();
    _streamRefresh = null;
    if (!_disposed) notifyListeners();
  }

  Future<void> restore() async {
    final epoch = _epoch;
    final path = await room.storage.draft(_workspaceKey);
    if (epoch != _epoch || path.isEmpty || !await Directory(path).exists()) {
      return;
    }
    await selectWorkspace(path);
  }

  Future<void> selectWorkspace(String path) async {
    final identity = owner;
    await stop();
    if (_disposed || identity != owner) return;
    final epoch = ++_epoch;
    await _closeRuntime();
    final canonical = await Directory(path).resolveSymbolicLinks();
    if (_disposed || epoch != _epoch) return;
    workspace = canonical;
    final saved = await room.storage.draft(_sessionKey(canonical));
    if (_disposed || epoch != _epoch) return;
    try {
      session = AgentSession.decode(saved);
      if (session!.owner != owner || session!.workspace != canonical) {
        session = null;
      }
    } catch (_) {
      session = null;
    }
    session ??= AgentSession(
      id: newTurnId(),
      owner: owner,
      workspace: canonical,
    );
    await room.storage.saveDraft(_workspaceKey, canonical);
    _changed();
    await warmup();
  }

  Future<void> newSession() async {
    final identity = owner;
    await stop();
    if (_disposed || identity != owner) return;
    await _closeRuntime();
    if (_disposed || workspace.isEmpty) return;
    session = AgentSession(id: newTurnId(), owner: owner, workspace: workspace);
    error = '';
    await _save();
    _changed();
  }

  Future<void> _save() {
    final current = session;
    if (current == null) return Future.value();
    final key =
            'agent-session:${current.owner}:${sha256.convert(utf8.encode(current.workspace))}',
        text = jsonEncode(current.toJson());
    _saving = _saving
        .catchError((_) {})
        .then((_) => room.storage.saveDraft(key, text));
    return _saving;
  }

  void emit(AgentEvent event) {
    if (_disposed || session?.owner != owner) return;
    if ((event.type == 'modelProgress' && event.data['activity'] == true) ||
        event.type == 'toolStart' ||
        (event.type == 'assistant' && event.text.isNotEmpty)) {
      _nativeResponseTimer?.cancel();
    }
    if (event.type == 'modelProgress') {
      if (activity != event.text) {
        activity = event.text;
        activityAt = DateTime.now();
        _changed();
      }
      return;
    }
    if (event.type == 'toolStart' || event.type == 'toolResult') {
      activity = event.type == 'toolStart' ? '正在执行工具' : '正在整理结果';
      activityAt = DateTime.now();
    }
    final events = session!.events;
    final index = event.id.isEmpty
        ? -1
        : events.indexWhere((e) => e.id == event.id && e.type == event.type);
    if (index < 0) {
      events.add(event);
    } else {
      events[index] = event;
    }
    if (events.length > 2000) events.removeRange(0, events.length - 2000);
    if (event.data['streaming'] == true) {
      _streamRefresh ??= Timer(const Duration(milliseconds: 32), () {
        _streamRefresh = null;
        if (!_disposed) notifyListeners();
      });
    } else {
      _changed();
    }
  }

  Future<bool> _approve(AgentApproval request) async {
    final epoch = _epoch;
    final pending = (request: request, answer: Completer<bool>());
    _pending.add(pending);
    _nativeResponseTimer?.cancel();
    activity = '等待你的确认';
    activityAt = DateTime.now();
    _changed();
    try {
      final answer = await pending.answer.future.timeout(
        const Duration(minutes: 10),
        onTimeout: () => false,
      );
      return answer && !_disposed && epoch == _epoch && session?.owner == owner;
    } finally {
      _pending.remove(pending);
      _changed();
    }
  }

  void respond(bool allow) {
    final pending = _pending.firstOrNull;
    if (pending != null && !pending.answer.isCompleted) {
      pending.answer.complete(allow);
    }
  }

  void _accountChanged() {
    if (owner == _owner && configuration == _configuration) return;
    _owner = owner;
    _configuration = configuration;
    final epoch = ++_epoch;
    for (final pending in _pending) {
      if (!pending.answer.isCompleted) pending.answer.complete(false);
    }
    _interruptStreams();
    final saved = _save();
    final closing = _closeRuntime();
    session = null;
    workspace = '';
    error = '';
    busy = true;
    _changed();
    unawaited(
      Future.wait([saved, closing])
          .then((_) async {
            if (_disposed || epoch != _epoch) return;
            busy = false;
            _changed();
            await restore();
          })
          .catchError((Object failure) {
            if (!_disposed && epoch == _epoch) {
              busy = false;
              error = failure.toString();
              _changed();
            }
          }),
    );
  }

  Future<void> undoArticle(AgentEvent event) async {
    if (_disposed || busy || !event.data.containsKey('articleId')) return;
    final epoch = ++_epoch;
    busy = true;
    error = '';
    _changed();
    try {
      _nativeTools ??= NativeAgentTools(room);
      final tools = await _nativeTools!.discover();
      if (_disposed || epoch != _epoch) return;
      final gateway =
          _gateway ??
          ToolGateway(
            workspace: workspace,
            approve: _approve,
            emit: emit,
            commandRunner: SandboxCommandRunner('missing'),
            additional: tools,
          );
      _nativeTools!.gateway = gateway;
      gateway.emit = (event) {
        if (epoch == _epoch) emit(event);
      };
      gateway.begin();
      await gateway.call('article_patch', {
        'id': event.data['articleId'],
        'revision': event.data['revision'],
        'changes': jsonDecode(event.data['before'] as String),
      });
      if (epoch == _epoch) {
        emit(AgentEvent('info', '已撤销草稿修改'));
        await _save();
      }
    } catch (failure) {
      if (epoch == _epoch) error = failure.toString();
    } finally {
      if (epoch == _epoch) {
        busy = false;
        _changed();
      }
    }
  }

  Future<bool> _prepare(int epoch, AgentEmit taskEmit) async {
    taskEmit(AgentEvent('modelProgress', '正在检查工作目录和工具'));
    final binaries = await AgentBinaries.locate();
    if (_disposed || epoch != _epoch) return false;
    _nativeTools ??= NativeAgentTools(room);
    final tools = await _nativeTools!.discover();
    if (_disposed || epoch != _epoch) return false;
    _gateway ??= ToolGateway(
      workspace: workspace,
      approve: _approve,
      emit: taskEmit,
      commandRunner: SandboxCommandRunner(binaries.codex),
      additional: tools,
    );
    _nativeTools!.gateway = _gateway;
    _gateway!.emit = taskEmit;
    final preference = await room.storage.draft(
      'agent-engine:$owner:$configuration',
    );
    if (_disposed || epoch != _epoch) return false;
    _runtime ??=
        engine == 'structured' ||
            room.settings.flag('llmProxy') ||
            preference == 'structured'
        ? StructuredAgentRuntime(
            _gateway!,
            chat: LlmClient()..siteCookie = room.site.cookie,
          )
        : OpenCodeAgentRuntime(
            binaries,
            _gateway!,
            room.settings,
            dataDirectory: runtimeDataDirectory,
          );
    return true;
  }

  Future<void> warmup() async {
    if (_disposed ||
        busy ||
        session == null ||
        room.settings.model.trim().isEmpty) {
      return;
    }
    final epoch = ++_epoch;
    busy = true;
    error = '';
    status = '正在启动 Agent';
    activity = '正在启动 Agent';
    activityAt = DateTime.now();
    _changed();
    try {
      if (!await _prepare(epoch, (event) {
        if (epoch == _epoch) emit(event);
      })) {
        return;
      }
      await _runtime!.start(session!);
      if (epoch == _epoch) {
        status = '准备就绪';
        await _save();
      }
    } catch (failure) {
      if (epoch == _epoch) {
        error = failure.toString();
        await _closeRuntime();
      }
    } finally {
      if (epoch == _epoch) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> send(String text) async {
    if (_disposed || busy || text.trim().isEmpty) return;
    if (workspace.isEmpty) {
      error = '请先选择工作目录';
      _changed();
      return;
    }
    if (room.settings.model.trim().isEmpty) {
      error = '请先连接模型';
      _changed();
      return;
    }
    final epoch = ++_epoch;
    busy = true;
    error = '';
    status = '正在启动 Agent';
    activity = '正在准备任务';
    activityAt = DateTime.now();
    emit(AgentEvent('user', text));
    _changed();
    try {
      void taskEmit(AgentEvent event) {
        if (epoch == _epoch) emit(event);
      }

      if (!await _prepare(epoch, taskEmit)) return;
      _gateway!.begin();
      status = _runtime is StructuredAgentRuntime ? '结构化兼容模式' : 'OpenCode';
      _changed();
      try {
        if (_runtime is OpenCodeAgentRuntime && engine == 'auto') {
          final timeout = Completer<void>();
          final timer = Timer(nativeResponseTimeout, () {
            if (epoch == _epoch &&
                _gateway!.calls == 0 &&
                !timeout.isCompleted) {
              final upstream =
                  (_runtime as OpenCodeAgentRuntime).lastModelFailure;
              timeout.completeError(upstream ?? const AgentResponseTimeout());
              _gateway!.cancel();
              unawaited(_runtime!.cancel().catchError((Object _) {}));
            }
          });
          _nativeResponseTimer = timer;
          try {
            await Future.any([
              _runtime!.send(session!, text, room.settings, taskEmit),
              timeout.future,
            ]);
          } finally {
            timer.cancel();
            if (identical(_nativeResponseTimer, timer)) {
              _nativeResponseTimer = null;
            }
          }
        } else {
          await _runtime!.send(session!, text, room.settings, taskEmit);
        }
      } catch (failure) {
        if (epoch != _epoch ||
            _runtime is! OpenCodeAgentRuntime ||
            _gateway!.calls > 0 ||
            engine != 'auto' ||
            failure is! AgentResponseTimeout &&
                !(failure is ApiFailure &&
                    [400, 422].contains(failure.status)) &&
                !RegExp(
                  r'tools unsupported|does not support tools|function.*unsupported',
                  caseSensitive: false,
                ).hasMatch(failure.toString())) {
          rethrow;
        }
        emit(
          AgentEvent(
            'info',
            failure is AgentResponseTimeout
                ? '自动模式等待过久，正在切换兼容模式'
                : '模型工具协议不兼容，正在切换兼容模式',
          ),
        );
        activity = '正在切换兼容模式';
        activityAt = DateTime.now();
        _changed();
        await _runtime!.dispose();
        if (_disposed || epoch != _epoch) return;
        _gateway!.begin();
        _runtime = StructuredAgentRuntime(
          _gateway!,
          chat: LlmClient()..siteCookie = room.site.cookie,
        );
        status = '结构化兼容模式';
        _changed();
        await _runtime!.send(session!, text, room.settings, taskEmit);
        if (epoch == _epoch) {
          await room.storage.saveDraft(
            'agent-engine:$owner:$configuration',
            'structured',
          );
        }
      }
      if (epoch == _epoch) emit(AgentEvent('done', '本轮已结束'));
    } catch (failure) {
      if (!_disposed && epoch == _epoch) {
        error = failure.toString();
        emit(AgentEvent('error', error));
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        if (error.isNotEmpty) _interruptStreams();
        await _save();
        _changed();
      }
    }
  }

  Future<void> stop() async {
    final epoch = ++_epoch;
    _nativeResponseTimer?.cancel();
    _streamRefresh?.cancel();
    for (final pending in _pending) {
      if (!pending.answer.isCompleted) pending.answer.complete(false);
    }
    _gateway?.cancel();
    _nativeTools?.cancel();
    await _runtime?.cancel();
    if (_disposed || epoch != _epoch) return;
    busy = false;
    _interruptStreams();
    await _save();
    _changed();
  }

  void _interruptStreams() {
    for (var i = 0; i < (session?.events.length ?? 0); i++) {
      final event = session!.events[i];
      if (event.data['streaming'] == true) {
        session!.events[i] = AgentEvent(
          event.type,
          event.text,
          id: event.id,
          data: {...event.data, 'streaming': false, 'interrupted': true},
        );
      }
    }
  }

  Future<void> _closeRuntime() async {
    _nativeResponseTimer?.cancel();
    final runtime = _runtime;
    final gateway = _gateway;
    _runtime = null;
    gateway?.cancel();
    _gateway = null;
    final tools = _nativeTools;
    _nativeTools = null;
    tools?.cancel();
    await runtime?.dispose();
    await gateway?.commandRunner.dispose();
    tools?.dispose();
  }

  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    _disposed = true;
    _epoch++;
    _nativeResponseTimer?.cancel();
    _streamRefresh?.cancel();
    _interruptStreams();
    room.removeListener(_accountChanged);
    for (final pending in _pending) {
      if (!pending.answer.isCompleted) pending.answer.complete(false);
    }
    return _shutdown = Future.wait([_save(), _closeRuntime()]).then((_) {});
  }

  @override
  void dispose() {
    unawaited(shutdown().catchError((Object _) {}));
    super.dispose();
  }
}
