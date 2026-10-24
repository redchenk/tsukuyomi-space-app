import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/model_runtime.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/official_api.dart';
import 'package:tsukuyomi_space_app/core/payments.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';

Map<String, dynamic> dashboard([String user = 'alice']) => {
  'enabled': true,
  'me': {
    'site_user_id': user,
    'account_id': 'official-$user',
    'operator': false,
  },
  'models': [
    {
      'id': 'deepseek-chat',
      'provider': 'deepseek',
      'enabled': true,
      'max_output_tokens': 2048,
    },
  ],
};
const official = RoomSettings(
  siteUrl: 'https://site.test',
  llmUrl: 'https://site.test/official-api/v1/chat/completions',
  model: 'deepseek-chat',
  apiKey: 'must-never-be-relayed',
);

Map<String, dynamic> appCheckout({
  String amount = '1.23',
  String id = 'TSorder',
}) => {
  'type': 'app',
  'appId': '2099000000000002',
  'environment': 'sandbox',
  'orderString': Uri(
    queryParameters: {
      'app_id': '2099000000000002',
      'method': 'alipay.trade.app.pay',
      'sign_type': 'RSA2',
      'sign': 'fixture',
      'biz_content': jsonEncode({
        'out_trade_no': id,
        'total_amount': amount,
        'product_code': 'QUICK_MSECURITY_PAY',
      }),
    },
  ).query,
};
void main() {
  test('money stays exact beyond JS integer precision and preserves all nine decimal places', () {
    expect(moneyAtoms('9007199254740993999'), '9007199254.740993999');
    expect(moneyAtoms('-10000001'), '-0.010000001');
    expect(moneyAtoms('1000000000'), '1.00');
    expect(rateAtoms('0.000000001'), '1');
    expect(rateAtoms('123.456789123'), '123456789123');
    expect(() => rateAtoms('1e3'), throwsA(isA<ApiFailure>()));
    expect(() => rateAtoms('1.0000000001'), throwsA(isA<ApiFailure>()));
  });
  test('official endpoint recognition rejects relative, cross-origin and credential-bearing addresses', () {
    expect(official.usesOfficialApi, true);
    for (final url in [
      '',
      '/official-api/v1/chat/completions',
      'https://evil.test/official-api/v1/chat/completions',
      'https://u:p@site.test/official-api/v1/chat/completions',
      '${official.llmUrl}?q=1',
    ]) {
      expect(official.copyWith(llmUrl: url).usesOfficialApi, false);
    }
    final settings = officialRoomSettings(official, dashboard());
    expect(settings.apiKey, isEmpty);
    expect(settings.flag('llmProxy'), false);
    expect(
      ModelRuntime(settings).resolveParameters()['maxOutputTokens']['value'],
      2048,
    );
    expect(ModelRuntime(settings).unsupported('image'), true);
    expect(
      () => officialDashboard(dashboard('bob'), 'alice'),
      throwsA(isA<ApiFailure>()),
    );
  });
  test('official transport uses only site cookies, the expected account and its raw JSON envelope', () async {
    final calls = <http.Request>[];
    final site = SiteClient(
      client: MockClient((request) async {
        calls.add(request);
        expect(request.followRedirects, false);
        return http.Response(jsonEncode({'revision': 2}), 200);
      }),
    )..setSessionCookie('https://site.test', 'tsukuyomi_session=fixture');
    addTearDown(site.dispose);
    final response = await site.officialRequest(
      'https://site.test',
      'POST',
      '/api/admin/settings',
      account: 'official-alice',
      body: {'revision': 1},
    );
    expect(response, {'revision': 2});
    expect(
      calls.single.url.toString(),
      'https://site.test/official-api/api/admin/settings',
    );
    expect(calls.single.headers['Cookie'], 'tsukuyomi_session=fixture');
    expect(calls.single.headers['Authorization'], isNull);
    expect(
      calls.single.headers['X-Official-Expected-Account'],
      'official-alice',
    );
    expect(
      () => site.officialRequest(
        'https://site.test',
        'POST',
        '/api/admin/settings',
      ),
      throwsA(isA<ApiFailure>()),
    );
    for (final path in [
      'https://evil.test/api/dashboard',
      '/api/../../admin',
      '/api/%2e%2e/secret',
    ]) {
      await expectLater(
        () => site.officialRequest('https://site.test', 'GET', path),
        throwsA(isA<ApiFailure>()),
      );
    }
    expect(calls.length, 1);
  });
  test('stale plugin responses cannot update another session', () async {
    final pending = Completer<http.Response>();
    final site = SiteClient(client: MockClient((request) => pending.future))
      ..setSessionCookie('https://site.test', 'tsukuyomi_session=a');
    addTearDown(site.dispose);
    final request = site.officialRequest(
      'https://site.test',
      'GET',
      '/api/dashboard',
    );
    final check = expectLater(
      request,
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 409)),
    );
    site.setSessionCookie('https://site.test', 'tsukuyomi_session=b');
    pending.complete(http.Response(jsonEncode(dashboard()), 200));
    await check;
  });
  test('official chat preflights identity, clamps output, and sends no provider key', () async {
    final calls = <http.Request>[];
    final llm =
        LlmClient(
            clientFactory: () => MockClient((request) async {
              calls.add(request);
              if (request.method == 'GET') {
                return http.Response(jsonEncode(dashboard()), 200);
              }
              expect(request.headers['Cookie'], 'tsukuyomi_session=a');
              expect(request.headers['Authorization'], isNull);
              expect(
                request.headers['X-Official-Expected-Account'],
                'official-alice',
              );
              final body = jsonDecode(request.body) as Map;
              expect(body['max_tokens'], 2048);
              expect(body['thinking'], {'type': 'disabled'});
              expect(body['stream_options'], {'include_usage': true});
              expect(request.body.contains('must-never-be-relayed'), false);
              return http.Response(
                jsonEncode({
                  'choices': [
                    {
                      'message': {'content': '连接成功'},
                      'finish_reason': 'stop',
                    },
                  ],
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          )
          ..siteCookie = 'tsukuyomi_session=a'
          ..siteAccountId = 'alice';
    expect(await llm.reply(official, [], '你好').join(), '连接成功');
    expect(calls.length, 2);
  });
  test('account mismatch stops before billing and insufficient funds never retries', () async {
    var posts = 0;
    for (final mismatch in [true, false]) {
      final llm =
          LlmClient(
              clientFactory: () => MockClient((request) async {
                if (request.method == 'GET') {
                  return http.Response(
                    jsonEncode(dashboard(mismatch ? 'bob' : 'alice')),
                    200,
                  );
                }
                posts++;
                return http.Response(
                  jsonEncode({
                    'error': {'message': 'insufficient'},
                  }),
                  402,
                );
              }),
            )
            ..siteCookie = 'tsukuyomi_session=a'
            ..siteAccountId = 'alice';
      await expectLater(
        llm.reply(official, [], '你好').join(),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.status,
            'status',
            mismatch ? 409 : 402,
          ),
        ),
      );
    }
    expect(posts, 1);
  });
  test('official image chat follows server capabilities and keeps the same site account', () async {
    const dataUrl =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jE1sAAAAASUVORK5CYII=';
    for (final vision in [null, false, 'true', true]) {
      var posts = 0;
      final data = dashboard();
      (data['models'] as List).first['capabilities'] = {'vision': vision};
      expect(
        ModelRuntime(officialRoomSettings(official, data)).unsupported('image'),
        vision != true,
      );
      final llm =
          LlmClient(
              clientFactory: () => MockClient((request) async {
                if (request.method == 'GET') {
                  return http.Response(jsonEncode(data), 200);
                }
                posts++;
                expect(request.headers['Cookie'], 'tsukuyomi_session=a');
                expect(
                  request.headers['X-Official-Expected-Account'],
                  'official-alice',
                );
                expect(request.headers['Authorization'], isNull);
                final body = jsonDecode(request.body) as Map;
                final parts =
                    (body['messages'] as List).last['content'] as List;
                expect(
                  parts
                      .where((p) => p['type'] == 'image_url')
                      .single['image_url']['url'],
                  dataUrl,
                );
                return http.Response(
                  jsonEncode({
                    'choices': [
                      {
                        'message': {'content': '看见了图片'},
                        'finish_reason': 'stop',
                      },
                    ],
                  }),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }),
            )
            ..siteCookie = 'tsukuyomi_session=a'
            ..siteAccountId = 'alice'
            ..image = {'dataUrl': dataUrl, 'type': 'image/png'};
      if (vision == true) {
        expect(await llm.reply(official, [], '看图').join(), '看见了图片');
        expect(posts, 1);
      } else {
        await expectLater(
          llm.reply(official, [], '看图').join(),
          throwsA(isA<ApiFailure>()),
        );
        expect(posts, 0);
      }
    }
  });
  test('native checkout encodes a signed WAP URL once and falls back only when Alipay is unavailable', () async {
    final opened = <Uri>[];
    final url = Uri.https('openapi.alipay.com', '/gateway.do', {
      'method': 'alipay.trade.wap.pay',
      'sign': 'a+b/=%',
      'subject': '月读 + 空间',
    }).toString();
    await AlipayCheckoutLauncher(
      open: (uri) async {
        opened.add(uri);
        return uri.scheme == 'https';
      },
    ).launch(url, mobile: true);
    expect(opened.length, 2);
    expect(opened.first.queryParameters['url'], url);
    expect(opened.first.query.contains('+'), false);
    expect(opened.last.toString(), url);
    for (final bad in [
      'https://evil.test/gateway.do?method=alipay.trade.wap.pay',
      'alipays://evil',
      'https://openapi.alipay.com:444/gateway.do?method=alipay.trade.wap.pay',
    ]) {
      expect(() => checkoutDestination(bad), throwsA(isA<ApiFailure>()));
    }
  });
  test('App SDK receives only the matching signed order; a 9000 callback cannot credit a wallet', () async {
    final sdkCalls = <String>[];
    final launcher = AlipayCheckoutLauncher(
      appPay: (order, sandbox) async {
        expect(sandbox, true);
        sdkCalls.add(order);
        return {'resultStatus': '9000', 'result': 'untrusted'};
      },
    );
    await launcher.payApp(appCheckout(), {'id': 'TSorder', 'amount': '1.23'});
    expect(sdkCalls.length, 1);
    await expectLater(
      launcher.payApp(appCheckout(amount: '0.01'), {
        'id': 'TSorder',
        'amount': '1.23',
      }),
      throwsA(isA<ApiFailure>()),
    );
    expect(sdkCalls.length, 1);
    final duplicate = appCheckout();
    duplicate['orderString'] += '&app_id=2099000000000003';
    await expectLater(
      launcher.payApp(duplicate, {'id': 'TSorder', 'amount': '1.23'}),
      throwsA(isA<ApiFailure>()),
    );
    final cancelled = AlipayCheckoutLauncher(
      appPay: (order, sandbox) async => {'resultStatus': '6001'},
    );
    await expectLater(
      cancelled.payApp(appCheckout(), {'id': 'TSorder', 'amount': '1.23'}),
      throwsA(isA<ApiFailure>()),
    );
  });
}
