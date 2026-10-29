part of 'hero_transition.dart';

// Self-check of the artwork Hero flight, for a fault seen on devices and
// never caught on demand: the image flying to or from a card out of sight.
// At its start each flight's card end (the source of a push, the landing
// of a pop) has to be live, on its page and, pushed from a card just
// tapped, where that card is. A flight that fails logs one entry to
// [HeroAnomalyLog]; a normal one costs these few comparisons.

/// The card a work was last opened from: its Hero tag and its box on
/// screen.
({Object tag, Rect rect, DateTime at})? _lastOpen;

/// How long after a tap its flight may start and still be held to it.
const _openWindow = Duration(seconds: 2);

/// How far, in logical pixels, a flight may start outside the tapped card
/// (a press scales the card down).
const _openSlack = 8.0;

/// Notes that the card at [cardContext], whose image is the Hero [tag],
/// opens its work now.
void noteHeroCardOpened(BuildContext cardContext, Object tag) {
  final rect = _heroScreenRect(cardContext);
  _lastOpen = rect == null ? null : (tag: tag, rect: rect, at: DateTime.now());
}

/// Checks the flight between the Hero at [card] and the one at [other],
/// as it starts; logs it when the card end is not where the user sees it.
void inspectHeroFlight({
  required BuildContext flightContext,
  required HeroFlightDirection direction,
  required BuildContext card,
  required BuildContext other,
}) {
  final hero = card.widget as Hero;
  final tag = hero.tag;
  final cardRect = _heroScreenRect(card);
  final reasons = [
    if (!TickerMode.getValuesNotifier(card).value.enabled) 'card end still',
    if (_offPage(card)) 'card end off its page',
    // Only a card was tapped: detail to viewer shares the tag but starts
    // from the detail image.
    if (direction == HeroFlightDirection.push &&
        hero.child is IllustHeroCardFrame &&
        _awayFromTap(tag, cardRect))
      'card end away from the tapped card',
  ];
  if (reasons.isEmpty) return;
  final entry = [
    '${DateTime.now().toIso8601String()} ${direction.name} $tag',
    reasons.join('; '),
    'card: ${_describe(card, cardRect)}',
    'other: ${_describe(other, _heroScreenRect(other))}',
  ].join('\n');
  log('hero anomaly: $entry');
  // The shuttle is built mid-frame; the prompt waits for its end.
  SchedulerBinding.instance.addPostFrameCallback((_) {
    if (!flightContext.mounted) return;
    final container = ProviderScope.containerOf(flightContext, listen: false);
    unawaited(container.read(heroAnomalyLogProvider).add(entry));
    if (FrameProbe.available || container.read(developerOptionsProvider)) {
      showAppSnackBar(flightContext, flightContext.l10n.heroAnomalyRecorded);
    }
  });
}

/// Whether the Hero at [context] lies outside its route's page, where
/// the flight places it: the page may still be moving in its own
/// transition, so the screen is no measure.
bool _offPage(BuildContext context) {
  final page = ModalRoute.of(context)?.subtreeContext?.findRenderObject();
  final box = context.findRenderObject();
  if (page is! RenderBox || box is! RenderBox || !box.hasSize) return true;
  final rect = MatrixUtils.transformRect(
    box.getTransformTo(page),
    Offset.zero & box.size,
  );
  return !rect.overlaps(Offset.zero & page.size);
}

bool _awayFromTap(Object tag, Rect? cardRect) {
  final open = _lastOpen;
  if (open == null ||
      open.tag != tag ||
      DateTime.now().difference(open.at) > _openWindow) {
    return false;
  }
  return cardRect == null || !cardRect.overlaps(open.rect.inflate(_openSlack));
}

/// The route, navigator (a branch's restoration id) and box of a flight
/// end.
String _describe(BuildContext context, Rect? rect) {
  final route = ModalRoute.of(context)?.settings.name;
  final navigator = Navigator.maybeOf(context)?.widget.restorationScopeId;
  final box = rect == null
      ? 'no box'
      : [
          rect.left,
          rect.top,
          rect.width,
          rect.height,
        ].map((v) => v.round()).join(',');
  return '$route in ${navigator ?? '-'} at $box';
}
