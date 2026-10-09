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
import 'settings_page.dart' show settingsPageIcons;

/// The "me" destination: who is signed in, the places of their own content
/// one tap away, and the settings pages. The content entries carry more
/// weight than the settings — they are what the page is opened for.
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
          const _ContentShortcuts(),
          const _SettingsList(),
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

/// One content entry: a card or a cell of [_ContentShortcuts].
typedef _Entry = ({IconData icon, String label, VoidCallback onTap, int badge});

/// The user's own content: the three places opened most as cards with an
/// accent icon each, the rest as a row of plain icons under them.
class _ContentShortcuts extends ConsumerWidget {
  const _ContentShortcuts();

  static const _cardGap = FuncSpacing.md;

  /// The narrowest plain entry at the default font size that holds a
  /// two-line label of a few CJK characters or one long word. Narrower,
  /// the plain entries go two to a row.
  static const _minCellWidth = 80.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final activeTasks = ref.watch(_activeDownloadCountProvider).value ?? 0;
    final List<(_Entry, _Accent)> cards = [
      (
        (
          icon: Icons.favorite_border,
          label: l10n.profileBookmarked,
          onTap: () => unawaited(openMe(context, tab: MeTab.bookmarks)),
          badge: 0,
        ),
        (fill: scheme.primaryContainer, ink: scheme.onPrimaryContainer),
      ),
      (
        (
          icon: Icons.people_outline,
          label: l10n.profileFollowing,
          onTap: () => unawaited(openMe(context, tab: MeTab.following)),
          badge: 0,
        ),
        (fill: scheme.tertiaryContainer, ink: scheme.onTertiaryContainer),
      ),
      (
        (
          icon: Icons.downloading_outlined,
          label: l10n.downloaderSettings,
          onTap: () => unawaited(openDownloadTasks(context)),
          badge: activeTasks,
        ),
        (fill: scheme.secondaryContainer, ink: scheme.onSecondaryContainer),
      ),
    ];
    final List<_Entry> cells = [
      (
        icon: Icons.collections_bookmark_outlined,
        label: l10n.watchlistTitle,
        onTap: () => unawaited(openWatchlist(context)),
        badge: 0,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        0,
        FuncSpacing.lg,
        FuncSpacing.md,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final cardWidth =
              (width - (cards.length - 1) * _cardGap) / cards.length;
          final cardFit = _wordFit(context, [
            for (final (entry, _) in cards) entry.label,
          ], cardWidth - 2 * _EntryLabel.inset);
          final minCell = MediaQuery.textScalerOf(context).scale(_minCellWidth);
          final columns = width / cells.length >= minCell
              ? cells.length
              : cells.length ~/ 2;
          final cellFit = _wordFit(context, [
            for (final entry in cells) entry.label,
          ], width / columns - 2 * _EntryLabel.inset);
          return Column(
            children: [
              // Cards of one row share the height of the tallest label.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, (entry, accent)) in cards.indexed) ...[
                      if (index > 0) const SizedBox(width: _cardGap),
                      Expanded(
                        child: _AccentEntry(
                          entry: entry,
                          accent: accent,
                          fit: cardFit,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: FuncSpacing.sm),
              for (var start = 0; start < cells.length; start += columns)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in cells.skip(start).take(columns))
                      Expanded(
                        child: _PlainEntry(entry: entry, fit: cellFit),
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }

  /// Labels wrap to two lines between words but never inside one: the
  /// longest word of any label decides one shared scale. Scripts that
  /// break between any two characters (CJK) never need it.
  static LabelFit _wordFit(
    BuildContext context,
    List<String> labels,
    double slotWidth,
  ) => LabelFit.group(
    labels: [
      for (final label in labels)
        for (final word in label.split(RegExp(r'\s+')))
          if (!_breaksAnywhere.hasMatch(word)) word,
    ],
    style: _EntryLabel.style(context),
    textScaler: MediaQuery.textScalerOf(context),
    textDirection: Directionality.of(context),
    slotWidth: slotWidth,
  );

  static final _breaksAnywhere = RegExp(
    r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]',
  );
}

/// A card's icon colors: a container tone and the ink on it.
typedef _Accent = ({Color fill, Color ink});

/// A tonal card: the icon on its accent square, the label under it.
class _AccentEntry extends StatelessWidget {
  const _AccentEntry({
    required this.entry,
    required this.accent,
    required this.fit,
  });

  final _Entry entry;
  final _Accent accent;
  final LabelFit fit;

  static const _iconSquare = 40.0;

  @override
  Widget build(BuildContext context) {
    final badge = entry.badge;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(borderRadius: FuncShape.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: entry.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _EntryLabel.inset,
            vertical: FuncSpacing.md,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Badge(
                isLabelVisible: badge > 0,
                label: Text(AppFormat.count(context, badge)),
                child: SizedBox.square(
                  dimension: _iconSquare,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: accent.fill,
                      borderRadius: FuncShape.card,
                    ),
                    child: Icon(entry.icon, color: accent.ink),
                  ),
                ),
              ),
              const SizedBox(height: FuncSpacing.sm),
              _EntryLabel(entry.label, fit: fit),
            ],
          ),
        ),
      ),
    );
  }
}

/// A plain entry: the icon in the label's tone, no container.
class _PlainEntry extends StatelessWidget {
  const _PlainEntry({required this.entry, required this.fit});

  final _Entry entry;
  final LabelFit fit;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: entry.onTap,
      borderRadius: FuncShape.card,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _EntryLabel.inset,
          vertical: FuncSpacing.md,
        ),
        child: Column(
          children: [
            Icon(
              entry.icon,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: FuncSpacing.sm),
            _EntryLabel(entry.label, fit: fit),
          ],
        ),
      ),
    );
  }
}

class _EntryLabel extends StatelessWidget {
  const _EntryLabel(this.label, {required this.fit});

  final String label;
  final LabelFit fit;

  /// Side padding of an entry around its label.
  static const inset = FuncSpacing.xs;
  static const _lines = 2;

  /// The ambient style with `bodyMedium` over it, as the label draws.
  static TextStyle style(BuildContext context) => DefaultTextStyle.of(
    context,
  ).style.merge(Theme.of(context).textTheme.bodyMedium);

  @override
  Widget build(BuildContext context) => Text(
    label,
    textAlign: TextAlign.center,
    style: style(context),
    maxLines: _lines,
    overflow: TextOverflow.ellipsis,
    textScaler: fit.scaler(MediaQuery.textScalerOf(context)),
  );
}

/// The settings pages as the index lists them, without their summaries,
/// each row a card of its own. The heading's search button opens the
/// index, whose search field is on top.
class _SettingsList extends StatelessWidget {
  const _SettingsList();

  /// The account page is the account row's; the frame probe stays on the
  /// index.
  static const _pages = [
    SettingsPageRef.theme,
    SettingsPageRef.language,
    SettingsPageRef.translate,
    SettingsPageRef.motion,
    SettingsPageRef.browse,
    SettingsPageRef.muted,
    SettingsPageRef.network,
    SettingsPageRef.download,
    SettingsPageRef.backup,
    SettingsPageRef.about,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsGroup(
      separated: true,
      title: Row(
        children: [
          Expanded(child: Text(l10n.settingsTitle)),
          IconButton(
            tooltip: l10n.settingsSearchHint,
            icon: const Icon(Icons.search, size: 20),
            onPressed: () => openSettingsPage(context, settingsIndexPath),
          ),
        ],
      ),
      children: [
        for (final page in _pages)
          SettingsTile(
            setting: page,
            icon: settingsPageIcons[page],
            onTap: () => openSettingsPage(context, page.path),
          ),
      ],
    );
  }
}
