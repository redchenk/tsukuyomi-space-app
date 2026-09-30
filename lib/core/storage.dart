import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

abstract interface class RoomStorage {
  Future<RoomSettings> settings();
  Future<void> saveSettings(RoomSettings value);
  Future<String?> readSecret(String key);
  Future<void> writeSecret(String key, String? value);
  Future<List<ChatTurn>> history(String scope);
  Future<void> saveHistory(String scope, List<ChatTurn> value);
  Future<String> draft(String scope);
  Future<void> saveDraft(String scope, String value);
}

class DeviceRoomStorage implements RoomStorage {
  DeviceRoomStorage(this.preferences);
  final SharedPreferences preferences;
  final FlutterSecureStorage _secure = const FlutterSecureStorage(
    // Direct downloads have no Apple team signature. The login keychain works
    // with ad-hoc signing; the data-protection keychain requires a team profile.
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  @override
  Future<String?> readSecret(String key) => _secure.read(key: 'tsukuyomi.$key');
  @override
  Future<void> writeSecret(String key, String? value) =>
      value == null || value.isEmpty
      ? _secure.delete(key: 'tsukuyomi.$key')
      : _secure.write(key: 'tsukuyomi.$key', value: value);
  @override
  Future<RoomSettings> settings() async {
    final source = preferences.getString('settings');
    final data = source == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(source) as Map);
    // Upgrade the old implicit demo default without touching demo history.
    if (!preferences.containsKey('room-first-v6')) {
      data['demo'] = false;
      await preferences.setString('settings', jsonEncode(data));
      await preferences.setBool('room-first-v6', true);
    }
    return RoomSettings.fromJson(
      data,
      apiKey: await readSecret('llmKey') ?? '',
      ttsKey: await readSecret('ttsKey') ?? '',
      mcpKey: await readSecret('mcpKey') ?? '',
    );
  }

  @override
  Future<void> saveSettings(RoomSettings value) async {
    await writeSecret('llmKey', value.apiKey);
    await writeSecret('ttsKey', value.ttsKey);
    await writeSecret('mcpKey', value.mcpKey);
    if (!await preferences.setString('settings', jsonEncode(value.toJson()))) {
      throw const ApiFailure('设置保存失败');
    }
  }

  @override
  Future<List<ChatTurn>> history(String scope) async {
    final source = preferences.getString('history.$scope');
    if (source == null) return [];
    return (jsonDecode(source) as List)
        .map((j) => ChatTurn.fromJson(Map<String, dynamic>.from(j as Map)))
        .toList();
  }

  @override
  Future<void> saveHistory(String scope, List<ChatTurn> value) async {
    if (!await preferences.setString(
      'history.$scope',
      jsonEncode(value.map((t) => t.toJson()).toList()),
    )) {
      throw const ApiFailure('本地会话保存失败');
    }
  }

  @override
  Future<String> draft(String scope) async =>
      preferences.getString('draft.$scope') ?? '';
  @override
  Future<void> saveDraft(String scope, String value) async {
    if (!await preferences.setString('draft.$scope', value)) {
      throw const ApiFailure('草稿保存失败');
    }
  }
}
