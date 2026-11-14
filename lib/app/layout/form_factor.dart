import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/settings/app_settings.dart';
import 'app_breakpoints.dart';
import 'window_layout_spec.dart';

/// The kind of device the shell is laid out for (user decision 11-09).
///
/// - [phone]: a display whose shortest side is under 600dp
///   ([AppBreakpoints.isPhoneDisplay]), turned or not: the bottom bar.
/// - [touch]: a larger touch screen (a tablet, an unfolded foldable): the
///   rail from 600dp wide, always collapsed.
/// - [pc]: a desktop: the same pages as [touch], a rail the user opens and
///   closes, and a pointer's context menus.
///
/// Below 600dp wide every form shows the bottom bar ([hasRail]).
enum FormFactor {
  phone,
  touch,
  pc;

  /// The form for a display of [display] logical pixels (null: unknown,
  /// never a phone) on [platform]. A desktop is a PC unless [choice] asks
  /// for the touch shell; elsewhere [choice] does not count, since only
  /// desktops offer it.
  static FormFactor resolve({
    required Size? display,
    required TargetPlatform platform,
    required InterfaceForm choice,
  }) {
    if (AppBreakpoints.isPhoneDisplay(display)) return phone;
    final desktop = switch (platform) {
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS => true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => false,
    };
    // Elsewhere the choice is ignored: a backup from a desktop can carry it.
    if (!desktop) return touch;
    return choice == InterfaceForm.touch ? touch : pc;
  }

  /// The form of the screen [context] is on. Under [FormFactorScope] the
  /// app's; elsewhere (a widget test) the platform's own.
  static FormFactor of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FormFactorData>()?.form ??
      resolve(
        display: AppBreakpoints.displaySizeOf(context),
        platform:
            WindowEnvironmentOverride.maybeOf(context)?.targetPlatform ??
            defaultTargetPlatform,
        choice: InterfaceForm.auto,
      );

  /// Whether a window [width] wide shows the rail rather than the bottom
  /// bar.
  bool hasRail(double width) => this != phone && width >= AppBreakpoints.medium;

  /// Whether the rail is open into its labelled panel: never on a touch
  /// screen; on a PC as the user last left it ([choice]), or from
  /// [AppBreakpoints.extraLarge] wide until the user has toggled it.
  bool railExpanded(double width, {required bool? choice}) =>
      this == pc && (choice ?? width >= AppBreakpoints.extraLarge);
}

/// Publishes the app's [FormFactor] below it: the display the app is on,
/// the platform and the user's [InterfaceForm].
class FormFactorScope extends StatelessWidget {
  const FormFactorScope({super.key, required this.choice, required this.child});

  final InterfaceForm choice;
  final Widget child;

  @override
  Widget build(BuildContext context) => _FormFactorData(
    form: FormFactor.resolve(
      display: AppBreakpoints.displaySizeOf(context),
      platform:
          WindowEnvironmentOverride.maybeOf(context)?.targetPlatform ??
          defaultTargetPlatform,
      choice: choice,
    ),
    child: child,
  );
}

class _FormFactorData extends InheritedWidget {
  const _FormFactorData({required this.form, required super.child});

  final FormFactor form;

  @override
  bool updateShouldNotify(_FormFactorData oldWidget) => form != oldWidget.form;
}
