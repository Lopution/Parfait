import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform/desktop_file_drop.dart';
import '../../core/platform/platform_caps.dart';
import '../motion/motion_tokens.dart';
import '../theme/func_semantic_tokens.dart';

/// Wraps a desktop page body to accept OS file drag-and-drop while the route
/// is active, painting a themed highlight scrim during drag hover.
class DesktopFileDropTarget extends ConsumerStatefulWidget {
  const DesktopFileDropTarget({
    super.key,
    required this.hint,
    required this.icon,
    required this.onFilesDropped,
    required this.child,
  });

  final String hint;
  final IconData icon;
  final ValueChanged<List<String>> onFilesDropped;
  final Widget child;

  @override
  ConsumerState<DesktopFileDropTarget> createState() =>
      _DesktopFileDropTargetState();
}

class _DesktopFileDropTargetState extends ConsumerState<DesktopFileDropTarget> {
  StreamSubscription<DesktopFileDropEvent>? _sub;
  DesktopFileDropSource? _source;
  bool _dragging = false;

  bool get _isRouteCurrent => ModalRoute.of(context)?.isCurrent ?? true;

  void _bindSource(DesktopFileDropSource source, bool enabled) {
    if (!enabled) {
      unawaited(_sub?.cancel());
      _sub = null;
      _source = null;
      if (_dragging) {
        _dragging = false;
      }
      return;
    }
    if (identical(_source, source) && _sub != null) return;
    unawaited(_sub?.cancel());
    _source = source;
    _sub = source.events.listen(_handleEvent);
  }

  void _handleEvent(DesktopFileDropEvent event) {
    if (!mounted) return;
    switch (event) {
      case DesktopFileDropEntered():
        if (!_isRouteCurrent) return;
        if (!_dragging) {
          setState(() => _dragging = true);
        }
      case DesktopFileDropExited():
        if (_dragging) {
          setState(() => _dragging = false);
        }
      case DesktopFileDropped(:final paths):
        final active = _isRouteCurrent;
        if (_dragging) {
          setState(() => _dragging = false);
        }
        if (active && paths.isNotEmpty) {
          widget.onFilesDropped(paths);
        }
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(platformCapsProvider);
    final source = ref.watch(desktopFileDropSourceProvider);
    _bindSource(source, caps.isDesktop);

    if (!caps.isDesktop) {
      return widget.child;
    }

    final tokens = FuncSemanticTokens.of(context);
    final colors = Theme.of(context).colorScheme;
    final duration = MotionTokens.resolve(context, MotionTokens.stateFade);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _dragging ? 1.0 : 0.0,
              duration: duration,
              child: _dragging
                  ? Padding(
                      padding: const EdgeInsets.all(FuncSpacing.lg),
                      child: DecoratedBox(
                        key: const ValueKey('desktop-file-drop-overlay'),
                        decoration: BoxDecoration(
                          color: colors.surface.withValues(alpha: 0.92),
                          borderRadius: FuncShape.panel,
                          border: Border.all(color: tokens.brand, width: 2),
                        ),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(FuncSpacing.xl),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  widget.icon,
                                  size: 40,
                                  color: tokens.brand,
                                ),
                                const SizedBox(height: FuncSpacing.md),
                                Text(
                                  widget.hint,
                                  textAlign: TextAlign.center,
                                  style: tokens.title,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}
