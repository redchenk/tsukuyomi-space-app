import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../room/room_style.dart';

/// Matches the website's SocialText tokens; user content remains plain text.
class PlazaSocialText extends StatefulWidget {
  const PlazaSocialText({
    super.key,
    required this.content,
    required this.onMention,
    required this.onTopic,
  });
  final String content;
  final ValueChanged<String> onMention, onTopic;
  @override
  State<PlazaSocialText> createState() => _PlazaSocialTextState();
}

class _PlazaSocialTextState extends State<PlazaSocialText> {
  static final _tokens = RegExp(
    r'(@([A-Za-z0-9_\-\u4e00-\u9fff\u3040-\u30ff]{2,32}))|(#([A-Za-z0-9_\-\u4e00-\u9fff\u3040-\u30ff]{2,28})#?)',
    unicode: true,
  );
  final _recognizers = <TapGestureRecognizer>[];
  late List<InlineSpan> _spans;

  void _parse() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    _spans = [];
    var last = 0;
    for (final match in _tokens.allMatches(widget.content)) {
      if (match.start > last) {
        _spans.add(TextSpan(text: widget.content.substring(last, match.start)));
      }
      final mention = match.group(2), topic = match.group(4);
      final recognizer = TapGestureRecognizer()
        ..onTap = () {
          if (mention != null) {
            widget.onMention(mention);
          } else {
            widget.onTopic(topic!);
          }
        };
      _recognizers.add(recognizer);
      _spans.add(
        TextSpan(
          text: match.group(0),
          style: TextStyle(color: RoomStyle(context).accent),
          recognizer: recognizer,
        ),
      );
      last = match.end;
    }
    if (last < widget.content.length) {
      _spans.add(TextSpan(text: widget.content.substring(last)));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _parse();
  }

  @override
  void didUpdateWidget(PlazaSocialText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) _parse();
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectableText.rich(
    TextSpan(children: _spans),
    style: const TextStyle(height: 1.7),
  );
}
