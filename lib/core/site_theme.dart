import 'package:flutter/material.dart';

import 'season_theme.dart';

/// Website editorial.css / material-components.css at 4b0ade7 (2026-10-06).
/// Keep these semantic roles shared by Room, content pages and Material controls.
class SitePalette {
  const SitePalette(this.dark, {this.season = SiteSeason.spring});
  final SiteSeason season;
  static SitePalette of(BuildContext context) =>
      Theme.of(context).extension<SiteSeasonColors>()?.palette ??
      SitePalette(Theme.of(context).brightness == Brightness.dark);
  Color seasonal(Color spring, int slot) => season == SiteSeason.spring
      ? spring
      : Color(_colors[season]![dark ? 1 : 0][slot]);
  final bool dark;
  static const brand = Color(0xffac4d6d);
  static const brandHover = Color(0xff923d5b);
  static const cardRadius = 24.0;
  static const fieldRadius = 16.0;
  static const dialogRadius = 28.0;
  Color get background =>
      seasonal(dark ? const Color(0xff151923) : const Color(0xfff7f9fc), 0);
  Color get surface =>
      seasonal(dark ? const Color(0xff222836) : Colors.white, 1);
  Color get low =>
      seasonal(dark ? const Color(0xff1b202c) : const Color(0xfff8f9fc), 2);
  Color get soft =>
      seasonal(dark ? const Color(0xff2c3342) : const Color(0xffeef2f8), 3);
  Color get ink =>
      seasonal(dark ? const Color(0xffedf0f7) : const Color(0xff202b46), 4);
  Color get muted =>
      seasonal(dark ? const Color(0xffb5bccb) : const Color(0xff626e84), 5);
  Color get line =>
      seasonal(dark ? const Color(0xff394153) : const Color(0xffdfe6f0), 6);
  Color get accent => seasonal(dark ? const Color(0xffe5a4bc) : brand, 7);
  Color get selected =>
      seasonal(dark ? const Color(0xff3a2b39) : const Color(0xfff4e6ec), 8);
  Color get cyan =>
      seasonal(dark ? const Color(0xffa9cadc) : const Color(0xff386c85), 9);
  Color get primary => seasonal(brand, 10);
  Color get primaryHover => seasonal(brandHover, 11);
  Color get success => dark ? const Color(0xff8ddab3) : const Color(0xff23734e);
  Color get warning => dark ? const Color(0xffefd196) : const Color(0xff8a6112);
  Color get danger => dark ? const Color(0xffffacba) : const Color(0xffad344b);
  Color get hover => Color.alphaBlend(accent.withValues(alpha: .08), surface);
  Color get pressed => Color.alphaBlend(accent.withValues(alpha: .12), surface);
}

const _colors = <SiteSeason, List<List<int>>>{
  SiteSeason.summer: [
    [
      0xfff3f8fa,
      0xfffcfeff,
      0xfff4f8fb,
      0xffe7f0f5,
      0xff203443,
      0xff526b7a,
      0xffd4e2e9,
      0xff28647d,
      0xffe0edf4,
      0xff377781,
      0xff28647d,
      0xff1e5269,
    ],
    [
      0xff111c25,
      0xff1c2b36,
      0xff16242e,
      0xff263946,
      0xffe5f1f7,
      0xffabc1ce,
      0xff3a5263,
      0xffa0cde2,
      0xff263f50,
      0xff9ad4d9,
      0xff316b86,
      0xff255b75,
    ],
  ],
  SiteSeason.autumn: [
    [
      0xfffbf7f1,
      0xfffffdf9,
      0xfffaf6ef,
      0xfff3eade,
      0xff43332a,
      0xff776555,
      0xffe8dccc,
      0xff97562b,
      0xfff5e7d8,
      0xff627258,
      0xff97562b,
      0xff804720,
    ],
    [
      0xff211b17,
      0xff302721,
      0xff27201b,
      0xff40342a,
      0xfff6ebdc,
      0xffcfbca5,
      0xff594839,
      0xffe5b481,
      0xff493425,
      0xffb7c8a8,
      0xff9d602f,
      0xff885025,
    ],
  ],
  SiteSeason.winter: [
    [
      0xfff5f8fc,
      0xfffdfeff,
      0xfff2f6fb,
      0xffe8edf6,
      0xff2a3550,
      0xff586a84,
      0xffd8e1ee,
      0xff46628d,
      0xffe5ecf8,
      0xff487487,
      0xff46628d,
      0xff354f78,
    ],
    [
      0xff151c2c,
      0xff222c40,
      0xff1b2435,
      0xff2d3950,
      0xffeaf0ff,
      0xffb2bfd8,
      0xff41516d,
      0xffb4c9f4,
      0xff2c3c59,
      0xffa6cede,
      0xff4f6897,
      0xff405784,
    ],
  ],
};

class SiteSeasonColors extends ThemeExtension<SiteSeasonColors> {
  const SiteSeasonColors(this.palette);
  final SitePalette palette;
  @override
  SiteSeasonColors copyWith({SitePalette? palette}) =>
      SiteSeasonColors(palette ?? this.palette);
  @override
  SiteSeasonColors lerp(covariant SiteSeasonColors? other, double t) =>
      t < .5 ? this : other ?? this;
}

ThemeData siteTheme(bool dark, {SiteSeason season = SiteSeason.spring}) {
  final p = SitePalette(dark, season: season);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: p.primary,
        brightness: dark ? Brightness.dark : Brightness.light,
      ).copyWith(
        primary: p.accent,
        onPrimary: dark ? const Color(0xff30202a) : Colors.white,
        primaryContainer: p.selected,
        onPrimaryContainer: p.ink,
        secondary: p.cyan,
        secondaryContainer: p.soft,
        onSecondaryContainer: p.ink,
        surface: p.surface,
        surfaceContainerLowest: p.background,
        surfaceContainerLow: p.low,
        surfaceContainer: p.surface,
        surfaceContainerHigh: p.soft,
        surfaceContainerHighest: p.soft,
        onSurface: p.ink,
        onSurfaceVariant: p.muted,
        outline: p.line,
        outlineVariant: p.line,
        error: p.danger,
        errorContainer: Color.alphaBlend(
          p.danger.withValues(alpha: .12),
          p.surface,
        ),
        onErrorContainer: p.danger,
      );
  OutlineInputBorder field(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(SitePalette.fieldRadius),
        borderSide: BorderSide(color: color, width: width),
      );
  final overlay = WidgetStateProperty.resolveWith<Color?>((states) {
    if (states.contains(WidgetState.disabled)) return null;
    if (states.contains(WidgetState.pressed)) {
      return p.accent.withValues(alpha: .12);
    }
    if (states.contains(WidgetState.hovered) ||
        states.contains(WidgetState.focused)) {
      return p.accent.withValues(alpha: .08);
    }
    return null;
  });
  return ThemeData(
    useMaterial3: true,
    extensions: [SiteSeasonColors(p)],
    colorScheme: scheme,
    scaffoldBackgroundColor: p.background,
    dividerColor: p.line,
    disabledColor: p.muted.withValues(alpha: .48),
    fontFamilyFallback: const [
      'PingFang SC',
      'Microsoft YaHei',
      'Noto Sans CJK SC',
    ],
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.low,
      hintStyle: TextStyle(color: p.muted),
      border: field(p.line),
      enabledBorder: field(p.line),
      disabledBorder: field(p.line.withValues(alpha: .48)),
      focusedBorder: field(p.accent, 2),
      errorBorder: field(p.danger),
      focusedErrorBorder: field(p.danger, 2),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style:
          FilledButton.styleFrom(
            foregroundColor: Colors.white,
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            elevation: 0,
            shape: const StadiumBorder(),
          ).copyWith(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return p.ink.withValues(alpha: .12);
              }
              return states.contains(WidgetState.hovered)
                  ? p.primaryHover
                  : p.primary;
            }),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? p.muted.withValues(alpha: .48)
                  : Colors.white,
            ),
          ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        side: BorderSide(color: p.line),
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        shape: const StadiumBorder(),
      ).copyWith(overlayColor: overlay),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        shape: const StadiumBorder(),
      ).copyWith(overlayColor: overlay),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: p.ink,
        minimumSize: const Size(44, 44),
      ).copyWith(overlayColor: overlay),
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SitePalette.cardRadius),
        side: BorderSide(color: p.line),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SitePalette.dialogRadius),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(SitePalette.dialogRadius),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SitePalette.fieldRadius),
      ),
    ),
    appBarTheme: AppBarThemeData(
      backgroundColor: p.surface,
      foregroundColor: p.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.soft,
      selectedColor: p.selected,
      side: BorderSide(color: p.line),
      shape: const StadiumBorder(),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
