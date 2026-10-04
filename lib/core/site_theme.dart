import 'package:flutter/material.dart';

/// Website editorial.css / material-components.css at dba4908 (2026-10-04).
/// Keep these semantic roles shared by Room, content pages and Material controls.
class SitePalette {
  const SitePalette(this.dark);
  final bool dark;
  static const brand = Color(0xffac4d6d);
  static const brandHover = Color(0xff923d5b);
  static const cardRadius = 24.0;
  static const fieldRadius = 16.0;
  static const dialogRadius = 28.0;
  Color get background =>
      dark ? const Color(0xff151923) : const Color(0xfff7f9fc);
  Color get surface => dark ? const Color(0xff222836) : Colors.white;
  Color get low => dark ? const Color(0xff1b202c) : const Color(0xfff8f9fc);
  Color get soft => dark ? const Color(0xff2c3342) : const Color(0xffeef2f8);
  Color get ink => dark ? const Color(0xffedf0f7) : const Color(0xff202b46);
  Color get muted => dark ? const Color(0xffb5bccb) : const Color(0xff626e84);
  Color get line => dark ? const Color(0xff394153) : const Color(0xffdfe6f0);
  Color get accent => dark ? const Color(0xffe5a4bc) : brand;
  Color get selected =>
      dark ? const Color(0xff3a2b39) : const Color(0xfff4e6ec);
  Color get cyan => dark ? const Color(0xffa9cadc) : const Color(0xff386c85);
  Color get success => dark ? const Color(0xff8ddab3) : const Color(0xff23734e);
  Color get warning => dark ? const Color(0xffefd196) : const Color(0xff8a6112);
  Color get danger => dark ? const Color(0xffffacba) : const Color(0xffad344b);
  Color get hover => Color.alphaBlend(accent.withValues(alpha: .08), surface);
  Color get pressed => Color.alphaBlend(accent.withValues(alpha: .12), surface);
}

ThemeData siteTheme(bool dark) {
  final p = SitePalette(dark);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: SitePalette.brand,
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
                  ? SitePalette.brandHover
                  : SitePalette.brand;
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
