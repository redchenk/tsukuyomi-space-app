import 'package:flutter/material.dart';

import 'locale_controller.dart';
import 'site_i18n_messages.dart';

export 'locale_controller.dart' show SiteLocaleScope, SiteLanguageMenu;

final _sourceKeys = <String, String>{
  for (final messages in [
    ...nativeSiteMessages.values,
    ...nativeSiteSupplementalMessages.values,
  ])
    for (final entry in messages.entries) entry.value: entry.key,
};

String siteMessage(
  String language,
  String key, {
  String? fallback,
  Map<String, Object> params = const {},
}) {
  var result =
      nativeSiteSupplementalMessages[language]?[key] ??
      nativeSiteMessages[language]?[key] ??
      nativeSiteSupplementalMessages['zh']?[key] ??
      nativeSiteMessages['zh']?[key] ??
      fallback ??
      key;
  for (final entry in params.entries) {
    result = result.replaceAll('{${entry.key}}', '${entry.value}');
  }
  return result;
}

String siteTr(
  BuildContext context,
  String key, {
  String? fallback,
  Map<String, Object> params = const {},
}) => siteMessage(
  SiteLocaleScope.maybeOf(context)?.language ?? 'zh',
  key,
  fallback: fallback,
  params: params,
);

/// Use only for application copy. Article, message and account data stay literal.
String siteTranslate(BuildContext context, String source) {
  final key = _sourceKeys[source];
  return key == null ? source : siteTr(context, key, fallback: source);
}

/// Const application labels still subscribe to locale changes during build.
/// Use [translate] false for user-authored text, and [translationKey] for copy
/// whose Chinese source is shared by keys with different meanings.
class SiteText extends StatelessWidget {
  const SiteText(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis = TextWidthBasis.parent,
    this.textHeightBehavior,
    this.selectionColor,
    this.translate = true,
    this.translationKey,
  });
  final String data;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel, semanticsIdentifier;
  final TextWidthBasis textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;
  final bool translate;
  final String? translationKey;
  @override
  Widget build(BuildContext context) => Text(
    translate
        ? translationKey == null
              ? siteTranslate(context, data)
              : siteTr(context, translationKey!, fallback: data)
        : data,
    style: style,
    strutStyle: strutStyle,
    textAlign: textAlign,
    textDirection: textDirection,
    locale: locale,
    softWrap: softWrap,
    overflow: overflow,
    textScaler: textScaler,
    maxLines: maxLines,
    semanticsLabel: semanticsLabel,
    semanticsIdentifier: semanticsIdentifier,
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
    selectionColor: selectionColor,
  );
}
