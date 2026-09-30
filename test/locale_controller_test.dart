import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/locale_controller.dart';
import 'package:tsukuyomi_space_app/core/site_i18n_messages.dart';
import 'package:tsukuyomi_space_app/core/site_localization.dart';

import 'support/fakes.dart';

class _DelayedStorage extends MemoryStorage {
  final read = Completer<String>();
  final writes = <String>[], gates = <Completer<void>>[];
  int reads = 0;
  @override
  Future<String> draft(String scope) {
    reads++;
    return read.future;
  }

  @override
  Future<void> saveDraft(String scope, String value) async {
    writes.add(value);
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    await super.saveDraft(scope, value);
  }
}

class _FailStorage extends MemoryStorage {
  @override
  Future<void> saveDraft(String scope, String value) async =>
      throw StateError('disk full');
}

void main() {
  test('all source keys exist in each locale with useful article and account translations', () {
    expect(nativeSiteMessages.keys, unorderedEquals(['zh', 'ja', 'en']));
    for (final messages in nativeSiteMessages.values) {
      expect(messages.length, greaterThanOrEqualTo(314));
      expect(messages.keys, unorderedEquals(nativeSiteMessages['zh']!.keys));
      expect(messages.values.every((value) => value.isNotEmpty), isTrue);
    }
    expect(siteMessage('en', 'stage'), 'Main Stage');
    expect(siteMessage('ja', 'editorTitle'), '記事エディター');
    expect(siteMessage('en', '__missing__', fallback: 'Fallback'), 'Fallback');
  });
  test('native supplemental UI labels keep identical non-empty locale keys and interpolate asset pagination', () {
    expect(
      nativeSiteSupplementalMessages.keys,
      unorderedEquals(['zh', 'ja', 'en']),
    );
    for (final messages in nativeSiteSupplementalMessages.values) {
      expect(messages.length, greaterThan(500));
      expect(
        messages.keys,
        unorderedEquals(nativeSiteSupplementalMessages['zh']!.keys),
      );
      expect(messages.values.every((value) => value.isNotEmpty), isTrue);
    }
    expect(
      siteMessage(
        'en',
        'nativeAssetPagination',
        params: {'total': 24, 'page': 2, 'pages': 3},
      ),
      '24 items · Page 2 / 3',
    );
    expect(
      siteMessage(
        'ja',
        'nativeAssetPagination',
        params: {'total': 24, 'page': 2, 'pages': 3},
      ),
      '24件 · 2 / 3ページ',
    );
  });
  test(
    'locale defaults to Chinese and persists across accounts and restart',
    () async {
      final storage = MemoryStorage();
      final first = LocaleController(storage);
      expect(first.locale, const Locale('zh'));
      await first.restore();
      await first.setLanguage('ja');
      first.dispose();
      final second = LocaleController(storage);
      addTearDown(second.dispose);
      await second.restore();
      expect(second.language, 'ja');
      expect(storage.drafts, {LocaleController.storageKey: 'ja'});
      expect(storage.secrets, isEmpty);
    },
  );
  test('invalid values never become an unsupported locale', () async {
    for (final value in ['', 'invalid', 'en-US']) {
      final storage = MemoryStorage()
        ..drafts[LocaleController.storageKey] = value;
      final locale = LocaleController(storage);
      await locale.restore();
      expect(locale.language, 'zh');
      expect(await locale.setLanguage(value), isFalse);
      locale.dispose();
    }
  });
  test(
    'late persisted value never replaces the latest visible choice',
    () async {
      final storage = _DelayedStorage();
      final current = LocaleController(storage);
      addTearDown(current.dispose);
      final restore = current.restore();
      final write = current.setLanguage('en');
      storage.read.complete('ja');
      await restore;
      expect(current.language, 'en');
      await Future<void>.delayed(Duration.zero);
      storage.gates.single.complete();
      expect(await write, isTrue);
      expect(storage.drafts[LocaleController.storageKey], 'en');
    },
  );
  test(
    'quick selections save sequentially so an older write cannot win',
    () async {
      final storage = _DelayedStorage();
      final current = LocaleController(storage);
      addTearDown(current.dispose);
      final first = current.setLanguage('ja'),
          second = current.setLanguage('en');
      expect(current.language, 'en');
      await Future<void>.delayed(Duration.zero);
      expect(storage.writes, ['ja']);
      storage.gates.first.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(storage.writes, ['ja', 'en']);
      storage.gates.last.complete();
      await second;
      expect(storage.drafts[LocaleController.storageKey], 'en');
    },
  );
  test(
    'failed writes keep visible choice and disposed restore does not notify',
    () async {
      final failed = LocaleController(_FailStorage());
      addTearDown(failed.dispose);
      expect(await failed.setLanguage('en'), isFalse);
      expect(failed.language, 'en');
      final storage = _DelayedStorage();
      final current = LocaleController(storage);
      final restoring = current.restore();
      current.dispose();
      storage.read.complete('ja');
      await restoring;
      expect(current.language, 'zh');
      expect(await current.setLanguage('en'), isFalse);
    },
  );
  testWidgets(
    'const SiteText responds to language while user-authored labels stay literal and Text semantics survive',
    (tester) async {
      final locale = LocaleController(MemoryStorage());
      addTearDown(locale.dispose);
      await tester.pumpWidget(
        SiteLocaleScope(
          controller: locale,
          child: const MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  SiteText(
                    '主舞台',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    semanticsLabel: 'Navigation',
                  ),
                  SiteText('主舞台', translate: false),
                  SiteText('Editor', translationKey: 'editorTitle'),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('主舞台'), findsNWidgets(2));
      await locale.setLanguage('en');
      await tester.pumpAndSettle();
      expect(find.text('Main Stage'), findsOneWidget);
      expect(find.text('主舞台'), findsOneWidget);
      expect(find.text('Article editor'), findsOneWidget);
      final text = tester.widget<Text>(find.text('Main Stage'));
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.textAlign, TextAlign.center);
      expect(text.semanticsLabel, 'Navigation');
    },
  );
  testWidgets('global language menu changes locale and writes preference', (
    tester,
  ) async {
    final storage = MemoryStorage();
    final current = LocaleController(storage);
    addTearDown(current.dispose);
    await tester.pumpWidget(
      SiteLocaleScope(
        controller: current,
        child: const MaterialApp(home: Scaffold(body: SiteLanguageMenu())),
      ),
    );
    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, '日本語'));
    await tester.pumpAndSettle();
    expect(current.language, 'ja');
    expect(storage.drafts[LocaleController.storageKey], 'ja');
    expect(tester.takeException(), isNull);
  });
}
