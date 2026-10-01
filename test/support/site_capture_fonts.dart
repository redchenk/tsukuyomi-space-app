import 'dart:io';

import 'package:flutter/services.dart';

Future<void> loadSiteCaptureFonts() async {
  final override = const String.fromEnvironment('QA_SANS_FONT');
  final sans = override.isNotEmpty
      ? File(override)
      : Directory('/System/Library/AssetsV2/com_apple_MobileAsset_Font8')
            .listSync(recursive: true)
            .whereType<File>()
            .firstWhere((file) => file.path.endsWith('/PingFang.ttc'));
  final bytes = ByteData.sublistView(await sans.readAsBytes());
  for (final family in ['Roboto', 'PingFang SC']) {
    await (FontLoader(family)..addFont(Future.value(bytes))).load();
  }
  final serif = File(
    const String.fromEnvironment(
      'QA_SERIF_FONT',
      defaultValue: '/System/Library/Fonts/Supplemental/Songti.ttc',
    ),
  );
  await (FontLoader(
        'Songti SC',
      )..addFont(Future.value(ByteData.sublistView(await serif.readAsBytes()))))
      .load();
  await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
        rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
      ))
      .load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}
