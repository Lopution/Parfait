import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../../core/entity/illust_entity.dart';
import '../../../l10n/app_localizations.dart';

/// Provider access for a [CardAction]'s icon and label.
///
/// The long-press sheet builds its rows under a [WidgetRef], so [watch]
/// keeps an open sheet following the store (a list still loading lands and
/// the entry renames). A pointer menu is built from a secondary click,
/// outside build, with a [ProviderContainer]; there [watch] is a one-off
/// read of the state at opening — nothing can change under the open menu,
/// since selecting an entry closes it first.
abstract interface class CardActionState {
  factory CardActionState.ofRef(WidgetRef ref) = _RefCardActionState;
  factory CardActionState.ofContainer(ProviderContainer container) =
      _ContainerCardActionState;

  T watch<T>(ProviderListenable<T> provider);
}

final class _RefCardActionState implements CardActionState {
  _RefCardActionState(this.ref);

  final WidgetRef ref;

  @override
  T watch<T>(ProviderListenable<T> provider) => ref.watch(provider);
}

final class _ContainerCardActionState implements CardActionState {
  _ContainerCardActionState(this.container);

  final ProviderContainer container;

  @override
  T watch<T>(ProviderListenable<T> provider) => container.read(provider);
}

/// One entry in the card long-press menu. Actions are thin app-layer
/// adapters over core providers — core domains never know the menu exists,
/// and new domains (mute-system registers its block entries later) only
/// append instances to [illustCardActionsProvider].
abstract class CardAction {
  const CardAction();

  /// Stable identifier for tests and analytics.
  String get id;

  /// Icon for the entity's current state (e.g. filled vs outline heart).
  IconData iconFor(CardActionState state, IllustEntity entity);

  String labelFor(
    CardActionState state,
    IllustEntity entity,
    AppLocalizations l10n,
  );

  /// Runs after the sheet or menu has been popped. [context] is the card's
  /// own — the presentation's context is already unmounted at this point —
  /// and [container] outlives the card, so a refresh landing underneath the
  /// open presentation cannot take the providers away.
  Future<void> run(
    BuildContext context,
    ProviderContainer container,
    IllustEntity entity,
  );
}
