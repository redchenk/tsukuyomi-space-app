import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/app_theme_controller.dart';

import 'support/fakes.dart';

class DelayedThemeStorage extends MemoryStorage {
  final read = Completer<String>();
  final writes = <String>[];
  final gates = <Completer<void>>[];
  var reads = 0;
  @override
  Future<String> draft(String scope) {
    expect(scope, AppThemeController.storageKey);
    reads++;
    return read.future;
  }

  @override
  Future<void> saveDraft(String scope, String value) async {
    expect(scope, AppThemeController.storageKey);
    writes.add(value);
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    await super.saveDraft(scope, value);
  }
}

void main() {
  test(
    'defaults to dark and restores a persisted light choice after restart',
    () async {
      final storage = MemoryStorage();
      final first = AppThemeController(storage);
      expect(first.dark, isTrue);
      await first.restore();
      expect(first.dark, isTrue);
      expect(await first.toggle(), isTrue);
      expect(first.dark, isFalse);
      first.dispose();

      final restarted = AppThemeController(storage);
      addTearDown(restarted.dispose);
      await restarted.restore();
      expect(restarted.dark, isFalse);
      expect(storage.drafts, {AppThemeController.storageKey: 'light'});
      expect(storage.secrets, isEmpty);
      expect(storage.value.toJson()['options'], isEmpty);
    },
  );

  test(
    'restores dark and falls back to dark for missing or invalid values',
    () async {
      for (final saved in ['', 'dark', 'invalid']) {
        final storage = MemoryStorage()
          ..drafts[AppThemeController.storageKey] = saved;
        final theme = AppThemeController(storage);
        await theme.restore();
        expect(theme.dark, isTrue);
        theme.dispose();
      }
    },
  );

  test('a delayed restore never overwrites a user selection', () async {
    final storage = DelayedThemeStorage();
    final theme = AppThemeController(storage);
    addTearDown(theme.dispose);
    final restoring = theme.restore();
    final saving = theme.toggle();
    expect(theme.dark, isFalse);
    storage.read.complete('dark');
    await restoring;
    expect(theme.dark, isFalse);
    await Future<void>.delayed(Duration.zero);
    storage.gates.single.complete();
    expect(await saving, isTrue);
    expect(storage.drafts[AppThemeController.storageKey], 'light');
  });

  test(
    'restore begun after a selection keeps it without reading stale data',
    () async {
      final storage = MemoryStorage()
        ..drafts[AppThemeController.storageKey] = 'light';
      final theme = AppThemeController(storage);
      addTearDown(theme.dispose);
      // Choosing the current default is still an explicit preference.
      final saving = theme.setDark(true);
      await theme.restore();
      expect(theme.dark, isTrue);
      expect(await saving, isTrue);
      expect(storage.drafts[AppThemeController.storageKey], 'dark');
    },
  );

  test(
    'rapid toggles save serially and restart with the final choice',
    () async {
      final storage = DelayedThemeStorage();
      final theme = AppThemeController(storage);
      var updates = 0;
      theme.addListener(() => updates++);
      final first = theme.toggle();
      final second = theme.toggle();
      final third = theme.toggle();
      expect(theme.dark, isFalse);
      expect(updates, 3);
      await Future<void>.delayed(Duration.zero);
      expect(storage.writes, ['light']);

      storage.gates[0].complete();
      expect(await first, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(storage.writes, ['light', 'dark']);
      storage.gates[1].complete();
      expect(await second, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(storage.writes, ['light', 'dark', 'light']);
      storage.gates[2].complete();
      expect(await third, isTrue);
      theme.dispose();

      storage.read.complete(storage.drafts[AppThemeController.storageKey]!);
      final restarted = AppThemeController(storage);
      addTearDown(restarted.dispose);
      await restarted.restore();
      expect(restarted.dark, isFalse);
    },
  );

  test(
    'listener-triggered selections also persist in selection order',
    () async {
      final storage = DelayedThemeStorage();
      final theme = AppThemeController(storage);
      addTearDown(theme.dispose);
      Future<bool>? second;
      theme.addListener(() {
        if (!theme.dark) second = theme.setDark(true);
      });
      final first = theme.toggle();
      expect(theme.dark, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(storage.writes, ['light']);
      storage.gates[0].complete();
      expect(await first, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(storage.writes, ['light', 'dark']);
      storage.gates[1].complete();
      expect(await second!, isTrue);
      expect(storage.drafts[AppThemeController.storageKey], 'dark');
    },
  );

  test(
    'read errors retain the dark default and repeated restore reads once',
    () async {
      final storage = DelayedThemeStorage();
      final theme = AppThemeController(storage);
      addTearDown(theme.dispose);
      final first = theme.restore();
      final second = theme.restore();
      storage.read.completeError(StateError('unavailable'));
      await Future.wait([first, second]);
      expect(theme.dark, isTrue);
      expect(storage.reads, 1);
    },
  );

  test(
    'write failure preserves the visible choice and does not block later saves',
    () async {
      final storage = DelayedThemeStorage();
      final theme = AppThemeController(storage);
      addTearDown(theme.dispose);
      final failed = theme.toggle();
      final retry = theme.setDark(false);
      await Future<void>.delayed(Duration.zero);
      storage.gates[0].completeError(StateError('disk full'));
      expect(await failed, isFalse);
      expect(theme.dark, isFalse);
      await Future<void>.delayed(Duration.zero);
      storage.gates[1].complete();
      expect(await retry, isTrue);
      expect(storage.drafts[AppThemeController.storageKey], 'light');
    },
  );

  test(
    'dispose prevents late restore notifications but finishes queued saves',
    () async {
      final storage = DelayedThemeStorage();
      final theme = AppThemeController(storage);
      var updates = 0;
      theme.addListener(() => updates++);
      final restoring = theme.restore();
      final saving = theme.toggle();
      theme.dispose();
      storage.read.complete('dark');
      await restoring;
      await Future<void>.delayed(Duration.zero);
      storage.gates.single.complete();
      expect(await saving, isTrue);
      expect(updates, 1);
      expect(await theme.toggle(), isFalse);
      expect(storage.writes, ['light']);
    },
  );
}
