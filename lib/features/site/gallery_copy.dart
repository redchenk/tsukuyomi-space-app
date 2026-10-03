import 'package:flutter/widgets.dart';

import '../../core/site_localization.dart';

/// Gallery copy follows the source gallery workspace, with native Japanese UI.
String galleryCopy(BuildContext context, String zh, String en, String ja) =>
    switch (SiteLocaleScope.maybeOf(context)?.language ?? 'zh') {
      'en' => en,
      'ja' => ja,
      _ => zh,
    };
