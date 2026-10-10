import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_release.dart';
import 'app_update_installer.dart';
import 'app_update_release.dart';
import 'app_update_service.dart';

enum AppUpdatePhase {
  idle,
  checking,
  available,
  downloading,
  verifying,
  ready,
  installing,
  opened,
  permissionRequired,
  failed,
}

class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    required this.preferences,
    AppUpdateService? service,
    UpdateInstaller? installer,
    Future<InstalledApp> Function()? installedApp,
    DateTime Function()? now,
  }) : service = service ?? AppUpdateService(),
       installer = installer ?? NativeUpdateInstaller(),
       installedApp = installedApp ?? InstalledApp.load,
       now = now ?? DateTime.now;
  final SharedPreferences preferences;
  final AppUpdateService service;
  final UpdateInstaller installer;
  final Future<InstalledApp> Function() installedApp;
  final DateTime Function() now;
  InstalledApp? installed;
  AppUpdateRelease? release;
  File? downloaded;
  AppUpdatePhase phase = AppUpdatePhase.idle;
  String? error;
  int received = 0, total = 0, notification = 0;
  UpdateCancellation? _token;
  Timer? _startup;
  bool _disposed = false;
  DateTime? _progressAt;
  bool get automatic => preferences.getBool('app-update.automatic') ?? true;
  bool get previews =>
      preferences.getBool('app-update.previews') ??
      AppVersion.parse(appReleaseTag)!.pre.isNotEmpty;
  bool get busy => const {
    AppUpdatePhase.checking,
    AppUpdatePhase.downloading,
    AppUpdatePhase.verifying,
    AppUpdatePhase.installing,
  }.contains(phase);
  bool get hasUpdate => release != null;
  DateTime? get checkedAt {
    final value = preferences.getInt('app-update.checked');
    return value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Run after Room's first frame; no package lookup or HTTP blocks startup.
  void start() {
    _startup ??= Timer(const Duration(seconds: 5), checkAutomatically);
  }

  Future<void> checkAutomatically() async {
    if (!automatic || busy || _disposed) return;
    final last = preferences.getInt('app-update.attempt');
    final interval = preferences.getBool('app-update.last-success') == false
        ? const Duration(hours: 1)
        : const Duration(hours: 24);
    if (last != null &&
        now().difference(DateTime.fromMillisecondsSinceEpoch(last)) <
            interval) {
      return;
    }
    await check(automaticCheck: true);
  }

  Future<void> setAutomatic(bool enabled) async {
    await preferences.setBool('app-update.automatic', enabled);
    _notify();
    if (enabled) unawaited(checkAutomatically());
  }

  Future<void> setPreviews(bool enabled) async {
    if (busy) return;
    await preferences.setBool('app-update.previews', enabled);
    release = null;
    downloaded = null;
    _notify();
    await check();
  }

  Future<void> remindLater() async {
    if (release != null) {
      await preferences.setString('app-update.dismissed', release!.tag);
    }
    _notify();
  }

  Future<void> check({bool automaticCheck = false}) async {
    if (busy || _disposed) return;
    final token = _token = UpdateCancellation();
    phase = AppUpdatePhase.checking;
    error = null;
    _notify();
    try {
      await preferences.setInt(
        'app-update.attempt',
        now().millisecondsSinceEpoch,
      );
      installed ??= await installedApp().timeout(const Duration(seconds: 10));
      token.check();
      final next = await service.check(
        installed!.version,
        installed!.platform,
        previews: previews,
        token: token,
      );
      token.check();
      if (release?.tag != next?.tag) downloaded = null;
      release = next;
      phase = next == null
          ? AppUpdatePhase.idle
          : downloaded == null
          ? AppUpdatePhase.available
          : AppUpdatePhase.ready;
      await preferences.setInt(
        'app-update.checked',
        now().millisecondsSinceEpoch,
      );
      await preferences.setBool('app-update.last-success', true);
      if (automaticCheck &&
          automatic &&
          next != null &&
          preferences.getString('app-update.dismissed') != next.tag) {
        notification++;
      }
    } catch (e) {
      if (_disposed) return;
      error = e is UpdateFailure ? e.code : 'network';
      phase = AppUpdatePhase.failed;
      await preferences.setBool('app-update.last-success', false);
    } finally {
      if (identical(_token, token)) _token = null;
      _notify();
    }
  }

  Future<void> download() async {
    final target = release;
    if (target == null || busy || _disposed) return;
    final token = _token = UpdateCancellation();
    phase = AppUpdatePhase.downloading;
    error = null;
    downloaded = null;
    received = 0;
    total = target.installer.size;
    _progressAt = null;
    _notify();
    try {
      final file = await service.download(target, token, (
        bytes,
        size,
        verifying,
      ) {
        if (_disposed) return;
        received = bytes;
        total = size;
        final next = verifying
            ? AppUpdatePhase.verifying
            : AppUpdatePhase.downloading;
        final changed = phase != next;
        phase = next;
        if (changed ||
            _progressAt == null ||
            now().difference(_progressAt!) >=
                const Duration(milliseconds: 100)) {
          _progressAt = now();
          _notify();
        }
      });
      token.check();
      downloaded = file;
      phase = AppUpdatePhase.ready;
    } catch (e) {
      if (_disposed) return;
      final code = e is UpdateFailure ? e.code : 'storage';
      error = code == 'cancelled' ? null : code;
      phase = code == 'cancelled'
          ? AppUpdatePhase.available
          : AppUpdatePhase.failed;
    } finally {
      if (identical(_token, token)) _token = null;
      _notify();
    }
  }

  void cancel() {
    _token?.cancel();
  }

  Future<void> install() async {
    final file = downloaded, target = release, app = installed;
    if (file == null || target == null || app == null || busy || _disposed) {
      return;
    }
    final token = _token = UpdateCancellation();
    phase = AppUpdatePhase.verifying;
    error = null;
    _notify();
    try {
      await service.verify(file, target, token);
      token.check();
      phase = AppUpdatePhase.installing;
      _notify();
      final result = await installer.install(file, app.platform);
      if (_disposed) return;
      phase = result == UpdateInstallResult.permissionRequired
          ? AppUpdatePhase.permissionRequired
          : AppUpdatePhase.opened;
    } catch (e) {
      if (_disposed) return;
      error = e is UpdateFailure
          ? e.code
          : e is PlatformException &&
                const {
                  'signing',
                  'package',
                  'downgrade',
                  'storage',
                }.contains(e.code)
          ? e.code
          : 'installer';
      phase = AppUpdatePhase.failed;
      if (error == 'integrity') downloaded = null;
    } finally {
      if (identical(_token, token)) _token = null;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _startup?.cancel();
    _token?.cancel();
    super.dispose();
  }
}
