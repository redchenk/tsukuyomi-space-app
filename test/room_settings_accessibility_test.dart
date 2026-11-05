import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/locale_controller.dart';
import 'package:tsukuyomi_space_app/core/site_theme.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/settings/settings_page.dart';

import 'support/fakes.dart';

void main() {
  for (final width in [320.0, 390.0]) {
    for (final language in ['en', 'ja']) {
      testWidgets(
        'settings categories fit enlarged text at $width in $language',
        (tester) async {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final previousErrorHandler = FlutterError.onError;
          FlutterError.onError = (details) {
            debugPrint(details.toString());
            previousErrorHandler?.call(details);
          };
          addTearDown(() => FlutterError.onError = previousErrorHandler);
          final room = RoomController(
            storage: MemoryStorage(),
            chat: FakeChat(),
            site: FakeSite(),
            voice: SilentVoice(),
          );
          await room.initialize();
          final locale = LocaleController(room.storage);
          await locale.setLanguage(language);
          addTearDown(locale.dispose);
          addTearDown(room.dispose);
          await tester.pumpWidget(
            SiteLocaleScope(
              controller: locale,
              child: MaterialApp(
                theme: siteTheme(false),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(1.3)),
                  child: child!,
                ),
                home: RoomSettingsPage(controller: room),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final id in roomSections.keys) {
            final entry = find.byKey(Key('settings-category-$id'));
            await tester.ensureVisible(entry);
            await tester.tap(entry);
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$id at $width / $language',
            );
            final home = find.text(
              language == 'en' ? 'All settings' : 'すべての設定',
            );
            await tester.ensureVisible(home);
            await tester.tap(home);
            await tester.pumpAndSettle();
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
