import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../core/storage.dart';

/// Preserve only the receipt digest and UUID. Never persist private letter text.
class DriftSubmissions {
  DriftSubmissions(this.storage);
  final RoomStorage storage;
  static String uuid() {
    final r = Random.secure(), bytes = List.generate(16, (_) => 0);
    for (var i = 0; i < 16; i++) {
      bytes[i] = r.nextInt(256);
    }
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  final receipts = <String, Map<String, dynamic>>{};
  Future<Map<String, dynamic>> prepare(
    String scope,
    Map<String, dynamic> payload,
  ) async {
    final digest = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    Map<String, dynamic>? previous = receipts[scope];
    if (previous == null) {
      try {
        previous = Map<String, dynamic>.from(
          jsonDecode(await storage.draft('drift-receipt:$scope')),
        );
      } catch (_) {}
    }
    final receipt = previous?['fingerprint'] == digest
        ? previous!
        : {'fingerprint': digest, 'requestId': uuid()};
    receipts[scope] = receipt;
    await storage.saveDraft('drift-receipt:$scope', jsonEncode(receipt));
    return {...payload, 'requestId': receipt['requestId']};
  }

  Future<void> complete(String scope, String id) async {
    if (receipts[scope]?['requestId'] != id) return;
    receipts.remove(scope);
    await storage.saveDraft('drift-receipt:$scope', '');
  }
}
