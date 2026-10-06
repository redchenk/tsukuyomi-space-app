import 'package:flutter/material.dart';

import '../../core/site_theme.dart';

/// Shared with the website's editorial theme and its 860px Room breakpoint.
class RoomStyle {
  RoomStyle(BuildContext context)
    : dark = Theme.of(context).brightness == Brightness.dark,
      palette = SitePalette.of(context);
  final bool dark;
  static const breakpoint = 860.0;
  final SitePalette palette;
  Color get background => palette.background;
  Color get surface => palette.surface;
  Color get low => palette.low;
  Color get soft => palette.soft;
  Color get line => palette.line;
  Color get ink => palette.ink;
  Color get muted => palette.muted;
  Color get accent => palette.accent;
  Color get primary => palette.primary;
  Color get onPrimary => Colors.white;
  Color get selected => palette.selected;
  Color get success => palette.success;
  Color get warning => palette.warning;
  Color get danger => palette.danger;
  Color get glass => surface.withValues(alpha: .92);
  static const serif = 'Songti SC';
}

class CharacterAvatar extends StatelessWidget {
  const CharacterAvatar({super.key, this.size = 38, this.radius = 11});
  final double size, radius;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: SizedBox.square(
      dimension: size,
      child: OverflowBox(
        maxWidth: size * 3.5,
        maxHeight: size * 4.375,
        alignment: const Alignment(.22, -.56),
        child: Image.asset(
          'assets/images/yachiyo-portrait.webp',
          width: size * 3.5,
          height: size * 4.375,
          fit: BoxFit.cover,
          excludeFromSemantics: true,
        ),
      ),
    ),
  );
}
