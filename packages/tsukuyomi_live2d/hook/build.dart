import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final sdk = input.packageRoot.resolve('vendor/cubism/');
    final config = input.config.code;
    final os = config.targetOS;
    final arch = config.targetArchitecture.toString();
    String? core;
    if (os == OS.macOS) {
      core =
          'Core/lib/macos/${arch == 'x64' ? 'x86_64' : arch}/libLive2DCubismCore.a';
    } else if (os == OS.linux && arch == 'x64') {
      core = 'Core/lib/linux/x86_64/libLive2DCubismCore.a';
    } else if (os == OS.android) {
      final abi = {
        'arm64': 'arm64-v8a',
        'arm': 'armeabi-v7a',
        'x64': 'x86_64',
        'ia32': 'x86',
      }[arch];
      if (abi != null) core = 'Core/lib/android/$abi/libLive2DCubismCore.a';
    } else if (os == OS.iOS) {
      final simulator = config.iOS.targetSdk == IOSSdk.iPhoneSimulator;
      final cpu = arch == 'x64' ? 'x86_64' : arch;
      core =
          'Core/lib/ios/Release-${simulator ? 'iphonesimulator-$cpu' : 'iphoneos'}/libLive2DCubismCore.a';
    }
    if (os == OS.windows && ['x64', 'ia32'].contains(arch)) {
      core =
          'Core/lib/windows/${arch == 'x64' ? 'x86_64' : 'x86'}/143/Live2DCubismCore_MD.lib';
    }
    final enabled =
        core != null && File.fromUri(sdk.resolve(core)).existsSync();
    final requireCore = File.fromUri(sdk.resolve('REQUIRE_CORE'));
    if (!enabled && requireCore.existsSync()) {
      throw StateError('Release requires Cubism Core for $os/$arch: $core');
    }
    if (requireCore.existsSync()) output.dependencies.add(requireCore.uri);
    final sources = <String>['src/bridge.cpp'];
    if (enabled) {
      final framework = Directory.fromUri(sdk.resolve('Framework/src/'));
      for (final file
          in framework.listSync(recursive: true).whereType<File>()) {
        if (file.path.endsWith('.cpp') &&
            (!file.uri.path.contains('/Rendering/') ||
                file.uri.path.endsWith('/csmBlendMode.cpp')) &&
            !file.uri.path.endsWith('/CubismUserModel.cpp')) {
          sources.add(file.path);
        }
      }
      output.dependencies.add(sdk.resolve(core));
    }
    final builder = CBuilder.library(
      name: input.packageName,
      assetName: 'bindings.dart',
      sources: sources,
      language: Language.cpp,
      cppLinkStdLib: os == OS.windows
          ? null
          : (os == OS.android
                ? 'c++_static'
                : (os == OS.linux ? 'stdc++' : 'c++')),
      includes: enabled
          ? [
              sdk.resolve('Core/include').toFilePath(),
              sdk.resolve('Framework/src').toFilePath(),
            ]
          : [],
      defines: {'TS_HAS_CUBISM': enabled ? '1' : '0'},
      flags: os == OS.windows
          ? ['/std:c++17', '/MD']
          : ['-std=c++17', if (os == OS.android) '-Wl,--no-undefined'],
      libraries: enabled
          ? [
              os == OS.windows ? 'Live2DCubismCore_MD' : 'Live2DCubismCore',
              if (os == OS.android) ...['m', 'log'],
            ]
          : [],
      libraryDirectories: enabled
          ? [sdk.resolve(core).resolve('.').toFilePath()]
          : [],
    );
    await builder.run(
      input: input,
      output: output,
      logger: Logger('cubism')
        ..onRecord.listen((r) => stdout.writeln(r.message)),
    );
  });
}
