import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/locale_controller.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_theme.dart';
import 'package:tsukuyomi_space_app/features/settings/model_runtime_panel.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'expanded model controls support narrow screens, three languages and large fonts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final width in [360.0, 1280.0]) {
        tester.view.physicalSize = Size(width, 900);
        for (final language in ['zh', 'ja', 'en']) {
          for (final scale in [1.0, 2.0]) {
            final locale = LocaleController(MemoryStorage());
            await locale.setLanguage(language);
            await tester.pumpWidget(
              SiteLocaleScope(
                controller: locale,
                child: MaterialApp(
                  theme: siteTheme(false),
                  home: Scaffold(
                    body: MediaQuery(
                      data: MediaQueryData(
                        size: Size(width, 900),
                        textScaler: TextScaler.linear(scale),
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(22),
                        child: ModelRuntimePanel(
                          key: ValueKey('$width-$language-$scale'),
                          settings: const RoomSettings(
                            llmUrl: 'https://api.deepseek.com/chat/completions',
                            model: 'deepseek-chat',
                          ),
                          onChanged: (_) {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.byType(ExpansionTile));
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$width $language $scale',
            );
            await tester.pumpWidget(const SizedBox.shrink());
            locale.dispose();
          }
        }
      }
    },
  );
}
