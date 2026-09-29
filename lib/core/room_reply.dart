/// Mirrors the website's roomReplyPresentation.mjs; stored turns stay intact.
List<String> splitRoomReply(String value) {
  final text = value.replaceAll(RegExp(r'\r\n?'), '\n').trim();
  if (text.isEmpty) return [];
  final parts = <String>[], brackets = <String>[];
  const closing = {
    '(': ')',
    '（': '）',
    '[': ']',
    '【': '】',
    '「': '」',
    '『': '』',
    '“': '”',
  };
  var start = 0, inline = false, fenced = false;
  void push(int end) {
    final part = text.substring(start, end).trim();
    if (part.isNotEmpty) parts.add(part);
    start = end;
  }

  String charAt(int index) =>
      index >= 0 && index < text.length ? text[index] : '\u0000';
  bool isUrl(String token) =>
      RegExp(r'https?://|www\.', caseSensitive: false).hasMatch(token);
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (text.startsWith('```', i)) {
      fenced = !fenced;
      i += 2;
      continue;
    }
    if (fenced) continue;
    if (char == '`') inline = !inline;
    if (inline) continue;
    if (closing.containsKey(char)) {
      brackets.add(closing[char]!);
    } else if (brackets.isNotEmpty && char == brackets.last) {
      brackets.removeLast();
    }
    if (brackets.isNotEmpty) continue;
    final token =
        RegExp(r'\S+$').firstMatch(text.substring(start, i + 1))?.group(0) ??
        '';
    final period =
        char == '.' &&
        (i + 1 == text.length || RegExp(r'\s').hasMatch(charAt(i + 1))) &&
        !isUrl(token) &&
        !RegExp(
          r'^(?:Mr|Mrs|Ms|Dr|Prof|St|vs|etc|e\.g|i\.e|[A-Z])\.$',
          caseSensitive: false,
        ).hasMatch(token);
    final sentence =
        RegExp('[。！？]').hasMatch(char) ||
        (RegExp('[!?]').hasMatch(char) && !isUrl(token)) ||
        period ||
        (RegExp('[」』”]').hasMatch(char) &&
            RegExp('[。！？!?]').hasMatch(charAt(i - 1)));
    if (sentence) {
      while (RegExp('[。！？!?.…～~」』”’]').hasMatch(charAt(i + 1))) {
        i++;
      }
      push(i + 1);
    } else if (char == '\n' && charAt(i + 1) == '\n') {
      push(i);
      while (charAt(i + 1) == '\n') {
        i++;
      }
      start = i + 1;
    } else if ((i - start >= 140 && RegExp('[，,；;]').hasMatch(char)) ||
        (i - start >= 240 && RegExp(r'\s').hasMatch(char))) {
      if (!isUrl(token)) push(i + 1);
    }
  }
  push(text.length);
  return parts;
}
