import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../l10n/context.dart';
import '../../motion/app_overlays.dart';
import 'illust_card_actions.dart';

/// Card long-press menu: renders the registered [CardAction]s as a modal
/// bottom sheet. Presentation curve and reduced-motion degrade come from
/// [showAppBottomSheet] / MotionTokens.
Future<void> showCardActionSheet(BuildContext context, IllustEntity entity) {
  return showAppBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Consumer(
      builder: (sheetContext, ref, _) {
        final actions = ref.watch(illustCardActionsProvider);
        final l10n = sheetContext.l10n;
        return SafeArea(
          top: false,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final action in actions)
                Semantics(
                  button: true,
                  label: action.labelFor(ref, entity, l10n),
                  child: ListTile(
                    leading: Icon(action.iconFor(ref, entity)),
                    title: Text(action.labelFor(ref, entity, l10n)),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      action.run(context, ref, entity);
                    },
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}
