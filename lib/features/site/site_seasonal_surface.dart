import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../room/room_style.dart';

/// A single bounded glass layer for the fixed header or an open menu. Scrolling
/// content never receives a full-screen filter or an animation controller.
class SiteSeasonalSurface extends StatelessWidget {
  const SiteSeasonalSurface({
    super.key,
    required this.child,
    this.radius = 40,
    this.menu = false,
  });
  final Widget child;
  final double radius;
  final bool menu;

  @override
  Widget build(BuildContext context) {
    final p = RoomStyle(context);
    final opaque = MediaQuery.highContrastOf(context);
    final ornament =
        'assets/images/navigation/seasons-v1/'
        '${p.palette.season.name}-ornament.webp';
    Widget contents = Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: p.surface.withValues(
                alpha: opaque
                    ? 1
                    : p.dark
                    ? .84
                    : .76,
              ),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: p.line),
            ),
          ),
        ),
        if (!opaque)
          Positioned.fill(
            child: IgnorePointer(
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black,
                    Colors.black.withValues(alpha: menu ? .04 : .10),
                    Colors.black.withValues(alpha: menu ? .04 : .10),
                    Colors.black,
                  ],
                  stops: const [0, .40, .60, 1],
                ).createShader(bounds),
                child: Opacity(
                  opacity: p.dark ? .80 : .78,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final compact = MediaQuery.sizeOf(context).width <= 860;
                      final height = compact ? 160.0 : 180.0;
                      Widget rim(bool bottom) => Positioned(
                        top: bottom ? null : -(compact ? 69.0 : 76.0),
                        bottom: bottom ? -(compact ? 69.0 : 76.0) : null,
                        left: 0,
                        right: 0,
                        height: height,
                        child: RotatedBox(
                          quarterTurns: bottom && menu ? 2 : 0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              image: DecorationImage(
                                image: ResizeImage(
                                  AssetImage(ornament),
                                  height: 360,
                                ),
                                fit: BoxFit.fitHeight,
                                repeat: ImageRepeat.repeatX,
                              ),
                            ),
                          ),
                        ),
                      );
                      return Stack(children: [rim(false), rim(true)]);
                    },
                  ),
                ),
              ),
            ),
          ),
        child,
      ],
    );
    if (!opaque) {
      contents = BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: contents,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: contents,
    );
  }
}

/// Feather only the background. Keeping text outside the masks preserves
/// legibility, selection and focus; no large backdrop blur runs during a fling.
class HubFeatheredSurface extends StatelessWidget {
  const HubFeatheredSurface({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      if (!MediaQuery.highContrastOf(context))
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (r) => LinearGradient(
                  colors: const [
                    Colors.transparent,
                    Colors.black,
                    Colors.black,
                    Colors.transparent,
                  ],
                  stops: [
                    0,
                    (36 / r.width).clamp(0, .49),
                    (1 - 36 / r.width).clamp(.51, 1),
                    1,
                  ],
                ).createShader(r),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        RoomStyle(context).surface.withValues(alpha: .24),
                        RoomStyle(context).surface.withValues(alpha: .24),
                        Colors.transparent,
                      ],
                      stops: const [0, .15, .85, 1],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      child,
    ],
  );
}
