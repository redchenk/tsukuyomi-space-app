import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/qq_auth.dart';

import 'support/fakes.dart';

class BrowserPlatform extends InAppWebViewPlatform {
  final views = <BrowserView>[];
  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => EmptyCookies(params);
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = BrowserView(params);
    views.add(view);
    return view;
  }
}

class EmptyCookies extends PlatformCookieManager {
  EmptyCookies(super.params) : super.implementation();
  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async => [];
}

class BrowserController extends PlatformInAppWebViewController {
  BrowserController()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'fixture'),
      );
  WebUri url = WebUri('https://xui.ptlogin2.qq.com/cgi-bin/xlogin');
  @override
  Future<WebUri?> getUrl() async => url;
}

class BrowserView extends PlatformInAppWebViewWidget {
  BrowserView(super.params) : super.implementation();
  final nativeController = BrowserController();
  late final controller = InAppWebViewController.fromPlatform(
    platform: nativeController,
  );
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController c) =>
      InAppWebViewController.fromPlatform(platform: c) as T;
  @override
  void dispose() {}
}

void main() {
  testWidgets(
    'QQ popup preserves its window and invokes the external client without losing web login',
    (tester) async {
      final oldPlatform = InAppWebViewPlatform.instance;
      final platform = BrowserPlatform();
      InAppWebViewPlatform.instance = platform;
      addTearDown(() {
        InAppWebViewPlatform.instance = oldPlatform;
        debugDefaultTargetPlatformOverride = null;
      });
      final launches = <String>[];
      var installed = true;
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        launches.add('${(call.arguments as Map)['url']}');
        return installed;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final c = RoomController(
        storage: MemoryStorage(),
        chat: FakeChat(),
        voice: SilentVoice(),
        site: SiteClient(
          client: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'success': true,
                'data': {
                  'qqOAuthStartUrl':
                      'https://yachiyo.hk/api/auth/oauth/qq/start',
                },
              }),
              200,
            ),
          ),
        ),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(showQQAuthorization(context, c)),
              child: const Text('QQ'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('QQ'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final parent = platform.views.single;
      final opened = await parent.params.onCreateWindow!(
        parent.controller,
        CreateWindowAction(
          windowId: 7,
          isForMainFrame: true,
          request: URLRequest(url: WebUri('about:blank')),
        ),
      );
      expect(opened, isTrue);
      await tester.pump();
      final popup = platform.views.last;
      expect(popup.params.windowId, 7);
      expect(popup.params.initialUrlRequest, isNull);
      popup.nativeController.url = WebUri('about:blank');
      final action = NavigationAction(
        isForMainFrame: true,
        request: URLRequest(
          url: WebUri('wtloginmqq://ptlogin/qlogin?qrcode=fixture'),
        ),
      );
      expect(
        await popup.params.shouldOverrideUrlLoading!(popup.controller, action),
        NavigationActionPolicy.CANCEL,
      );
      expect(launches, ['wtloginmqq://ptlogin/qlogin?qrcode=fixture']);
      installed = false;
      await popup.params.shouldOverrideUrlLoading!(popup.controller, action);
      await tester.pump();
      expect(find.textContaining('无法打开 QQ'), findsOneWidget);
      expect(find.byType(InAppWebView, skipOffstage: false), findsNWidgets(2));
      popup.params.onCloseWindow!(popup.controller);
      await tester.pump();
      expect(find.byType(InAppWebView), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
