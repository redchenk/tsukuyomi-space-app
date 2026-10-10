import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/app_update_release.dart';
import 'package:tsukuyomi_space_app/core/app_update_service.dart';

void main() {
  test(
    'official GitHub release detects and downloads a verified installer',
    () async {
      final cache = Directory('artifacts/app-update-live');
      await cache.create(recursive: true);
      final service = AppUpdateService(
        cacheDirectory: () async => cache.absolute,
      );
      final release = await service.check(
        AppVersion.parse('v0.6.9-beta.1')!,
        UpdatePlatform.ios,
        previews: true,
        token: UpdateCancellation(),
      );
      expect(release, isNotNull);
      final file = await service.download(
        release!,
        UpdateCancellation(),
        (_, _, _) {},
      );
      await service.verify(file, release, UpdateCancellation());
      expect(await file.length(), release.installer.size);
      // ignore: avoid_print
      print(
        'TSUKUYOMI_UPDATE_GITHUB_OK ${release.tag} ${release.installer.name} size=${release.installer.size} sha256=${release.installer.digest}',
      );
    },
    skip: !const bool.fromEnvironment('RUN_APP_UPDATE_NETWORK'),
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
