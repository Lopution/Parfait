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
      child: Align(
        alignment: Alignment.topCenter,
        // Article-role width cap — a readable line length on wide
        // surfaces. This is a content-width role, not a breakpoint.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ContentWidths.article),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              FuncSpacing.xl,
              FuncSpacing.lg,
              FuncSpacing.xl,
              FuncSpacing.xxl,
            ),
            children: [
              SelectableText(
                l10n.agreementIntro,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: FuncSpacing.xl),
              _AgreementSection(
                title: l10n.agreementAccountTitle,
                body: l10n.agreementAccountBody,
              ),
              _AgreementSection(
                title: l10n.agreementContentTitle,
                body: l10n.agreementContentBody,
              ),
              _AgreementSection(
                title: l10n.agreementNetworkTitle,
                body: l10n.agreementNetworkBody,
              ),
              _AgreementSection(
                title: l10n.agreementPrivacyTitle,
                body: l10n.agreementPrivacyBody,
              ),
              _AgreementSection(
                title: l10n.agreementDisclaimerTitle,
                body: l10n.agreementDisclaimerBody,
              ),
              const SizedBox(height: FuncSpacing.sm),
              SelectableText(
                l10n.agreementUpdates,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
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
          SelectableText(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: FuncSpacing.sm),
          SelectableText(body, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
