import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui show ImageFilter, lerpDouble;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/mute/mute_predicate.dart';
import '../../../core/mute/mute_store.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../../motion/motion_tokens.dart';
import '../../pixiv_image.dart';
import '../../theme/func_semantic_tokens.dart';
import '../feed/illust_card_layout.dart';
import '../feed/muted_cover.dart';
import 'card_action.dart';
import 'illust_card_actions.dart';
import '../../icons/app_icons.dart';

/// Presents iOS long-press card actions as a full-screen frosted backdrop with
/// a spring-lifted card preview and a compact action menu docked beside it,
/// replacing the Material bottom sheet while preserving live reactive state and
/// accessible button semantics.
Future<void> showIosCardContextMenu(BuildContext context, IllustEntity entity) {
  final rootNavigator = Navigator.of(context, rootNavigator: true);
  final fallbackNavigator = Navigator.of(context).context;
  final anchorRect = _globalRectOf(context);
  final reduceMotion = !MotionTokens.enabled(context);
  final (enterDuration, springCurve) = MotionTokens.springCurve(
    context,
    MotionSpring.spatialFast,
  );
  final exitDuration = MotionTokens.resolve(context, MotionTokens.stateFade);

  return rootNavigator.push(
    _IosCardContextMenuRoute<void>(
      entity: entity,
      anchorRect: anchorRect,
      fallbackNavigator: fallbackNavigator,
      themes: InheritedTheme.capture(from: context, to: rootNavigator.context),
      enterDuration: enterDuration,
      exitDuration: exitDuration,
      springCurve: springCurve,
      reduceMotion: reduceMotion,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

Rect? _globalRectOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) return null;
  final origin = box.localToGlobal(Offset.zero);
  if (!origin.dx.isFinite || !origin.dy.isFinite) return null;
  return origin & box.size;
}

class _IosCardContextMenuRoute<T> extends PopupRoute<T> {
  _IosCardContextMenuRoute({
    required this.entity,
    required this.anchorRect,
    required this.fallbackNavigator,
    required this.themes,
    required this.enterDuration,
    required this.exitDuration,
    required this.springCurve,
    required this.reduceMotion,
    required String barrierLabel,
  }) : _barrierLabel = barrierLabel;

  final IllustEntity entity;
  final Rect? anchorRect;
  final BuildContext fallbackNavigator;
  final CapturedThemes themes;
  final Duration enterDuration;
  final Duration exitDuration;
  final Curve springCurve;
  final bool reduceMotion;
  final String _barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => _barrierLabel;

  @override
  Duration get transitionDuration => enterDuration;

  @override
  Duration get reverseTransitionDuration => exitDuration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return themes.wrap(
      _IosCardContextMenuOverlay(
        entity: entity,
        anchorRect: anchorRect,
        fallbackNavigator: fallbackNavigator,
        animation: animation,
        springCurve: springCurve,
        reduceMotion: reduceMotion,
      ),
    );
  }
}

class _IosCardContextMenuOverlay extends ConsumerWidget {
  const _IosCardContextMenuOverlay({
    required this.entity,
    required this.anchorRect,
    required this.fallbackNavigator,
    required this.animation,
    required this.springCurve,
    required this.reduceMotion,
  });

  final IllustEntity entity;
  final Rect? anchorRect;
  final BuildContext fallbackNavigator;
  final Animation<double> animation;
  final Curve springCurve;
  final bool reduceMotion;

  static const double _maxMenuWidth = 256;
  static const double _minMenuWidth = 216;
  static const double _maxPreviewHeight = 240;
  static const double _minPreviewHeight = 120;
  static const double _estimatedRowHeight = 44;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.watch(illustCardActionsProvider);
    final state = CardActionState.ofRef(ref);
    final providers = ProviderScope.containerOf(context);
    final l10n = context.l10n;
    final tokens = FuncSemanticTokens.of(context);
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mediaPadding = MediaQuery.paddingOf(context);
    final viewport = MediaQuery.sizeOf(context);

    final muted =
        ref.watch(muteStoreProvider.select((s) => muteHitFor(entity, s))) !=
            null &&
        !ref.watch(
          revealedMuteIdsProvider.select((ids) => ids.contains(entity.id)),
        );

    final safeLeft = mediaPadding.left + FuncSpacing.lg;
    final safeTop = mediaPadding.top + FuncSpacing.md;
    final safeRight = math.max(
      safeLeft + _minMenuWidth,
      viewport.width - mediaPadding.right - FuncSpacing.lg,
    );
    final safeBottom = math.max(
      safeTop + _minPreviewHeight,
      viewport.height - mediaPadding.bottom - FuncSpacing.md,
    );
    final safeWidth = safeRight - safeLeft;
    final safeHeight = safeBottom - safeTop;

    final previewWidth = (anchorRect?.width ?? 220.0)
        .clamp(math.min(180.0, safeWidth), math.min(280.0, safeWidth))
        .toDouble();
    final menuWidth = math
        .max(previewWidth, _minMenuWidth)
        .clamp(
          math.min(_minMenuWidth, safeWidth),
          math.min(_maxMenuWidth, safeWidth),
        )
        .toDouble();

    final decodeWidth = PixivImage.feedDecodeWidthOf(
      context,
      anchorRect?.width ?? previewWidth,
    );
    final preview = illustCardPreview(
      entity,
      quality: ref.watch(previewQualityProvider),
      cardPhysicalWidth: decodeWidth,
    );
    final aspect = (1.0 / preview.heightRatio).clamp(0.55, 1.8);
    final desiredMenuHeight = actions.length * _estimatedRowHeight;
    final maxAllowedPreview = math.max(
      _minPreviewHeight,
      safeHeight -
          FuncSpacing.sm -
          math.min(desiredMenuHeight, safeHeight * 0.48),
    );
    final previewHeight = (previewWidth / aspect + 48.0)
        .clamp(
          _minPreviewHeight,
          math.min(_maxPreviewHeight, maxAllowedPreview),
        )
        .toDouble();
    final menuMaxHeight = math.max(
      88.0,
      safeHeight - previewHeight - FuncSpacing.sm,
    );
    final totalHeight =
        previewHeight +
        FuncSpacing.sm +
        math.min(desiredMenuHeight, menuMaxHeight);

    final desiredLeft =
        anchorRect?.left ?? (safeLeft + (safeWidth - previewWidth) / 2);
    final previewLeft = desiredLeft
        .clamp(safeLeft, math.max(safeLeft, safeRight - previewWidth))
        .toDouble();
    final menuLeft = desiredLeft
        .clamp(safeLeft, math.max(safeLeft, safeRight - menuWidth))
        .toDouble();

    final desiredTop =
        anchorRect?.top ?? (safeTop + (safeHeight - totalHeight) / 2);
    final blockTop = desiredTop
        .clamp(safeTop, math.max(safeTop, safeBottom - totalHeight))
        .toDouble();

    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final rawT = reduceMotion ? 1.0 : animation.value.clamp(0.0, 1.0);
        final springT = reduceMotion ? 1.0 : springCurve.transform(rawT);
        final previewScale = reduceMotion
            ? 1.0
            : ui.lerpDouble(0.95, 1.03, springT)!;
        final menuScale = reduceMotion
            ? 1.0
            : ui.lerpDouble(0.88, 1.0, Curves.easeOutCubic.transform(rawT))!;
        final sigma = 16.0 * rawT;

        Widget scrim = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).pop(),
          child: Semantics(
            button: true,
            label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
            child: ColoredBox(
              key: const Key('ios-card-context-backdrop'),
              color: Color.alphaBlend(
                colors.surface.withValues(alpha: (isDark ? 0.56 : 0.44) * rawT),
                Colors.black.withValues(alpha: 0.24 * rawT),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
        if (sigma > 0.05) {
          scrim = BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: scrim,
          );
        }

        return Stack(
          children: [
            Positioned.fill(child: scrim),
            Positioned(
              left: previewLeft,
              top: blockTop,
              width: previewWidth,
              height: previewHeight,
              child: Transform.scale(
                scale: previewScale,
                alignment: Alignment.center,
                child: FadeTransition(
                  opacity: reduceMotion ? kAlwaysCompleteAnimation : animation,
                  child: _PreviewCard(
                    entity: entity,
                    preview: preview,
                    decodeWidth: decodeWidth,
                    muted: muted,
                    width: previewWidth,
                  ),
                ),
              ),
            ),
            Positioned(
              left: menuLeft,
              top: blockTop + previewHeight + FuncSpacing.sm,
              width: menuWidth,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: menuMaxHeight),
                child: Transform.scale(
                  scale: menuScale,
                  alignment: Alignment.topLeft,
                  child: FadeTransition(
                    opacity: reduceMotion
                        ? kAlwaysCompleteAnimation
                        : animation,
                    child: Semantics(
                      container: true,
                      explicitChildNodes: true,
                      label: entity.title,
                      child: DecoratedBox(
                        key: const Key('ios-card-context-menu'),
                        decoration: BoxDecoration(
                          borderRadius: FuncShape.card,
                          border: Border.all(color: tokens.divider),
                          boxShadow: tokens.layerLift,
                        ),
                        child: ClipRRect(
                          borderRadius: FuncShape.card,
                          child: BackdropFilter(
                            filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                            child: ColoredBox(
                              color: colors.surfaceContainerHigh.withValues(
                                alpha: isDark ? 0.88 : 0.92,
                              ),
                              child: Material(
                                type: MaterialType.transparency,
                                child: SingleChildScrollView(
                                  primary: false,
                                  physics: const ClampingScrollPhysics(),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      for (
                                        var i = 0;
                                        i < actions.length;
                                        i++
                                      ) ...[
                                        if (i > 0)
                                          Divider(
                                            height: 1,
                                            thickness: 0.5,
                                            color: tokens.divider,
                                          ),
                                        _ContextActionRow(
                                          icon: actions[i].iconFor(
                                            state,
                                            entity,
                                          ),
                                          label: actions[i].labelFor(
                                            state,
                                            entity,
                                            l10n,
                                          ),
                                          onTap: () {
                                            Navigator.of(context).pop();
                                            unawaited(
                                              actions[i].run(
                                                fallbackNavigator.mounted
                                                    ? fallbackNavigator
                                                    : context,
                                                providers,
                                                entity,
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.entity,
    required this.preview,
    required this.decodeWidth,
    required this.muted,
    required this.width,
  });

  final IllustEntity entity;
  final IllustCardPreview preview;
  final int decodeWidth;
  final bool muted;
  final double width;

  @override
  Widget build(BuildContext context) {
    final tokens = FuncSemanticTokens.of(context);
    final colors = Theme.of(context).colorScheme;
    final url = preview.url;
    final tier = preview.tier;
    return DecoratedBox(
      key: const Key('ios-card-context-preview'),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: FuncShape.card,
        boxShadow: tokens.cardLift,
      ),
      child: ClipRRect(
        borderRadius: FuncShape.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: muted || url.isEmpty
                  ? ColoredBox(
                      color: colors.surfaceContainerHighest,
                      child: Center(
                        child: Icon(
                          muted ? AppIcons.eyeOff : AppIcons.illust,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    )
                  : PixivImage.feed(
                      url,
                      layoutWidth: width,
                      decodeWidth: decodeWidth,
                      fit: BoxFit.cover,
                      alignment: preview.crop == IllustCardCrop.top
                          ? Alignment.topCenter
                          : Alignment.center,
                      tierKey: tier == null ? null : entity.imageTierKeyAt(0),
                      tier: tier,
                      tierUpgrade: false,
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FuncSpacing.md,
                vertical: FuncSpacing.sm,
              ),
              child: MergeSemantics(
                child: Semantics(
                  header: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entity.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.title,
                      ),
                      Text(
                        entity.user.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.caption,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContextActionRow extends StatelessWidget {
  const _ContextActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = FuncSemanticTokens.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FuncSpacing.lg,
            vertical: FuncSpacing.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.body,
                ),
              ),
              const SizedBox(width: FuncSpacing.md),
              Icon(icon, size: 18, color: tokens.contentPrimary),
            ],
          ),
        ),
      ),
    );
  }
}
