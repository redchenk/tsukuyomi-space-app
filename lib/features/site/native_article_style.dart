import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;

import '../room/room_style.dart';

// Matches shared/article-markdown.css and frontend/styles/editorial.css.
const articleCodeBackground = Color(0xff182132);
const articleCodeHeader = Color(0xff232e43);
const articleCodeInk = Color(0xffe7edf7);
const articleCodeColors = <String, Color>{
  'comment': Color(0xffa0adc0),
  'quote': Color(0xffa0adc0),
  'keyword': Color(0xffc5afff),
  'selector-tag': Color(0xffc5afff),
  'literal': Color(0xffc5afff),
  'type': Color(0xffc5afff),
  'string': Color(0xffa5dcc1),
  'attribute': Color(0xffa5dcc1),
  'addition': Color(0xffa5dcc1),
  'number': Color(0xfff0baa6),
  'symbol': Color(0xfff0baa6),
  'variable': Color(0xfff0baa6),
  'deletion': Color(0xfff0baa6),
  'title': Color(0xff98cfff),
  'built_in': Color(0xff98cfff),
  'attr': Color(0xff98cfff),
};
Color articleCalloutColor(String type) => switch (type) {
  'tip' => const Color(0xff429d85),
  'warning' => const Color(0xffb48b42),
  'caution' => const Color(0xffd57487),
  _ => const Color(0xff8b7cd8),
};
String articleCssColor(Color color) =>
    'rgba(${(color.r * 255).round()},${(color.g * 255).round()},'
    '${(color.b * 255).round()},${color.a})';

Map<String, String> nativeArticleStyles(
  dom.Element element,
  RoomStyle p, {
  required bool mobile,
  bool firstHeading = true,
}) {
  final tag = element.localName, classes = element.classes;
  final result = <String, String>{};
  final size = mobile ? 16.0 : 17.0;
  if (['h1', 'h2', 'h3', 'h4', 'h5', 'h6'].contains(tag)) {
    final headingSize = switch (tag) {
      'h1' => mobile ? 28 : 32,
      'h2' => mobile ? 23 : 26,
      'h3' => mobile ? 19 : 21,
      'h4' => 18,
      'h5' => size * 1.08,
      _ => size,
    };
    result.addAll({
      'font-size': '${headingSize}px',
      'font-weight': '700',
      'line-height': '1.45',
      'color': articleCssColor(p.ink),
      'margin': '1.8em 0 .7em',
    });
    if (tag == 'h2') {
      result.addAll({
        'padding-bottom': '10px',
        'border-bottom': '1px solid ${articleCssColor(p.line)}',
      });
    }
    if (element.previousElementSibling == null &&
        element.parent?.localName != 'li' &&
        firstHeading) {
      result['margin-top'] = '0';
    }
  }
  if (['p', 'ul', 'ol'].contains(tag)) {
    result['margin'] = '0 0 1.25em';
    if (tag == 'p') {
      result.addAll({'line-height': '1.62', 'color': articleCssColor(p.muted)});
    }
    if (tag != 'p') result['padding-left'] = '1.6em';
    if (element.parent?.localName == 'li' && tag != 'p') {
      result['margin'] = '.4em 0';
    }
    if (element.nextElementSibling == null &&
        (element.parent?.localName == 'blockquote' ||
            element.parent?.classes.contains('markdown-callout') == true)) {
      result['margin-bottom'] = '0';
    }
  }
  if (tag == 'a') {
    result.addAll({
      'color': articleCssColor(p.accent),
      'text-decoration': 'underline',
    });
  }
  if (tag == 'blockquote') {
    result.addAll({
      'border-left': '3px solid ${articleCssColor(p.accent)}',
      'background-color': articleCssColor(p.soft),
      'color': articleCssColor(p.muted),
      'padding': '16px 22px',
      'margin': '1.2em 0',
    });
  }
  if (tag == 'code' && element.parent?.localName != 'pre') {
    result.addAll({
      'font-family': 'monospace',
      'color': articleCssColor(p.ink),
      'background-color': articleCssColor(p.soft),
      'padding': '.08em .3em',
    });
  }
  if (tag == 'table') {
    result.addAll({
      'width': '100%',
      'border-collapse': 'collapse',
      'font-size': '.94em',
      'border': '0',
    });
  }
  if (tag == 'th' || tag == 'td') {
    final last = tag == 'td' && element.parent?.nextElementSibling == null;
    result.addAll({
      'padding': '.75em 1em',
      'min-width': '90px',
      'border': '0',
      'border-bottom': last ? '0' : '1px solid ${articleCssColor(p.line)}',
      'text-align': element.attributes['align'] ?? 'left',
    });
    if (tag == 'th') {
      result.addAll({
        'background-color': articleCssColor(p.soft),
        'font-weight': '600',
      });
    }
  }
  if (classes.contains('markdown-task')) result['list-style-type'] = 'none';
  if (classes.contains('markdown-callout-title') ||
      classes.contains('markdown-alert-title')) {
    result.addAll({
      'font-weight': '700',
      'color': articleCssColor(p.ink),
      'margin': '0 0 .55em',
    });
  }
  if (tag == 'mark') {
    final variant = classes.join(' ');
    final color = variant.contains('-secondary')
        ? const Color(0x4477b8cf)
        : variant.contains('-tertiary')
        ? const Color(0x44df9abd)
        : variant.contains('-error')
        ? const Color(0x44ed8282)
        : variant.contains('-tip')
        ? const Color(0x4457bd97)
        : const Color(0x44a48aea);
    result.addAll({
      'background-color': articleCssColor(color),
      'color': articleCssColor(p.muted),
      'padding': '.06em .2em',
    });
  }
  if (classes.contains('footnotes')) {
    result.addAll({
      'margin-top': '2em',
      'font-size': '.88em',
      'color': articleCssColor(p.muted),
    });
  }
  return result;
}
