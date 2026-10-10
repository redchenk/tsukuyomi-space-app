import 'dart:io';
import 'dart:ffi' show Abi;
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import 'app_release.dart';
import 'app_update_release.dart';

const appUpdateChannel = MethodChannel('space.tsukuyomi/app_update');

class InstalledApp {
  const InstalledApp(this.version, this.build, this.platform);
  final AppVersion version;
  final String build;
  final UpdatePlatform platform;
  static Future<InstalledApp> load() async {
    final info = await PackageInfo.fromPlatform();
    final version = AppVersion.parse(info.version);
    final tag = AppVersion.parse(appReleaseTag)!;
    if (version == null) throw const UpdateFailure('metadata');
    UpdatePlatform? platform;
    if (Platform.isAndroid) {
      final abis =
          await appUpdateChannel.invokeListMethod<String>('supportedAbis') ??
          [];
      // Preserve the running APK's ABI and its split-APK versionCode offset,
      // including devices that can emulate a second architecture.
      final abi = Abi.current();
      if (abi == Abi.androidArm64 && abis.contains('arm64-v8a')) {
        platform = UpdatePlatform.androidArm64;
      } else if (abi == Abi.androidX64 && abis.contains('x86_64')) {
        platform = UpdatePlatform.androidX64;
      }
    } else if (Platform.isMacOS) {
      platform = UpdatePlatform.macos;
    } else if (Platform.isIOS) {
      platform = UpdatePlatform.ios;
    } else {
      // Only x64 desktop builds are distributed; reject ARM hosts running a
      // locally built native ARM app. Windows x64 emulation remains supported.
      final abi = Abi.current();
      if (Platform.isWindows && abi == Abi.windowsX64) {
        platform = UpdatePlatform.windows;
      }
      if (Platform.isLinux && abi == Abi.linuxX64) {
        platform = UpdatePlatform.linux;
      }
    }
    if (platform == null) throw const UpdateFailure('unsupported');
    return InstalledApp(
      version.base == tag.base ? tag : version,
      info.buildNumber,
      platform,
    );
  }
}

enum UpdateInstallResult { opened, permissionRequired, shared }

abstract interface class UpdateInstaller {
  Future<UpdateInstallResult> install(File file, UpdatePlatform platform);
}

class NativeUpdateInstaller implements UpdateInstaller {
  @override
  Future<UpdateInstallResult> install(
    File file,
    UpdatePlatform platform,
  ) async {
    if (Platform.isAndroid) {
      final result = await appUpdateChannel.invokeMethod<String>('install', {
        'path': file.path,
      });
      return result == 'permissionRequired'
          ? UpdateInstallResult.permissionRequired
          : UpdateInstallResult.opened;
    }
    if (Platform.isIOS) {
      final view = PlatformDispatcher.instance.implicitView;
      final size = view == null
          ? const Size(2, 2)
          : view.physicalSize / view.devicePixelRatio;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'Tsukuyomi Space · iOS IPA',
          sharePositionOrigin: Rect.fromLTWH(
            size.width / 2,
            size.height / 2,
            1,
            1,
          ),
        ),
      );
      return UpdateInstallResult.shared;
    }
    if (Platform.isWindows) {
      // Inno Setup presents its normal upgrade UI and handles files in use.
      await Process.start(file.path, const [], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      final result = await Process.run('/usr/bin/open', [file.path]);
      if (result.exitCode != 0) throw const UpdateFailure('installer');
    } else if (Platform.isLinux) {
      final result = await Process.run('xdg-open', [file.path]);
      if (result.exitCode != 0) throw const UpdateFailure('installer');
    } else {
      throw const UpdateFailure('unsupported');
    }
    return UpdateInstallResult.opened;
  }
}
