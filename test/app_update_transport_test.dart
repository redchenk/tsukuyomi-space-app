import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/app_update_release.dart';
import 'package:tsukuyomi_space_app/core/app_update_service.dart';

class _Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = '$value';
  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, {String? location, Stream<List<int>>? bytes})
    : _bytes = bytes ?? Stream.value([1, 2, 3]) {
    if (location != null) headers.set('location', location);
  }
  final Stream<List<int>> _bytes;
  @override
  final int statusCode;
  @override
  final headers = _Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _bytes.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response);
  final _Response response;
  @override
  bool followRedirects = true;
  @override
  final headers = _Headers();
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  _Client(this.responses);
  final List<_Response> responses;
  final urls = <Uri>[];
  final requests = <_Request>[];
  bool closed = false;
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    urls.add(uri);
    final request = _Request(responses.removeAt(0));
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('follow only trusted release redirects without credentials; close HTTP client', () async {
    final client = _Client([
      _Response(
        302,
        location:
            'https://release-assets.githubusercontent.com/file?sig=public',
      ),
      _Response(200),
    ]);
    final bytes = await GithubUpdateTransport(clientFactory: () => client)
        .read(
          Uri.parse('$appRepository/releases/download/v0.6.12/file.exe'),
          UpdateCancellation(),
        )
        .expand((b) => b)
        .toList();
    expect(bytes, [1, 2, 3]);
    expect(client.urls.length, 2);
    expect(client.closed, true);
    for (final request in client.requests) {
      expect(request.followRedirects, false);
      expect(request.headers.value('authorization'), isNull);
      expect(request.headers.value('cookie'), isNull);
      expect(request.headers.value('accept-encoding'), 'identity');
    }
  });
  test(
    'reject untrusted redirects before opening the next connection',
    () async {
      for (final url in [
        'https://evil.example/installer',
        'http://github.com/installer',
        'https://user:secret@github.com/installer',
      ]) {
        final client = _Client([_Response(302, location: url)]);
        await expectLater(
          GithubUpdateTransport(clientFactory: () => client)
              .read(appReleasesApi, UpdateCancellation())
              .drain<void>(),
          throwsA(
            isA<UpdateFailure>().having((e) => e.code, 'code', 'untrusted'),
          ),
        );
        expect(client.urls.length, 1);
        expect(client.closed, true);
      }
    },
  );
  test('redirect loops are bounded and HTTP rate limits reported without response body', () async {
    final client = _Client(
      List.generate(
        6,
        (_) => _Response(302, location: 'https://github.com/again'),
      ),
    );
    await expectLater(
      GithubUpdateTransport(clientFactory: () => client)
          .read(appReleasesApi, UpdateCancellation())
          .drain<void>(),
      throwsA(isA<UpdateFailure>().having((e) => e.code, 'code', 'untrusted')),
    );
    expect(client.urls.length, 6);
    for (final status in [403, 429, 404, 500]) {
      await expectLater(
        GithubUpdateTransport(clientFactory: () => _Client([_Response(status)]))
            .read(appReleasesApi, UpdateCancellation())
            .drain<void>(),
        throwsA(
          isA<UpdateFailure>().having(
            (e) => e.code,
            'code',
            status == 403 || status == 429 ? 'rateLimit' : 'network',
          ),
        ),
      );
    }
  });
  test(
    'cancellation closes the active connection and stops subsequent output',
    () async {
      final token = UpdateCancellation();
      final client = _Client([
        _Response(
          200,
          bytes: Stream.fromIterable([
            [1],
            [2],
          ]),
        ),
      ]);
      final chunks = <List<int>>[];
      await expectLater(
        () async {
          await for (final chunk in GithubUpdateTransport(
            clientFactory: () => client,
          ).read(appReleasesApi, token)) {
            chunks.add(chunk);
            token.cancel();
          }
        }(),
        throwsA(
          isA<UpdateFailure>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      expect(chunks, [
        [1],
      ]);
      expect(client.closed, true);
    },
  );
}
