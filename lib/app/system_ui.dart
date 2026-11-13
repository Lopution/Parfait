import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/log.dart';
import 'theme/func_tokens.dart';

/// The only file that may construct `SystemUiOverlayStyle` / write
/// `AnnotatedRegion<SystemUiOverlayStyle>` / call `SystemChrome` (design §6,
/// enforced by test/architecture/feedback_channels_test.dart).

/// Coordinates active route background brightness so desktop custom title-bar
/// controls adapt contrast over dark immersive surfaces (e.g. artwork viewer
/// or night reading mode) even when the outer app theme is light.
class DesktopSystemBarsController {
  DesktopSystemBarsController({Brightness initial = Brightness.light})
    : _brightness = ValueNotifier<Brightness>(initial);

  final ValueNotifier<Brightness> _brightness;
  Brightness? _rootBrightness;
  final List<_BarsEntry> _routeEntries = <_BarsEntry>[];
  bool _disposed = false;

  ValueListenable<Brightness> get brightness => _brightness;

  void _setEntry(Object token, Brightness background, {required bool isRoute}) {
    if (_disposed) return;
    if (!isRoute) {
      _rootBrightness = background;
    } else {
      final index = _routeEntries.indexWhere((e) => identical(e.token, token));
      if (index >= 0) {
        _routeEntries[index] = _BarsEntry(token, background);
      } else {
        _routeEntries.add(_BarsEntry(token, background));
      }
    }
    _sync();
  }

  void _removeEntry(Object token) {
    if (_disposed) return;
    final removed = _routeEntries.length;
    _routeEntries.removeWhere((e) => identical(e.token, token));
    if (_routeEntries.length != removed) {
      _sync();
    }
  }

  void _sync() {
    if (_disposed) return;
    final effective = _routeEntries.isNotEmpty
        ? _routeEntries.last.background
        : _rootBrightness;
    if (effective != null && _brightness.value != effective) {
      _brightness.value = effective;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _routeEntries.clear();
    _brightness.dispose();
  }
}

class _BarsEntry {
  const _BarsEntry(this.token, this.background);

  final Object token;
  final Brightness background;
}

/// Exposes [DesktopSystemBarsController] down to [FuncSystemBars] instances.
class DesktopSystemBarsScope extends InheritedWidget {
  const DesktopSystemBarsScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final DesktopSystemBarsController controller;

  static DesktopSystemBarsController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<DesktopSystemBarsScope>()
      ?.controller;

  @override
  bool updateShouldNotify(DesktopSystemBarsScope oldWidget) =>
      controller != oldWidget.controller;
}

/// Transparent status and navigation bars whose icons contrast with
/// [background] — the brightness of what is painted under the bars.
SystemUiOverlayStyle funcSystemBarsStyle(Brightness background) {
  Brightness iconsOver(Brightness under) =>
      under == Brightness.dark ? Brightness.light : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: FuncTokens.transparent,
    // iOS reads the *bar's* brightness and derives icon colour itself.
    statusBarBrightness: background,
    statusBarIconBrightness: iconsOver(background),
    systemNavigationBarColor: FuncTokens.transparent,
    systemNavigationBarIconBrightness: iconsOver(background),
    systemNavigationBarDividerColor: FuncTokens.transparent,
    // systemNavigationBarContrastEnforced stays unset: with three-button
    // navigation the platform decides whether to add a scrim.
  );
}

/// The only caller of `SystemChrome.setEnabledSystemUIMode`. A platform
/// failure (desktop embedders, a detached engine) is logged, never thrown
/// and never silently dropped. Only [Exception]s are platform failures —
/// a programming error still throws.
Future<void> setSystemUiMode(SystemUiMode mode) async {
  try {
    await SystemChrome.setEnabledSystemUIMode(mode);
  } on Exception catch (error) {
    log('setEnabledSystemUIMode($mode) failed: $error');
  }
}

/// Scoped system bar style: the root default, or a page override while it
/// is mounted. Built on [AnnotatedRegion], so leaving the page restores the
/// style underneath without any imperative reset — `RenderView` picks the
/// innermost region covering each bar, which is this page while it fills
/// the screen and the root style again the frame after it unmounts.
class FuncSystemBars extends StatefulWidget {
  const FuncSystemBars({
    super.key,
    required this.background,
    required this.child,
  });

  /// Brightness of what paints under the bars; icons take the inverse.
  final Brightness background;

  final Widget child;

  @override
  State<FuncSystemBars> createState() => _FuncSystemBarsState();
}

class _FuncSystemBarsState extends State<FuncSystemBars> {
  DesktopSystemBarsController? _controller;
  bool _isRoute = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = DesktopSystemBarsScope.maybeOf(context);
    final isRoute = ModalRoute.of(context) != null;
    if (!identical(_controller, next)) {
      _controller?._removeEntry(this);
      _controller = next;
    }
    _isRoute = isRoute;
    _publish();
  }

  @override
  void didUpdateWidget(FuncSystemBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.background != widget.background) {
      _publish();
    }
  }

  void _publish() {
    final controller = _controller;
    if (controller == null) return;
    final background = widget.background;
    final isRoute = _isRoute;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      controller._setEntry(this, background, isRoute: isRoute);
    });
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      // Remove outside active build/unmount checks.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller._removeEntry(this);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: funcSystemBarsStyle(widget.background),
      child: widget.child,
    );
  }
}
