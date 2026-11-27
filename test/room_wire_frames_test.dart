import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/model_protocol.dart';
import 'package:tsukuyomi_space_app/core/models.dart';

Stream<List<int>> bytesByOne(String s) =>
    Stream.fromIterable(utf8.encode(s).map((byte) => [byte]));

void main() {
  test('SSE separates split CRLF, lone CR and UTF-8 across reads', () async {
    final frames = await modelFrames(
      bytesByOne(
        ': ping\r\nevent: delta\rdata: 月🌙\r\ndata:  光\r\rdata: [DONE]\n',
      ),
    ).toList();
    expect(frames.single.event, 'delta');
    expect(frames.single.data, '月🌙\n 光');
  });
  test(
    'NDJSON accepts a final line and enforces byte limits before EOF',
    () async {
      final frames = await modelFrames(
        bytesByOne('月\r\n光'),
        ndjson: true,
      ).toList();
      expect(frames.map((f) => f.data), ['月', '光']);
      await expectLater(
        modelFrames(bytesByOne('月光'), eventBytes: 5).drain<void>(),
        throwsA(isA<ApiFailure>()),
      );
      await expectLater(
        modelFrames(bytesByOne('月光'), wireBytes: 5).drain<void>(),
        throwsA(isA<ApiFailure>()),
      );
    },
  );
}
