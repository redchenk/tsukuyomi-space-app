import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models.dart';
import 'agent_types.dart';

class AgentTool {
  const AgentTool(
    this.name,
    this.description,
    this.properties,
    this.required,
    this.execute, {
    this.confirm = false,
    this.approvalDetails,
    this.approvalReason = '此操作会写入外部服务',
  });
  final String name, description, approvalReason;
  final Map<String, dynamic> properties;
  final List<String> required;
  final Future<dynamic> Function(Map<String, dynamic> arguments) execute;
  final bool confirm;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  approvalDetails;
  Map<String, dynamic> get schema => {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  };
  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': schema,
  };
}

class ToolGateway {
  ToolGateway({
    required this.workspace,
    required this.approve,
    required this.emit,
    required this.commandRunner,
    List<AgentTool> additional = const [],
  }) {
    tools = {
      'fs_list': AgentTool(
        'fs_list',
        'List up to 200 entries in a directory.',
        {
          'path': {'type': 'string'},
        },
        [],
        _list,
      ),
      'fs_read': AgentTool(
        'fs_read',
        'Read a UTF-8 text file (maximum 64 KiB).',
        {
          'path': {'type': 'string'},
        },
        ['path'],
        _read,
      ),
      'fs_write': AgentTool(
        'fs_write',
        'Write a UTF-8 file and return a before/after diff.',
        {
          'path': {'type': 'string'},
          'content': {'type': 'string', 'maxLength': 65536},
        },
        ['path', 'content'],
        _write,
      ),
      'command': AgentTool(
        'command',
        'Run a command in the selected workspace sandbox.',
        {
          'command': {'type': 'string', 'maxLength': 12000},
          'readRoots': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'writeRoots': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'network': {'type': 'boolean'},
          'elevated': {'type': 'boolean'},
        },
        ['command'],
        _command,
      ),
      for (final tool in additional) tool.name: tool,
    };
  }
  final String workspace;
  final AgentApprove approve;
  AgentEmit emit;
  final SandboxCommandRunner commandRunner;
  late final Map<String, AgentTool> tools;
  int _epoch = 0, _calls = 0;
  Future<void> _queue = Future.value();
  bool _cancelled = false;
  int get calls => _calls;
  void begin() {
    _cancelled = false;
    _calls = 0;
    _epoch++;
  }

  void cancel() {
    _cancelled = true;
    _epoch++;
    commandRunner.cancel();
  }

  void _check(int epoch) {
    if (_cancelled || epoch != _epoch) throw const ApiFailure('Agent 操作已取消');
  }

  Future<dynamic> call(String name, Map<String, dynamic> arguments) {
    final epoch = _epoch;
    final result = _queue.then((_) => _execute(name, arguments, epoch));
    _queue = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<dynamic> _execute(
    String name,
    Map<String, dynamic> arguments,
    int epoch,
  ) async {
    _check(epoch);
    final tool = tools[name];
    if (tool == null) throw const ApiFailure('未知 Agent 工具');
    validateArguments(tool.schema, arguments);
    if (++_calls > 20) throw const ApiFailure('已达到 20 轮工具调用上限');
    final details = tool.approvalDetails == null
        ? arguments
        : await tool.approvalDetails!(arguments);
    _check(epoch);
    if (tool.confirm &&
        !await approve(AgentApproval(name, details, tool.approvalReason))) {
      _check(epoch);
      emit(AgentEvent('tool', '操作已拒绝', data: {'name': name}));
      return {'declined': true};
    }
    _check(epoch);
    emit(AgentEvent('toolStart', name, data: {'arguments': arguments}));
    final result = await tool.execute(arguments);
    _check(epoch);
    emit(AgentEvent('toolResult', name, data: {'result': result}));
    return result;
  }

  Future<String> resolvePath(String input, {required bool write}) =>
      _path(input, write: write);

  Future<String> _path(String input, {required bool write}) async {
    final epoch = _epoch;
    _check(epoch);
    final root = await Directory(workspace).resolveSymbolicLinks();
    final path = File(
      input.isEmpty
          ? root
          : File(input).isAbsolute
          ? input
          : root + Platform.pathSeparator + input,
    ).absolute.uri.normalizePath().toFilePath();
    var ancestor = path;
    final missing = <String>[];
    while (await FileSystemEntity.type(ancestor, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final parent = File(ancestor).parent.path;
      if (parent == ancestor) throw const ApiFailure('文件路径无效');
      missing.insert(
        0,
        ancestor.substring(
          parent.length + (parent.endsWith(Platform.pathSeparator) ? 0 : 1),
        ),
      );
      ancestor = parent;
    }
    var resolved = await File(ancestor).resolveSymbolicLinks();
    for (final segment in missing) {
      resolved += Platform.pathSeparator + segment;
    }
    final inside = samePath(root, resolved) || withinPath(root, resolved);
    if (!inside &&
        !await approve(
          AgentApproval(write ? 'fs_write' : 'fs_read', {
            'path': resolved,
          }, '此路径位于选定工作目录之外'),
        )) {
      throw const ApiFailure('目录外访问已拒绝');
    }
    _check(epoch);
    return resolved;
  }

  Future<dynamic> _list(Map<String, dynamic> args) async {
    final path = await _path(args['path'] as String? ?? '', write: false);
    final result = <Map<String, dynamic>>[];
    await for (final entry in Directory(path).list(followLinks: false)) {
      result.add({
        'name': entry.uri.pathSegments.where((s) => s.isNotEmpty).last,
        'type': (await FileSystemEntity.type(
          entry.path,
          followLinks: false,
        )).toString().split('.').last,
      });
      if (result.length >= 200) break;
    }
    result.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    return result;
  }

  Future<dynamic> _read(Map<String, dynamic> args) async {
    final path = await _path(args['path'] as String, write: false);
    final file = File(path);
    if (await file.length() > 65536) {
      throw const ApiFailure('文件超过 64 KiB，请缩小读取范围');
    }
    return {'path': path, 'content': await file.readAsString()};
  }

  Future<dynamic> _write(Map<String, dynamic> args) async {
    final epoch = _epoch;
    final path = await _path(args['path'] as String, write: true);
    final content = args['content'] as String;
    if (utf8.encode(content).length > 65536) {
      throw const ApiFailure('文件写入超过 64 KiB');
    }
    final file = File(path);
    if (await file.exists() && await file.length() > 65536) {
      throw const ApiFailure('原文件过大，无法安全展示差异');
    }
    final before = await file.exists() ? await file.readAsString() : '';
    _check(epoch);
    await file.parent.create(recursive: true);
    final canonicalParent = await file.parent.resolveSymbolicLinks();
    if (!samePath(canonicalParent, file.parent.path)) {
      throw const ApiFailure('文件目录在执行前发生变化');
    }
    final temporary = File(
      '$path.tsukuyomi-${Random.secure().nextInt(1 << 32)}',
    );
    try {
      await temporary.writeAsString(content, flush: true);
      _check(epoch);
      await temporary.rename(path);
      _check(epoch);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    emit(AgentEvent('diff', path, data: {'before': before, 'after': content}));
    return {'path': path, 'written': utf8.encode(content).length};
  }

  Future<dynamic> _command(Map<String, dynamic> args) async {
    final epoch = _epoch;
    final read = List<String>.from(args['readRoots'] as List? ?? []);
    final write = List<String>.from(args['writeRoots'] as List? ?? []);
    final network = args['network'] as bool? ?? false;
    final elevated =
        args['elevated'] == true ||
        RegExp(
          r'(^|[;&|\s])(sudo|doas|pkexec|runas)([\s]|$)',
          caseSensitive: false,
        ).hasMatch(args['command'] as String);
    if (elevated) {
      await approve(AgentApproval('command', args, '命令请求提权；当前沙箱仅支持普通用户执行'));
      _check(epoch);
      throw const ApiFailure('当前系统沙箱不支持提权，命令已停止');
    }
    if ((read.isNotEmpty || write.isNotEmpty || network) &&
        !await approve(AgentApproval('command', args, '命令请求目录外访问或网络权限'))) {
      return {'declined': true};
    }
    _check(epoch);
    return commandRunner.run(
      workspace,
      args['command'] as String,
      readRoots: read,
      writeRoots: write,
      network: network,
    );
  }
}

bool samePath(String a, String b) =>
    Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
bool withinPath(String root, String path) {
  final prefix = root.endsWith(Platform.pathSeparator)
      ? root
      : root + Platform.pathSeparator;
  return Platform.isWindows
      ? path.toLowerCase().startsWith(prefix.toLowerCase())
      : path.startsWith(prefix);
}

void validateArguments(Map<String, dynamic> schema, dynamic value) {
  if (schema.containsKey('enum') &&
      !(schema['enum'] as List).any(
        (v) => jsonEncode(v) == jsonEncode(value),
      )) {
    throw const ApiFailure('工具参数不在允许范围');
  }
  if (schema.containsKey('const') &&
      jsonEncode(schema['const']) != jsonEncode(value)) {
    throw const ApiFailure('工具参数不符合固定值');
  }
  for (final key in ['oneOf', 'anyOf']) {
    if (schema[key] is List) {
      var matched = 0;
      for (final candidate in schema[key] as List) {
        try {
          validateArguments(Map<String, dynamic>.from(candidate as Map), value);
          matched++;
        } on ApiFailure {
          /* Try the next documented schema. */
        }
      }
      if (matched == 0 || (key == 'oneOf' && matched != 1)) {
        throw const ApiFailure('工具参数不符合协议');
      }
    }
  }
  if (schema['allOf'] is List) {
    for (final candidate in schema['allOf'] as List) {
      validateArguments(Map<String, dynamic>.from(candidate as Map), value);
    }
  }
  if (schema.containsKey(r'$ref')) {
    throw const ApiFailure('工具参数引用了未支持的协议，操作已停止');
  }
  if (schema['type'] is List) {
    validateArguments({
      'anyOf': [
        for (final type in schema['type'] as List) {...schema, 'type': type},
      ],
    }, value);
    return;
  }
  switch (schema['type']) {
    case 'object':
      if (value is! Map || value.length > 200) {
        throw const ApiFailure('工具参数必须是有界对象');
      }
      final properties = Map<String, dynamic>.from(
        schema['properties'] as Map? ?? {},
      );
      for (final key in schema['required'] as List? ?? []) {
        if (!value.containsKey(key)) throw ApiFailure('缺少工具参数：$key');
      }
      for (final entry in value.entries) {
        final property = properties[entry.key];
        if (property is Map) {
          validateArguments(Map<String, dynamic>.from(property), entry.value);
        } else if (schema['additionalProperties'] == false) {
          throw const ApiFailure('工具包含未知参数');
        } else if (schema['additionalProperties'] is Map) {
          validateArguments(
            Map<String, dynamic>.from(schema['additionalProperties'] as Map),
            entry.value,
          );
        }
      }
    case 'string':
      if (value is! String || value.contains('\u0000')) {
        throw const ApiFailure('工具参数必须是文本');
      }
      if (value.length > (schema['maxLength'] as int? ?? 65536) ||
          value.length < (schema['minLength'] as int? ?? 0)) {
        throw const ApiFailure('工具参数长度无效');
      }
      if (schema['pattern'] is String &&
          !RegExp(schema['pattern'] as String).hasMatch(value)) {
        throw const ApiFailure('工具参数格式无效');
      }
    case 'boolean':
      if (value is! bool) throw const ApiFailure('工具参数必须是布尔值');
    case 'integer':
      if (value is! int) throw const ApiFailure('工具参数必须是整数');
      _validateNumber(schema, value);
    case 'number':
      if (value is! num || !value.isFinite) {
        throw const ApiFailure('工具参数必须是有限数值');
      }
      _validateNumber(schema, value);
    case 'null':
      if (value != null) throw const ApiFailure('工具参数必须为空');
    case 'array':
      if (value is! List ||
          value.length > (schema['maxItems'] as int? ?? 200) ||
          value.length < (schema['minItems'] as int? ?? 0)) {
        throw const ApiFailure('工具数组参数无效');
      }
      for (final item in value) {
        validateArguments(
          Map<String, dynamic>.from(schema['items'] as Map? ?? {}),
          item,
        );
      }
  }
}

void _validateNumber(Map<String, dynamic> schema, num value) {
  if ((schema['minimum'] is num && value < schema['minimum']) ||
      (schema['maximum'] is num && value > schema['maximum'])) {
    throw const ApiFailure('工具数值参数超出范围');
  }
}

class SandboxCommandRunner {
  SandboxCommandRunner(this.executable);
  final String executable;
  Process? _process;
  bool _cancelled = false;
  Future<void> dispose() => cancel();

  Future<void> cancel() async {
    _cancelled = true;
    final process = _process;
    if (process == null) return;
    if (Platform.isWindows) {
      await Process.run('taskkill', [
        '/PID',
        process.pid.toString(),
        '/T',
        '/F',
      ]);
    } else {
      await Process.run('/bin/kill', ['-TERM', '--', '-${process.pid}']);
      process.kill();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await Process.run('/bin/kill', ['-KILL', '--', '-${process.pid}']);
      process.kill(ProcessSignal.sigkill);
    }
  }

  Future<Map<String, dynamic>> run(
    String workspace,
    String command, {
    List<String> readRoots = const [],
    List<String> writeRoots = const [],
    bool network = false,
  }) async {
    _cancelled = false;
    if (!await File(executable).exists()) {
      throw const ApiFailure('命令沙箱未安装，操作已停止');
    }
    final private = await Directory.systemTemp.createTemp('tsukuyomi-sandbox-');
    final profile = <String, String>{
      ':root': 'deny',
      ':minimal': 'read',
      ':workspace_roots': 'write',
      await File(executable).parent.parent.resolveSymbolicLinks(): 'read',
      private.path: 'write',
      for (final root in readRoots)
        await Directory(root).resolveSymbolicLinks(): 'read',
      for (final root in writeRoots)
        await Directory(root).resolveSymbolicLinks(): 'write',
    };
    final config = File('${private.path}${Platform.pathSeparator}config.toml');
    final filesystem = profile.entries
        .map((e) => '${jsonEncode(e.key)} = ${jsonEncode(e.value)}')
        .join('\n');
    await config.writeAsString(
      'default_permissions = "tsukuyomi"\n[permissions.tsukuyomi.filesystem]\n$filesystem\n[permissions.tsukuyomi.network]\nenabled = $network\n[windows]\nsandbox = "mxc"\n',
    );
    final env = <String, String>{
      'CODEX_HOME': private.path,
      'TMPDIR': private.path,
      'TMP': private.path,
      'TEMP': private.path,
      for (final name in [
        'PATH',
        'SystemRoot',
        'WINDIR',
        'COMSPEC',
        'PATHEXT',
        'LANG',
        'LC_ALL',
      ])
        if (Platform.environment[name] != null)
          name: Platform.environment[name]!,
    };
    final shell = Platform.isWindows
        ? Platform.environment['COMSPEC'] ?? 'cmd.exe'
        : '/bin/sh';
    final args = [
      'sandbox',
      '-C',
      workspace,
      '-P',
      'tsukuyomi',
      '--',
      shell,
      if (Platform.isWindows) ...[
        '/d',
        '/s',
        '/c',
        command,
      ] else ...[
        '-c',
        command,
      ],
    ];
    final out = StringBuffer(), err = StringBuffer();
    int bytes = 0;
    void collect(List<int> data, StringBuffer target) {
      if (bytes >= 65536) return;
      final retained = data.take(65536 - bytes).toList();
      bytes += retained.length;
      target.write(utf8.decode(retained, allowMalformed: true));
    }

    try {
      if (_cancelled) throw const ApiFailure('Agent 操作已取消');
      final supervisor =
          '${File(executable).parent.parent.path}${Platform.pathSeparator}command-supervisor';
      if (!Platform.isWindows && !await File(supervisor).exists()) {
        throw const ApiFailure('命令监督程序未安装，执行已停止');
      }
      final process = await Process.start(
        Platform.isWindows ? executable : supervisor,
        Platform.isWindows ? args : [executable, ...args],
        workingDirectory: workspace,
        environment: env,
        includeParentEnvironment: false,
        mode: ProcessStartMode.normal,
      );
      _process = process;
      if (_cancelled) {
        await cancel();
        throw const ApiFailure('Agent 操作已取消');
      }
      final stdout = process.stdout.forEach((data) => collect(data, out));
      final stderr = process.stderr.forEach((data) => collect(data, err));
      final int code;
      try {
        code = await process.exitCode.timeout(const Duration(seconds: 120));
      } on TimeoutException {
        await cancel();
        throw const ApiFailure('命令超过 120 秒，已终止');
      }
      await stdout;
      await stderr;
      if (_cancelled) throw const ApiFailure('命令已取消');
      if (Platform.isWindows &&
          code != 0 &&
          (err.toString().contains('MXC') ||
              err.toString().contains('windows sandbox failed:'))) {
        throw ApiFailure('Windows 命令沙箱不可用，操作已停止：$err');
      }
      return {
        'exitCode': code,
        'stdout': out.toString(),
        'stderr': err.toString(),
        'truncated': bytes >= 65536,
      };
    } finally {
      _process = null;
      await deleteAgentTemporaryDirectory(private);
    }
  }
}

/// Windows can retain a sharing lock briefly after a process has exited.
/// Retry only known filesystem locking/access codes; persistent errors surface.
Future<void> deleteAgentTemporaryDirectory(
  Directory directory, {
  bool? retryWindowsSharingViolations,
  Future<void> Function(Directory)? deleteDirectory,
}) async {
  final retry = retryWindowsSharingViolations ?? Platform.isWindows;
  for (var attempt = 0; ; attempt++) {
    try {
      if (await directory.exists()) {
        if (deleteDirectory == null) {
          await directory.delete(recursive: true);
        } else {
          await deleteDirectory(directory);
        }
      }
      return;
    } on FileSystemException catch (error) {
      if (!retry ||
          ![5, 32, 33].contains(error.osError?.errorCode) ||
          attempt >= 6) {
        rethrow;
      }
      await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
    }
  }
}
