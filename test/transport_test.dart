import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/core/voice_service.dart';

void main() {
  test('SSE handles UTF-8 split into individual bytes and CRLF', () async {
    final source =
        ': ping\r\ndata: {"choices":[{"delta":{"content":"月光🌙"}}]}\r\n\r\ndata: [DONE]\r\n\r\n';
    final deltas = await decodeCompletion(
      Stream.fromIterable(utf8.encode(source).map((b) => [b])),
    ).toList();
    expect(deltas.join(), '月光🌙');
  });
  test('EOF without completion is rejected', () async {
    final stream = decodeCompletion(
      Stream.value(
        utf8.encode('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n'),
      ),
    );
    await expectLater(
      stream,
      emitsInOrder(['partial', emitsError(isA<ApiFailure>())]),
    );
  });
  test('length-limited completion is not successful', () async {
    final source =
        'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\n';
    await expectLater(
      decodeCompletion(Stream.value(utf8.encode(source))),
      emitsError(isA<ApiFailure>()),
    );
  });
  test('stop reason completes a stream without DONE marker', () async {
    final source =
        'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n';
    expect(await decodeCompletion(Stream.value(utf8.encode(source))).toList(), [
      'ok',
    ]);
  });
  test('provider error does not expose a provider response body', () async {
    final source =
        'data: {"error":{"message":"secret-key-in-provider-error"}}\n\n';
    await expectLater(
      decodeCompletion(Stream.value(utf8.encode(source))),
      emitsError(predicate((e) => !e.toString().contains('secret-key'))),
    );
  });
  test('remote HTTP and credentials embedded in URLs are rejected', () {
    expect(() => endpointUri('http://example.com'), throwsFormatException);
    expect(
      () => endpointUri('https://user:password@example.com'),
      throwsFormatException,
    );
    expect(
      endpointUri('http://localhost:11434/v1/chat/completions').port,
      11434,
    );
  });
  test(
    'site login captures only the user cookie and sends the expected contract',
    () async {
      var count = 0;
      final client = SiteClient(
        client: MockClient((request) async {
          expect(request.headers['Origin'], 'https://example.com');
          expect(request.followRedirects, false);
          if (count++ == 0) {
            expect(request.url.path, '/api/auth/login');
            expect(jsonDecode(request.body)['username'], 'alice');
            return http.Response(
              '{"success":true,"data":{"user":{"id":"a","username":"alice"}}}',
              200,
              headers: {
                'set-cookie': 'tsukuyomi_admin_session=; Path=/, tsukuyomi_session=abc.def; HttpOnly; Secure; Path=/',
              },
            );
          }
          expect(request.headers['Cookie'], 'tsukuyomi_session=abc.def');
          return http.Response(
            '{"success":true,"data":{"id":"a","username":"alice"}}',
            200,
          );
        }),
      );
      final account = await client.login(
        'https://example.com',
        'alice',
        'password',
      );
      expect(account.id, 'a');
      expect((await client.me('https://example.com')).username, 'alice');
      client.dispose();
    },
  );
  test(
    'PCM envelope distinguishes silence and speech and validates truncation',
    () {
      final bytes = Uint8List(44 + 3200);
      final b = ByteData.sublistView(bytes);
      void label(int at, String value) =>
          bytes.setRange(at, at + 4, ascii.encode(value));
      label(0, 'RIFF');
      b.setUint32(4, bytes.length - 8, Endian.little);
      label(8, 'WAVE');
      label(12, 'fmt ');
      b.setUint32(16, 16, Endian.little);
      b.setUint16(20, 1, Endian.little);
      b.setUint16(22, 1, Endian.little);
      b.setUint32(24, 16000, Endian.little);
      b.setUint32(28, 32000, Endian.little);
      b.setUint16(32, 2, Endian.little);
      b.setUint16(34, 16, Endian.little);
      label(36, 'data');
      b.setUint32(40, 3200, Endian.little);
      for (var i = 1600; i < 3200; i += 2) {
        b.setInt16(44 + i, 12000, Endian.little);
      }
      final envelope = WavEnvelope.parse(bytes);
      expect(envelope.at(Duration.zero), 0);
      expect(envelope.at(const Duration(milliseconds: 80)), greaterThan(.5));
      expect(envelope.duration, const Duration(milliseconds: 100));
      expect(
        () => WavEnvelope.parse(bytes.sublist(0, 60)),
        throwsFormatException,
      );
    },
  );
}
