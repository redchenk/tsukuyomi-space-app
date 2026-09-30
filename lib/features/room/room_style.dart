import 'package:flutter/material.dart';

/// Shared with the website's editorial theme and its 860px Room breakpoint.
class RoomStyle {
  RoomStyle(BuildContext context)
    : dark = Theme.of(context).brightness == Brightness.dark;
  final bool dark;
  static const breakpoint = 860.0;
  Color get background =>
      dark ? const Color(0xff10121c) : const Color(0xfff5f4fa);
  Color get surface => dark ? const Color(0xff1b1e2c) : Colors.white;
  Color get soft => dark ? const Color(0xff25283a) : const Color(0xffefedf7);
  Color get line => dark ? const Color(0xff343448) : const Color(0xffe5e1ef);
  Color get ink => dark ? const Color(0xfff0edf8) : const Color(0xff292738);
  Color get muted => dark ? const Color(0xffcec9df) : const Color(0xff514b62);
  Color get accent => dark ? const Color(0xffc4b5fd) : const Color(0xff60439f);
  Color get primary => dark ? const Color(0xffb79cde) : const Color(0xff7052ae);
  Color get onPrimary => dark ? const Color(0xff251c32) : Colors.white;
  Color get selected =>
      Color.alphaBlend(accent.withValues(alpha: .12), surface);
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
