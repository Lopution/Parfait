import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/format/app_format.dart';
import '../../app/navigation/routes.dart';
import '../../app/person_avatar.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/fit_label.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/settings/settings_group.dart';
import '../../app/widgets/settings/settings_tile.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../core/auth/account.dart';
import '../../core/auth/account_store.dart';
import '../../core/download/download_providers.dart';
import '../../core/download/download_task.dart' show isTerminal;
import '../../l10n/context.dart';
import 'settings_catalog.dart';
import 'settings_helpers.dart';

/// The "me" destination: who is signed in, the places of their own content
/// one tap away, and the way into settings. The content entries carry more
/// weight than the settings row — they are what the page is opened for.
class MeDashboardPage extends ConsumerWidget {
  const MeDashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountStoreProvider);
    return Scaffold(
      // Root pages own no inline composer: leaving the default `true`
      // would subscribe this whole subtree to per-frame viewInsets churn
      // every time the IME animates (e.g. the push that hides the search
      // keyboard) — a relayout storm across all five live branches.
      resizeToAvoidBottomInset: false,
      appBar: AppTopBar(title: Text(context.l10n.homeMe)),
      body: _body(context, ref, accounts),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<AccountState> accounts,
  ) {
    void reload() => ref.read(accountStoreProvider.notifier).reload();
    if (accounts.hasError) {
      return SettingsLoadError(
        error: accounts.error!,
        onRetry: reload,
        messageKey: 'accountReadFailed',
      );
    }
    if (accounts.isLoading && !accounts.hasValue) return const FeedLoading();
    final state = accounts.value;
    if (state?.status == AccountStatus.failure) {
      return SettingsLoadError(
        error: state?.error ?? StateError('account state unavailable'),
        onRetry: reload,
        messageKey: 'accountReadFailed',
      );
    }
    return settingsNarrowBody(
      ListView(
        padding: const EdgeInsets.only(
          top: FuncSpacing.sm,
          bottom: FuncSpacing.xl,
        ),
        children: [
          SettingsGroup(children: [_AccountRow(account: state?.current)]),
          SettingsGroup(
            title: Text(context.l10n.settingsGroupLibrary),
            children: const [_ContentEntries()],
          ),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: Icons.settings_outlined,
                title: context.l10n.settingsTitle,
                subtitle: Text(context.l10n.settingsEntrySummary),
                onTap: () => openSettingsPage(context, settingsIndexPath),
              ),
            ],
          ),
          const FuncNavBarSpacer(),
        ],
      ),
    );
  }
}

/// The signed-in account: tapping opens its profile, the trailing button
/// manages and switches accounts. Signed out, the card opens the login.
class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.account});

  final Account? account;

  static const _avatarDiameter = 58.0;

  @override
  Widget build(BuildContext context) {
    final value = account;
    final url = value?.profileImageUrl;
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.sm,
        FuncSpacing.sm,
        FuncSpacing.sm,
      ),
      leading: SizedBox.square(
        dimension: _avatarDiameter,
        child: PersonAvatar(
          imageUrl: url == null || url.isEmpty ? null : url,
          radius: _avatarDiameter / 2,
        ),
      ),
      title: Text(
        value?.name ?? context.l10n.signedOut,
        style: FuncSemanticTokens.of(context).display,
      ),
      subtitle: Text(
        value == null
            ? context.l10n.login
            : context.l10n.labelValue(context.l10n.accountId, value.id),
      ),
      trailing: IconButton(
        tooltip: context.l10n.switchAccount,
        icon: const Icon(Icons.switch_account_outlined),
        onPressed: () =>
            openSettingsPage(context, SettingsPageRef.account.path),
      ),
      onTap: value == null ? () => openLogin(context) : () => openMe(context),
    );
  }
}

/// Download tasks not yet finished. The manager reports every progress
/// tick; the count is re-emitted only when it moves, so the grid rebuilds
/// when a task starts or ends, not on every tick.
final _activeDownloadCountProvider = StreamProvider.autoDispose<int>((
  ref,
) async* {
  final manager = ref.watch(downloadManagerProvider);
  int count() => manager.tasks.where((task) => !isTerminal(task.status)).length;
  var last = count();
  yield last;
  await for (final _ in manager.changes) {
    final next = count();
    if (next == last) continue;
    yield last = next;
  }
});

/// One entry of [_ContentEntries].
typedef _Entry = ({IconData icon, String label, VoidCallback onTap, int badge});

/// The user's own content as a grid of large entries: a tonal circle and
/// a label each, four to a row on a phone (three on a narrow one or with
/// large text), one row on a wide screen.
class _ContentEntries extends ConsumerWidget {
  const _ContentEntries();

  /// A row on a phone; a wide screen fits all of them in one.
  static const _phoneColumns = 4;
  static const _narrowColumns = 3;
  static const _wideWidth = 560.0;

  /// The narrowest cell at the default font size that holds a two-line
  /// label of a few CJK characters or one long word.
  static const _minCellWidth = 80.0;

  static int _columnsFor(BuildContext context, double width, int count) {
    if (width >= _wideWidth) return count;
    final cell = MediaQuery.textScalerOf(context).scale(_minCellWidth);
    return width / _phoneColumns >= cell ? _phoneColumns : _narrowColumns;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final activeTasks = ref.watch(_activeDownloadCountProvider).value ?? 0;
    final List<_Entry> entries = [
      (
        icon: Icons.favorite_border,
        label: l10n.profileBookmarked,
        onTap: () => unawaited(openMe(context, tab: MeTab.bookmarks)),
        badge: 0,
      ),
      (
        icon: Icons.people_outline,
        label: l10n.profileFollowing,
        onTap: () => unawaited(openMe(context, tab: MeTab.following)),
        badge: 0,
      ),
      (
        icon: Icons.collections_bookmark_outlined,
        label: l10n.watchlistTitle,
        onTap: () => unawaited(openWatchlist(context)),
        badge: 0,
      ),
      (
        icon: Icons.downloading_outlined,
        label: l10n.downloaderSettings,
        onTap: () => unawaited(openDownloadTasks(context)),
        badge: activeTasks,
      ),
      (
        icon: Icons.history,
        label: l10n.historySettings,
        onTap: () => unawaited(openHistory(context)),
        badge: 0,
      ),
      (
        icon: Icons.watch_later_outlined,
        label: l10n.watchLaterTitle,
        onTap: () => unawaited(openWatchLater(context)),
        badge: 0,
      ),
      (
        icon: Icons.menu_book_outlined,
        label: l10n.localNovelsTitle,
        onTap: () => unawaited(openLocalNovels(context)),
        badge: 0,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = _columnsFor(
          context,
          constraints.maxWidth,
          entries.length,
        );
        final fit = _wordFit(context, [
          for (final entry in entries) entry.label,
        ], constraints.maxWidth / columns - 2 * _EntryCell.labelInset);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
          child: Column(
            children: [
              for (var start = 0; start < entries.length; start += columns)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = start; i < start + columns; i++)
                      Expanded(
                        child: i < entries.length
                            ? _EntryCell(entry: entries[i], fit: fit)
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  /// Labels wrap to two lines between words but never inside one: the
  /// longest word of any label decides one shared scale. Scripts that
  /// break between any two characters (CJK) never need it.
  static LabelFit _wordFit(
    BuildContext context,
    List<String> labels,
    double cellWidth,
  ) => LabelFit.group(
    labels: [
      for (final label in labels)
        for (final word in label.split(RegExp(r'\s+')))
          if (!_breaksAnywhere.hasMatch(word)) word,
    ],
    style: _EntryCell.labelStyle(context),
    textScaler: MediaQuery.textScalerOf(context),
    textDirection: Directionality.of(context),
    slotWidth: cellWidth,
  );

  static final _breaksAnywhere = RegExp(
    r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]',
  );
}

class _EntryCell extends StatelessWidget {
  const _EntryCell({required this.entry, required this.fit});

  final _Entry entry;
  final LabelFit fit;

  static const _circleDiameter = 48.0;
  static const labelInset = FuncSpacing.xs;
  static const _labelLines = 2;

  /// The ambient style with `bodyMedium` over it, as the label draws.
  static TextStyle labelStyle(BuildContext context) => DefaultTextStyle.of(
    context,
  ).style.merge(Theme.of(context).textTheme.bodyMedium);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final badge = entry.badge;
    return InkWell(
      onTap: entry.onTap,
      borderRadius: FuncShape.card,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: labelInset,
          vertical: FuncSpacing.md,
        ),
        child: Column(
          children: [
            Badge(
              isLabelVisible: badge > 0,
              label: Text(AppFormat.count(context, badge)),
              child: SizedBox.square(
                dimension: _circleDiameter,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(entry.icon, color: scheme.onPrimaryContainer),
                ),
              ),
            ),
            const SizedBox(height: FuncSpacing.sm),
            Text(
              entry.label,
              textAlign: TextAlign.center,
              style: labelStyle(context),
              maxLines: _labelLines,
              overflow: TextOverflow.ellipsis,
              textScaler: fit.scaler(MediaQuery.textScalerOf(context)),
            ),
          ],
        ),
      ),
    );
  }
}
