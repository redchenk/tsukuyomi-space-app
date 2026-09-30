import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;

import 'agent_tools.dart';
import '../models.dart';

class AgentBinaries {
  AgentBinaries(this.directory);
  final String directory;
  String get opencode =>
      '$directory${Platform.pathSeparator}opencode${Platform.isWindows ? '.exe' : ''}';
  String get codex =>
      '$directory${Platform.pathSeparator}bin${Platform.pathSeparator}codex${Platform.isWindows ? '.exe' : ''}';
  static Future<AgentBinaries> locate() async {
    var target = Platform.isWindows ? 'windows-x64' : 'linux-x64';
    if (Platform.isMacOS) {
      final arch = await Process.run('/usr/bin/uname', ['-m']);
      target = arch.stdout.toString().trim() == 'arm64'
          ? 'macos-arm64'
          : 'macos-x64';
    }
    final parent = File(Platform.resolvedExecutable).parent;
    const override = String.fromEnvironment('AGENT_BUNDLE_PATH');
    final paths = override.isNotEmpty
        ? ['$override/$target']
        : [
            if (Platform.isMacOS)
              '${parent.parent.path}/Resources/agent/$target',
            '${parent.path}${Platform.pathSeparator}agent${Platform.pathSeparator}$target',
            if (!kReleaseMode)
              '${Directory.current.path}/build/agent-runtime/$target',
          ];
    for (final path in paths) {
      if (await File('$path/runtime-manifest.json').exists()) {
        final verified = await Isolate.run(() => _verifyBundle(path));
        if (!verified) throw const ApiFailure('Agent 运行时校验失败，请重新安装完整应用');
        return AgentBinaries(path);
      }
    }
    throw const ApiFailure('当前安装包缺少桌面 Agent 运行时');
  }
}

Future<bool> _verifyBundle(String directory) async {
  final manifest = jsonDecode(
    File('$directory/runtime-manifest.json').readAsStringSync(),
  ) as Map;
  if (manifest['opencode'] != '1.18.33' || manifest['codex'] != '0.159.0') {
    return false;
  }
  final files = manifest['files'];
  if (files is! Map ||
      !files.containsKey(Platform.isWindows ? 'opencode.exe' : 'opencode') ||
      !files.containsKey(Platform.isWindows ? 'bin/codex.exe' : 'bin/codex') ||
      (!Platform.isWindows && !files.containsKey('command-supervisor')) ||
      !files.keys.any((name) => name.toString().startsWith('licenses/'))) {
    return false;
  }
  final root = Directory(directory).resolveSymbolicLinksSync();
  for (final entry in (manifest['files'] as Map).entries) {
    final file = File('$directory/${entry.key}');
    if (!file.existsSync() ||
        !withinPath(root, file.resolveSymbolicLinksSync())) {
      return false;
    }
    if ((await sha256.bind(file.openRead()).first).toString() != entry.value) {
      return false;
    }
  }
  return true;
}
