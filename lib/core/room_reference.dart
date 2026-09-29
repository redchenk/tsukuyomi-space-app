import 'dart:convert';

import 'room_reference_data.dart';

class RoomReference {
  static final Map<String, dynamic> data =
      jsonDecode(roomReferenceJson) as Map<String, dynamic>;
  static Future<void> load() async {}
  static List<Map<String, dynamic>> rows(String key) =>
      (data[key] as List? ?? [])
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
  static Map<String, dynamic> map(String key) =>
      Map<String, dynamic>.from(data[key] as Map? ?? {});
}
