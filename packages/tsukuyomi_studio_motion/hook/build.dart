import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final config = input.config.code;
    final os = config.targetOS;
    final compiler = config.cCompiler?.compiler;
    final compilerPath = compiler?.path.toLowerCase() ?? '';
    final ohos =
        os == OS.linux &&
        (compilerPath.contains('openharmony') ||
            compilerPath.contains('harmonyos'));
    final nativeRoot = ohos
        ? File.fromUri(compiler!).parent.parent.parent
        : null;
    final triple = const {
      'arm64': 'aarch64',
      'arm': 'armv7',
      'x64': 'x86_64',
    }[config.targetArchitecture.toString()];
    output.dependencies.add(
      input.packageRoot.resolve('src/vendor/quickjs/quickjs.h'),
    );
    await CBuilder.library(
      name: 'tsukuyomi_studio_motion',
      assetName: 'bindings.dart',
      sources: ['src/studio.c', 'src/vendor/quickjs/quickjs-amalgam.c'],
      includes: [input.packageRoot.resolve('src/vendor/quickjs').toFilePath()],
      language: Language.c,
      flags: os == OS.windows
          ? ['/std:c11', '/utf-8']
          : [
              '-std=gnu11',
              '-O2',
              if (os == OS.android) ...[
                '-Wl,--no-undefined',
                '-Wl,-z,max-page-size=16384',
              ],
              if (ohos) ...[
                '--target=$triple-linux-ohos',
                '--sysroot=${nativeRoot!.path}/sysroot',
              ],
            ],
      libraries: [if (os == OS.android || os == OS.linux) 'm'],
    ).run(
      input: input,
      output: output,
      logger: Logger('studio-motion')
        ..onRecord.listen((record) => stdout.writeln(record.message)),
    );
  });
}
