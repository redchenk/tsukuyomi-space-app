import 'package:flutter/material.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/main.dart';

import '../test/support/fakes.dart';

// Guest-only visual preview. Production uses main.dart and secure device storage.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = RoomController(
    storage: MemoryStorage(),
    chat: FakeChat(),
    site: SiteClient(),
    voice: SilentVoice(),
  );
  await controller.initialize();
  runApp(TsukuyomiApp(controller: controller));
}
