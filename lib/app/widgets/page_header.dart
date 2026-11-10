import 'package:material_ui/material_ui.dart';

import '../layout/form_factor.dart';

/// How page top bars are laid out on the shell's larger forms (NAV-20).
abstract final class PageHeader {
  /// Whether bars take the wide layout: wherever the shell shows its rail.
  static bool isWide(BuildContext context) =>
      FormFactor.of(context).hasRail(MediaQuery.sizeOf(context).width);
}
