import 'package:flutter/material.dart';

import '../../core/app_registration.dart';
import 'site_widgets.dart';

/// Available offline, even before the site's public settings have loaded.
class AppRegistrationLink extends StatelessWidget {
  const AppRegistrationLink({super.key, this.color});
  final Color? color;
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => openSiteLink(appIcpRegistrationUrl, appIcpRegistrationUrl),
    child: Text(
      appIcpRegistration,
      textAlign: TextAlign.center,
      style: TextStyle(color: color),
    ),
  );
}
