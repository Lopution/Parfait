import 'package:material_ui/material_ui.dart';

import '../../app/layout/content_widths.dart';
import '../../app/widgets/replica_scaffold.dart';
import '../../l10n/context.dart';
import '../../app/theme/func_semantic_tokens.dart';

/// The agreement is intentionally an in-app document rather than an inert
/// label. It states the practical boundaries of this unofficial client and
/// keeps the login consent link usable even when the network is unavailable.
class UserAgreementPage extends StatelessWidget {
  const UserAgreementPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ReplicaScaffold(
      title: Text(l10n.agreementTitle),
      // The agreement belongs to the sign-in flow.
      upLocation: '/login',
      child: Align(
        alignment: Alignment.topCenter,
        // Article-role width cap — a readable line length on wide
        // surfaces. This is a content-width role, not a breakpoint.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ContentWidths.article),
          // One selection region for the whole document: paragraphs are
          // plain Text, so none of them owns a Scrollable the app-wide
          // bouncing physics could leak into, and a selection can span
          // paragraphs.
          child: SelectionArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                FuncSpacing.xl,
                FuncSpacing.lg,
                FuncSpacing.xl,
                FuncSpacing.xxl,
              ),
              children: [
                Text(
                  l10n.agreementIntro,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: FuncSpacing.xl),
                for (final (title, body) in [
                  (l10n.agreementServiceTitle, l10n.agreementServiceBody),
                  (l10n.agreementAccountTitle, l10n.agreementAccountBody),
                  (l10n.agreementUsageTitle, l10n.agreementUsageBody),
                  (l10n.agreementContentTitle, l10n.agreementContentBody),
                  (l10n.agreementNetworkTitle, l10n.agreementNetworkBody),
                  (l10n.agreementThirdPartyTitle, l10n.agreementThirdPartyBody),
                  (l10n.agreementPrivacyTitle, l10n.agreementPrivacyBody),
                  (l10n.agreementDisclaimerTitle, l10n.agreementDisclaimerBody),
                  (l10n.agreementUpdatesTitle, l10n.agreementUpdates),
                ])
                  _AgreementSection(title: title, body: body),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AgreementSection extends StatelessWidget {
  const _AgreementSection({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: FuncSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: FuncSpacing.sm),
          Text(body, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
