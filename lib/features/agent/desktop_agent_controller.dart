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
  DesktopAgentController(this.room, {this.runtimeDataDirectory}) {
    _owner = owner;
    _configuration = configuration;
    room.addListener(_accountChanged);
  }
  final RoomController room;
  final String? runtimeDataDirectory;
  String workspace = '', error = '', engine = 'auto', status = '';
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
    _changed();
  }

  Future<bool> _approve(AgentApproval request) async {
    final epoch = _epoch;
    final pending = (request: request, answer: Completer<bool>());
    _pending.add(pending);
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
    _runtime ??= engine == 'structured' || room.settings.flag('llmProxy')
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
    _changed();
    try {
      void taskEmit(AgentEvent event) {
        if (epoch == _epoch) emit(event);
      }

      if (!await _prepare(epoch, taskEmit)) return;
      _gateway!.begin();
      emit(AgentEvent('user', text));
      status = _runtime is StructuredAgentRuntime ? '结构化兼容模式' : 'OpenCode';
      _changed();
      try {
        await _runtime!.send(session!, text, room.settings, taskEmit);
      } catch (failure) {
        if (epoch != _epoch ||
            _runtime is! OpenCodeAgentRuntime ||
            _gateway!.calls > 0 ||
            engine != 'auto' ||
            !(failure is ApiFailure && [400, 422].contains(failure.status)) &&
                !RegExp(
                  r'tools unsupported|does not support tools|function.*unsupported',
                  caseSensitive: false,
                ).hasMatch(failure.toString())) {
          rethrow;
        }
        await _runtime!.dispose();
        _gateway!.begin();
        _runtime = StructuredAgentRuntime(
          _gateway!,
          chat: LlmClient()..siteCookie = room.site.cookie,
        );
        status = '结构化兼容模式';
        _changed();
        await _runtime!.send(session!, text, room.settings, taskEmit);
      }
      if (epoch == _epoch) emit(AgentEvent('done', '任务完成'));
    } catch (failure) {
      if (!_disposed && epoch == _epoch) {
        error = failure.toString();
        emit(AgentEvent('error', error));
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        await _save();
        _changed();
      }
    }
  }

  Future<void> stop() async {
    final epoch = ++_epoch;
    for (final pending in _pending) {
      if (!pending.answer.isCompleted) pending.answer.complete(false);
    }
    _gateway?.cancel();
    _nativeTools?.cancel();
    await _runtime?.cancel();
    if (_disposed || epoch != _epoch) return;
    busy = false;
    await _save();
    _changed();
  }

  Future<void> _closeRuntime() async {
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
