import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/site_localization.dart';

/// Local artwork and a finite release animation; no network or audio needed.
class DriftLanternScene extends StatelessWidget {
  const DriftLanternScene({super.key, required this.sent});
  final bool sent;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final narrow = box.maxWidth < 620;
      return ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: SizedBox(
          height: narrow ? 340 : 300,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(
                'assets/images/drift/lantern/lake-${narrow ? 'portrait' : 'wide'}.webp',
                fit: BoxFit.cover,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xb3001223)],
                  ),
                ),
              ),
              TweenAnimationBuilder<double>(
                key: ValueKey(sent),
                tween: Tween(begin: 0, end: sent ? 1 : 0),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(seconds: 4),
                builder: (_, value, child) => Align(
                  alignment: Alignment(.42 + value * .1, .3 - value * .8),
                  child: Transform.rotate(
                    angle: math.sin(value * math.pi) * .04,
                    child: Transform.scale(
                      scale: 1 - value * .6,
                      child: Opacity(opacity: 1 - value * .65, child: child),
                    ),
                  ),
                ),
                child: Image.asset(
                  'assets/images/drift/lantern/paper-lantern.webp',
                  width: narrow ? 100 : 120,
                  excludeFromSemantics: true,
                ),
              ),
              const Positioned(
                left: 20,
                right: 20,
                bottom: 20,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SiteText(
                      '星海来信',
                      style: TextStyle(color: Colors.white, fontSize: 30),
                    ),
                    SizedBox(height: 8),
                    SiteText(
                      '把一句心事交给月光，遇见另一端的某个人。',
                      style: TextStyle(color: Colors.white, height: 1.6),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
