import 'dart:convert';

/// Public task updates, separate from provider reasoning and executable actions.
const agentCommunicationPrompt =
    'Communicate in the user\'s language. For a multi-step task, give a short '
    'upfront plan and brief updates when changing stages or encountering a '
    'problem. For a simple task, keep the update to one sentence. Describe '
    'observable actions and results, never private reasoning. Avoid repetitive '
    'updates and raw protocol/JSON output. End with what changed, what was '
    'actually checked, and any remaining limitation. Scale detail to the task; '
    'do not claim completion or tests you have not performed.';

/// Reads only top-level string values from an incomplete JSON object. This is
/// display-only: actions still require complete JSON and schema validation.
class AgentJsonPreview {
  final _values = <String, StringBuffer>{};
  final _complete = <String>{};
  int _depth = 0;
  bool _quoted = false, _escape = false, _keyString = false;
  bool _expectKey = false, _expectValue = false;
  String _key = '', _unicode = '';
  StringBuffer _keyBuffer = StringBuffer();
  String? _capture;
  int? _surrogate;

  String? get type =>
      _complete.contains('type') ? _values['type']?.toString() : null;
  String value(String name) => _values[name]?.toString() ?? '';

  void add(String delta) {
    for (final code in delta.codeUnits) {
      if (_quoted) {
        if (_unicode.isNotEmpty) {
          _unicode += String.fromCharCode(code);
          if (_unicode.length == 5) {
            final decoded = int.tryParse(_unicode.substring(1), radix: 16);
            if (decoded != null) _append(decoded);
            _unicode = '';
          }
        } else if (_escape) {
          _escape = false;
          if (code == 117) {
            _unicode = 'u';
          } else {
            _append(switch (code) {
              98 => 8,
              102 => 12,
              110 => 10,
              114 => 13,
              116 => 9,
              _ => code,
            });
          }
        } else if (code == 92) {
          _escape = true;
        } else if (code == 34) {
          _quoted = false;
          if (_keyString) {
            _key = _keyBuffer.toString();
            _expectKey = false;
          } else if (_capture != null) {
            _complete.add(_capture!);
          }
          _capture = null;
          _surrogate = null;
        } else {
          _append(code);
        }
        continue;
      }
      if (code == 123 || code == 91) {
        _depth++;
        if (_depth == 1 && code == 123) _expectKey = true;
        _expectValue = false;
      } else if (code == 125 || code == 93) {
        _depth--;
      } else if (code == 34) {
        _quoted = true;
        _keyString = _depth == 1 && _expectKey;
        _keyBuffer = StringBuffer();
        _capture =
            _depth == 1 &&
                _expectValue &&
                ['type', 'commentary', 'text'].contains(_key)
            ? _key
            : null;
        if (_capture != null) _values[_capture!] = StringBuffer();
        _expectValue = false;
      } else if (_depth == 1 && code == 58) {
        _expectValue = true;
      } else if (_depth == 1 && code == 44) {
        _expectKey = true;
        _expectValue = false;
      }
    }
  }

  void _append(int code) {
    final buffer = _keyString ? _keyBuffer : _values[_capture];
    if (buffer == null) return;
    if (_surrogate != null) {
      if (code >= 0xdc00 && code <= 0xdfff) {
        buffer.writeCharCode(
          0x10000 + ((_surrogate! - 0xd800) << 10) + code - 0xdc00,
        );
        _surrogate = null;
        return;
      }
      buffer.writeCharCode(0xfffd);
      _surrogate = null;
    }
    if (code >= 0xd800 && code <= 0xdbff) {
      _surrogate = code;
    } else {
      buffer.writeCharCode(code);
    }
  }
}

/// SSE boundaries are decoded before parsing JSON; keep-alive comments are not
/// model progress and an EOF without a completion marker must remain an error.
Stream<Map<String, dynamic>> decodeAgentSse(Stream<List<int>> bytes) async* {
  final data = <String>[];
  var size = 0;
  Map<String, dynamic>? consume() {
    if (data.isEmpty) return null;
    final source = data.join('\n');
    data.clear();
    size = 0;
    if (source == '[DONE]') return {'agentStreamDone': true};
    return Map<String, dynamic>.from(jsonDecode(source) as Map);
  }

  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      final value = consume();
      if (value != null) yield value;
    } else if (line.startsWith('data:')) {
      final value = line.substring(5).trimLeft();
      size += value.length;
      if (size > 1024 * 1024) {
        throw const FormatException('Model event too large');
      }
      data.add(value);
    }
  }
  final value = consume();
  if (value != null) yield value;
}
