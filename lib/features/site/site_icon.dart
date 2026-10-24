import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'site_icon_data.dart';

/// The same stroke geometry as the mobile website, with native semantics supplied
/// by the enclosing button and no font-dependent icon substitutions.
class SiteIcon extends StatelessWidget {
  const SiteIcon(this.name, {super.key, this.size = 20, this.color});
  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SvgPicture.string(
    siteIconSvg[name] ?? siteIconSvg['home']!,
    width: size,
    height: size,
    excludeFromSemantics: true,
    colorFilter: ColorFilter.mode(
      color ??
          IconTheme.of(context).color ??
          Theme.of(context).colorScheme.onSurface,
      BlendMode.srcIn,
    ),
  );
}
