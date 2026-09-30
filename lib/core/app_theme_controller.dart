import 'package:flutter/foundation.dart';

import 'storage.dart';

/// The website starts in dark mode and remembers an explicit theme choice.
/// Theme is a device preference, shared across accounts and website endpoints.
class AppThemeController extends ChangeNotifier {
  AppThemeController(this.storage);

  static const storageKey = 'app-theme';
  final RoomStorage storage;
  bool _dark = true, _disposed = false;
  int _changes = 0;
  Future<void>? _restoreFuture;
  Future<void> _pendingSave = Future<void>.value();

  bool get dark => _dark;

  /// An in-flight read cannot replace a user's more recent choice.
  Future<void> restore() => _restoreFuture ??= _restore();

  Future<void> _restore() async {
    if (_disposed || _changes != 0) return;
    var saved = '';
    try {
      saved = await storage.draft(storageKey);
    } catch (_) {
      // Missing or inaccessible preferences retain the website's dark default.
    }
    if (_disposed || _changes != 0) return;
    final next = saved != 'light';
    if (_dark != next) {
      _dark = next;
      notifyListeners();
    }
  }

  Future<bool> toggle() => setDark(!_dark);

  /// Changes the visible theme immediately. Writes run in selection order so
  /// quick toggles cannot restore an older preference after the latest one.
  /// A failed write leaves the visible choice intact and returns false.
  Future<bool> setDark(bool value) {
    if (_disposed) return Future<bool>.value(false);
    _changes++;
    final changed = _dark != value;
    _dark = value;
    final saved = _pendingSave.then((_) async {
      try {
        await storage.saveDraft(storageKey, value ? 'dark' : 'light');
        return true;
      } catch (_) {
        return false;
      }
    });
    _pendingSave = saved.then((_) {});
    if (changed) notifyListeners();
    return saved;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
