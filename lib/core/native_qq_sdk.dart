import 'dart:async';

import 'package:flutter/services.dart';

import 'models.dart';

class NativeQQSdk {
  static const appId = '1905926637';
  static const channel = MethodChannel('space.tsukuyomi/qq_auth');

  Future<Map<String, String>?> login() async {
    try {
      final result = await channel
          .invokeMapMethod<String, String>('login', {'consent': true})
          .timeout(const Duration(seconds: 130));
      if (result == null ||
          result['clientId'] != appId ||
          !RegExp(r'^[A-Za-z0-9_-]{16,256}$')
              .hasMatch(result['accessToken'] ?? '') ||
          !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(result['openId'] ?? '')) {
        throw const ApiFailure('QQ 返回的授权信息无效，请重试');
      }
      return result;
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') return null;
      throw ApiFailure(switch (error.code) {
        'not_installed' => '请安装或更新 QQ 后重试，也可以使用邮箱或密码登录',
        'timeout' => 'QQ 授权超时，请重试',
        'busy' => 'QQ 授权正在进行',
        'provider' => 'QQ 授权失败，请检查应用审核状态及调试账号后重试',
        _ => '无法启动 QQ 原生授权，请更新 QQ 后重试',
      });
    } on TimeoutException {
      throw const ApiFailure('QQ 授权超时，请重试');
    } on MissingPluginException {
      throw const ApiFailure('当前安装包不支持 QQ 原生登录，请更新 App');
    }
  }
}
