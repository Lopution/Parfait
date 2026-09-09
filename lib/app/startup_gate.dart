import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'navigation/routes.dart';

import '../core/auth/account_store.dart';
import '../core/settings/app_settings.dart';
import '../l10n/lookup.dart';
import '../l10n/context.dart';

/// Cold-start router driven by real settings and account state.
///
/// - guide not completed -> Welcome
/// - guide completed, no usable account -> Login
/// - guide completed, usable account -> Home
///
/// Hydration failures surface an explicit retryable error instead of silently
/// degrading to the no-account branch.
class StartupGate extends ConsumerWidget {
  const StartupGate({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountStoreProvider);
    if (!settings.guideCompleted) {
      return startupGateWelcomePage();
    }
    return accounts.when(
      loading: () => const _StartupProgress(),
      error: (error, stackTrace) => _StartupError(error: error),
      data: (state) {
        if (state.status == AccountStatus.failure) {
          return _StartupError(error: state.error ?? 'unknown account error');
        }
        return state.usableCurrent == null
            ? startupGateLoginPage()
            : startupGateHomePage();
      },
    );
  }
}

class _StartupProgress extends StatelessWidget {
  const _StartupProgress();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    String text(String key) => l10nLookup(context.l10n, key);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 16),
              Text(text('accountReadFailed')),
              const SizedBox(height: 8),
              Text(
                '$error',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () =>
                      ref.read(accountStoreProvider.notifier).reload(),
                  child: Text(text('retry')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
