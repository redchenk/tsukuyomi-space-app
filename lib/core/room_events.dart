import 'dart:async';
import 'dart:convert';

class RoomServerEvent {
  const RoomServerEvent(this.type, this.data, {this.id = ''});
  final String type, id;
  final Map<String, dynamic> data;
}

/// Named SSE events, including CRLF and UTF-8 split across transport chunks.
Stream<RoomServerEvent> decodeRoomEvents(Stream<List<int>> bytes) async* {
  var type = 'message', id = '';
  final data = <String>[];
  var size = 0;
  RoomServerEvent? flush() {
    if (data.isEmpty) return null;
    try {
      final value = jsonDecode(data.join('\n'));
      return value is Map
          ? RoomServerEvent(type, Map<String, dynamic>.from(value), id: id)
          : null;
    } on FormatException {
      return null;
    }
  }

  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      final event = flush();
      if (event != null) yield event;
      type = 'message';
      data.clear();
      size = 0;
      continue;
    }
    if (line.startsWith(':')) continue;
    final at = line.indexOf(':');
    final field = at < 0 ? line : line.substring(0, at);
    var value = at < 0 ? '' : line.substring(at + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        type = value;
      case 'id':
        if (!value.contains('\u0000')) id = value;
      case 'data':
        size += value.length;
        if (size > 512 * 1024) throw const FormatException('事件内容过大');
        data.add(value);
    }
  }
  // SSE dispatches only complete blank-line-terminated frames.
}

abstract interface class SiteRoomEventService {
  Stream<RoomServerEvent> roomEvents(String site);
}
