import 'package:flutter/material.dart';

import 'storage.dart';

/// Language is a device preference, shared across accounts and endpoints.
class LocaleController extends ChangeNotifier {
  LocaleController(this.storage);
  static const storageKey = 'site-language';
  static const languages = ['zh', 'ja', 'en'];
  final RoomStorage storage;
  String _language = 'zh';
  bool _disposed = false;
  int _changes = 0;
  Future<void>? _restoreFuture;
  Future<void> _pendingSave = Future<void>.value();
  String get language => _language;
  Locale get locale => Locale(_language);
  Future<void> restore() => _restoreFuture ??= _restore();
  Future<void> _restore() async {
    if (_disposed || _changes != 0) return;
    var saved = '';
    try {
      saved = await storage.draft(storageKey);
    } catch (_) {
      /* Keep the site's Chinese default. */
    }
    if (_disposed || _changes != 0 || !languages.contains(saved)) return;
    if (saved != _language) {
      _language = saved;
      notifyListeners();
    }
  }

  Future<bool> setLanguage(String language) {
    if (_disposed || !languages.contains(language)) {
      return Future<bool>.value(false);
    }
    _changes++;
    if (_language != language) {
      _language = language;
      notifyListeners();
    }
    final saved = _pendingSave.then((_) async {
      try {
        await storage.saveDraft(storageKey, language);
        return true;
      } catch (_) {
        return false;
      }
    });
    _pendingSave = saved.then((_) {});
    return saved;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class SiteLocaleScope extends InheritedNotifier<LocaleController> {
  const SiteLocaleScope({
    super.key,
    required LocaleController controller,
    required super.child,
  }) : super(notifier: controller);
  static LocaleController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SiteLocaleScope>()?.notifier;
}

class SiteLanguageMenu extends StatelessWidget {
  const SiteLanguageMenu({super.key});
  @override
  Widget build(BuildContext context) {
    final controller = SiteLocaleScope.maybeOf(context);
    if (controller == null) return const SizedBox();
    const names = {'zh': '中文', 'ja': '日本語', 'en': 'English'};
    return PopupMenuButton<String>(
      tooltip: '${names[controller.language]} · Language',
      initialValue: controller.language,
      onSelected: (value) async {
        final saved = await controller.setLanguage(value);
        if (!saved && context.mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(
                {
                  'zh': '语言已切换，本机偏好保存失败',
                  'ja': '言語を変更しましたが、端末設定の保存に失敗しました',
                  'en': 'Language changed, but the device preference could not be saved',
                }[controller.language]!,
              ),
            ),
          );
        }
      },
      itemBuilder: (_) => [
        for (final entry in names.entries)
          CheckedPopupMenuItem(
            value: entry.key,
            checked: controller.language == entry.key,
            child: Text(entry.value),
          ),
      ],
      icon: const Icon(Icons.language),
    );
  }
}
