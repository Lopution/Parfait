/// All SharedPreferences keys in one place (C5b).
///
/// Values are frozen: renaming a key loses user data. New keys must be
/// versioned (`.v1` suffix style).
abstract final class PreferenceKeys {
  /// Download recovery queue (`DownloadRecoveryStore`).
  static const String downloadRecovery = 'pixivfunc.download.recovery.v1';

  /// Updater download state (`UpdateDownloadStateStore`).
  static const String updateDownload = 'pixivfunc.update.download.v1';

  /// Updater manager recovery queue (shares the recovery schema).
  static const String updateManagerRecovery =
      'pixivfunc.update.manager.recovery.v1';

  /// Versioned JSON settings blob (`PreferencesSettingsRepository`).
  static const String settings = 'replica.settings.v2';

  /// Legacy settings keys migrated by the repository.
  static const String legacyJson = 'settings';
  static const String legacyGuideCompleted = 'replica.guide_completed';
  static const String legacyLanguage = 'replica.language';

  /// Blocked tag filter set (`BlockedTags`).
  static const String blockedTags = 'blocked_tags';

  /// Account metadata schema + current selection.
  static const String accounts = 'replica.accounts.v1';
  static const String accountsCurrent = 'replica.accounts.current.v1';

  /// Fast-route persisted addresses (`PixivFastRouteStore`).
  static const String fastRoutes = 'pixiv.network.fast_routes.v1';
}
