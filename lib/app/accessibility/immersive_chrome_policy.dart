import 'package:flutter/widgets.dart';

/// Whether an immersive surface (reader, image viewer, artwork stage) should
/// keep its navigation chrome pinned open so screen-reader touch exploration
/// cannot be locked behind hidden controls.
bool pinsImmersiveChromeForAccessibility(BuildContext context) =>
    MediaQuery.accessibleNavigationOf(context);
