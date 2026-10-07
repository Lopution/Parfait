import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/context.dart';
import '../../motion/motion_tokens.dart';

/// Something the settings search can find: a setting, or a settings page.
/// The settings catalog defines them; the row widgets only need the id to
/// mark themselves and the title they show.
abstract interface class SettingsEntry {
  /// Stable id, carried in the `focus` query of a settings route.
  String get id;

  /// The entry's title in [l10n]; null for a choice group shown without
  /// one (its options name it).
  String? title(AppLocalizations l10n);
}

/// Where a settings page scrolls when the search opened it for [target]:
/// the anchor of [target] is brought into view and marked once. Anchors
/// below the built part of a lazy list do not exist yet, so the scope
/// pages the list down until the target appears or the end is reached.
class SettingsFocusScope extends StatefulWidget {
  const SettingsFocusScope({
    super.key,
    required this.target,
    required this.child,
  });

  /// The [SettingsEntry.id] to reveal; null reveals nothing.
  final String? target;
  final Widget child;

  @override
  State<SettingsFocusScope> createState() => _SettingsFocusScopeState();
}

class _SettingsFocusScopeState extends State<SettingsFocusScope> {
  final _anchors = <String, _SettingAnchorState>{};
  bool _done = false;
  bool _scheduled = false;
  int _pagesDown = 0;

  /// Upper bound on page-downs while the target is not built yet; settings
  /// pages are a few screens long.
  static const _maxPagesDown = 20;

  /// Where the revealed row lands in the viewport: a little below the top,
  /// so the rows above it give context.
  static const _revealAlignment = 0.2;

  @override
  void didUpdateWidget(SettingsFocusScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target != widget.target) {
      _done = false;
      _pagesDown = 0;
      _schedule();
    }
  }

  void _register(_SettingAnchorState anchor) {
    _anchors[anchor.widget.entry.id] = anchor;
    _schedule();
  }

  void _unregister(String id, _SettingAnchorState anchor) {
    if (identical(_anchors[id], anchor)) _anchors.remove(id);
  }

  void _schedule() {
    if (_done || _scheduled || widget.target == null) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _reveal();
    });
  }

  void _reveal() {
    if (_done) return;
    final target = _anchors[widget.target];
    if (target != null) {
      _done = true;
      final duration = MotionTokens.resolve(context, MotionTokens.medium);
      Scrollable.ensureVisible(
        target.context,
        alignment: _revealAlignment,
        duration: duration,
        curve: MotionTokens.fastCurve,
      ).then((_) {
        if (target.mounted) target.mark();
      });
      return;
    }
    final any = _anchors.values.firstOrNull;
    final position = any == null
        ? null
        : Scrollable.maybeOf(any.context)?.position;
    if (position == null || !position.hasContentDimensions) return;
    if (position.pixels >= position.maxScrollExtent ||
        _pagesDown >= _maxPagesDown) {
      // The target is not on this page (or not in this state of it).
      _done = true;
      return;
    }
    _pagesDown++;
    position.jumpTo(
      math.min(
        position.pixels + position.viewportDimension,
        position.maxScrollExtent,
      ),
    );
    _schedule();
  }

  @override
  Widget build(BuildContext context) =>
      _SettingsFocusMarker(state: this, child: widget.child);
}

class _SettingsFocusMarker extends InheritedWidget {
  const _SettingsFocusMarker({required this.state, required super.child});

  final _SettingsFocusScopeState state;

  @override
  bool updateShouldNotify(_SettingsFocusMarker oldWidget) =>
      !identical(state, oldWidget.state);
}

/// Marks [child] as the place of [entry] on its settings page. A row
/// anchor tints itself when revealed ([paintsMark]); a group anchor leaves
/// the tint to the group's segments, which read it through
/// [SettingHighlight].
class SettingAnchor extends StatefulWidget {
  const SettingAnchor({
    super.key,
    required this.entry,
    this.paintsMark = true,
    required this.child,
  });

  final SettingsEntry entry;
  final bool paintsMark;
  final Widget child;

  @override
  State<SettingAnchor> createState() => _SettingAnchorState();
}

class _SettingAnchorState extends State<SettingAnchor>
    with SingleTickerProviderStateMixin {
  _SettingsFocusScopeState? _scope;

  /// 0 = unmarked, 1 = fully marked. Runs from 1 through the hold, then
  /// fades to 0.
  late final AnimationController _mark = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = context
        .getInheritedWidgetOfExactType<_SettingsFocusMarker>()
        ?.state;
    if (identical(scope, _scope)) return;
    _scope?._unregister(widget.entry.id, this);
    _scope = scope?.._register(this);
  }

  @override
  void didUpdateWidget(SettingAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.id != widget.entry.id) {
      _scope
        ?.._unregister(oldWidget.entry.id, this)
        .._register(this);
    }
  }

  @override
  void dispose() {
    _scope?._unregister(widget.entry.id, this);
    _mark.dispose();
    super.dispose();
  }

  /// Shows the mark at once, holds it, then fades it out. Under reduced
  /// motion the fade resolves to zero: the mark holds and then goes.
  void mark() {
    const hold = MotionTokens.settingHighlightHold;
    final fade = MotionTokens.resolve(
      context,
      MotionTokens.settingHighlightFade,
    );
    final total = hold + fade;
    _mark
      ..value = 1
      ..animateTo(
        0,
        duration: total,
        curve: Interval(hold.inMicroseconds / total.inMicroseconds, 1),
      );
  }

  @override
  Widget build(BuildContext context) {
    final child = SettingHighlight._(mark: _mark, child: widget.child);
    if (!widget.paintsMark) return child;
    return SettingMarkOverlay(mark: _mark, child: child);
  }
}

/// The mark of the nearest [SettingAnchor], for widgets that paint it on
/// their own shape (the segments of a settings group).
class SettingHighlight extends InheritedNotifier<Animation<double>> {
  const SettingHighlight._({
    required Animation<double> mark,
    required super.child,
  }) : super(notifier: mark);

  static Animation<double>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingHighlight>()?.notifier;
}

/// The primary-tinted wash over a revealed setting.
class SettingMarkOverlay extends StatelessWidget {
  const SettingMarkOverlay({
    super.key,
    required this.mark,
    required this.child,
  });

  final Animation<double> mark;
  final Widget child;

  /// Opacity of the wash at full mark: the pressed-state layer of M3.
  static const _maxOpacity = 0.12;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: mark,
      child: child,
      builder: (context, child) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          color: mark.value == 0
              ? null
              : color.withValues(alpha: _maxOpacity * mark.value),
        ),
        child: child,
      ),
    );
  }
}

/// [row] anchored at [setting] when one is given.
Widget anchorSettingsRow(SettingsEntry? setting, Widget row) =>
    setting == null ? row : SettingAnchor(entry: setting, child: row);

/// A row's title: [title] when given, else the title of [setting].
String settingsRowTitle(
  BuildContext context,
  String? title,
  SettingsEntry? setting,
) {
  final resolved = title ?? setting?.title(context.l10n);
  assert(resolved != null, 'A settings row needs a title or a setting');
  return resolved ?? '';
}
