import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../l10n/app_localizations.dart';

/// One entry in the card long-press menu. Actions are thin app-layer
/// adapters over core providers — core domains never know the menu exists,
/// and new domains (mute-system registers its block entries later) only
/// append instances to [illustCardActionsProvider].
abstract class CardAction {
  const CardAction();

  /// Stable identifier for tests and analytics.
  String get id;

  /// Icon for the entity's current state (e.g. filled vs outline heart).
  IconData iconFor(WidgetRef ref, IllustEntity entity);

  String labelFor(WidgetRef ref, IllustEntity entity, AppLocalizations l10n);

  /// Runs after the sheet has been popped. [context] is the card's own —
  /// the sheet's context is already unmounted at this point.
  Future<void> run(BuildContext context, WidgetRef ref, IllustEntity entity);
}
