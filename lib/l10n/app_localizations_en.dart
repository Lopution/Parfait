// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get networkDohEndpointsInvalid => 'Invalid DoH endpoint list';

  @override
  String get welcome1 => 'Thank you for using Pixiv Func';

  @override
  String get welcome2 => 'Initial setup will begin now';

  @override
  String get start => 'Start';

  @override
  String get selectLanguage => 'Select your language';

  @override
  String get selectTheme => 'Choose your favorite theme';

  @override
  String get next => 'Next';

  @override
  String get setupLater => 'Set up later';

  @override
  String get dark => 'Dark';

  @override
  String get light => 'Light';

  @override
  String get system => 'Follow the System';

  @override
  String get loginTitle => 'Register or Login';

  @override
  String get loginProxyNoticeTitle => 'Notice';

  @override
  String get loginProxyNoticeBody =>
      'Because of network restrictions, turn on a system or external proxy before logging in or registering. Pixiv Func does not include a built-in proxy.';

  @override
  String get loginProxyNoticeCancel => 'Cancel';

  @override
  String get loginProxyNoticeContinue => 'I have enabled it';

  @override
  String get register => 'Register';

  @override
  String get login => 'Log in';

  @override
  String get loginPageClosed => 'The page was closed. Reopen it to try again.';

  @override
  String loginCallbackInvalid(String reason) {
    return 'Invalid login callback: $reason';
  }

  @override
  String loginNetworkError(String status) {
    return 'Network error (HTTP $status)';
  }

  @override
  String loginPageLoadFailed(String error) {
    return 'Page load failed ($error)';
  }

  @override
  String get loginWebView2Missing =>
      'Signing in requires the WebView2 Runtime, which was not detected on this system. Install it and reopen this page.';

  @override
  String get loginInstallWebView2 => 'Install WebView2 Runtime';

  @override
  String get loginReload => 'Reload';

  @override
  String get loginRestart => 'Log in again';

  @override
  String loginFailed(String error) {
    return 'Login failed: $error';
  }

  @override
  String loginFailedType(String type) {
    return 'Login failed ($type)';
  }

  @override
  String get networkCompatibility => 'Pixiv official network compatibility';

  @override
  String get networkCompatibilityHint =>
      'Direct HTTPS is tried first; only official Pixiv destinations may try a strict HTTPS candidate after an explicit transport failure. Other traffic is never proxied and certificate checks stay enabled.';

  @override
  String get useLoginWithClipboard => 'Login with clipboard data';

  @override
  String get accountTransferExportTitle => 'Export account credential';

  @override
  String get accountTransferWarning =>
      'The clipboard is kept briefly and may be read by other apps; this format provides neither encryption nor sender authentication.';

  @override
  String get accountTransferSensitiveWarning =>
      'This device cannot mark clipboard entries as sensitive (Android 13+ only): the credential will sit in the system clipboard in plaintext. Paste as soon as possible; it is cleared automatically after 5 minutes.';

  @override
  String get accountTransferCopied =>
      'Account-transfer data copied. Paste it on the target device soon.';

  @override
  String get accountTransferImported => 'Account transfer succeeded';

  @override
  String get accountTransferClipboardReplaced =>
      'Account imported; the clipboard was replaced, so it was not cleared.';

  @override
  String get accountTransferCorrupt =>
      'Clipboard account data is corrupt or unsupported';

  @override
  String get accountTransferCredentialInvalid =>
      'The account credential is invalid; log in or copy again';

  @override
  String get accountTransferVerificationUnavailable =>
      'Pixiv credential verification is temporarily unavailable';

  @override
  String get accountTransferNoAccount =>
      'There is no signed-in account to copy';

  @override
  String get accountTransferCredentialUnavailable =>
      'The current credential is unavailable; log in again';

  @override
  String get accountTransferClipboardUnavailable =>
      'The clipboard is unavailable';

  @override
  String get accountTransferStorageFailure =>
      'The account-transfer record could not be stored safely';

  @override
  String get loginAgree => 'By logging in you agree';

  @override
  String get userAgreement => '《Pixiv Func User Agreement》';

  @override
  String get agreementTitle => 'Pixiv Func User Agreement';

  @override
  String get agreementIntro =>
      'Thank you for using Pixiv Func. By using this app, you confirm that you have read and agree to these terms. Stop using the app if you do not agree.';

  @override
  String get agreementAccountTitle => 'Account and authorization';

  @override
  String get agreementAccountBody =>
      'The app uses Pixiv\'s official sign-in flow and never asks you to enter or share your Pixiv password here. Keep your account and device secure; Pixiv account settings control account activity and revocation.';

  @override
  String get agreementContentTitle => 'Content and copyright';

  @override
  String get agreementContentBody =>
      'Artwork, comments, and profiles are provided by Pixiv and its users, with rights held by their respective owners. Browse, save, and share only where the law and Pixiv rules allow, and do not use the app to infringe others\' rights.';

  @override
  String get agreementNetworkTitle => 'Network access';

  @override
  String get agreementNetworkBody =>
      'The app provides compatibility routing only for official Pixiv destinations. It does not proxy other traffic and keeps certificate verification enabled. Network availability, API changes, and outages are not guaranteed.';

  @override
  String get agreementPrivacyTitle => 'Privacy and local data';

  @override
  String get agreementPrivacyBody =>
      'Credentials are kept in the system secure store; settings, cache, history, and downloads remain local. The app does not sell personal information. Uninstalling or clearing app data may remove local content.';

  @override
  String get agreementDisclaimerTitle => 'Disclaimer';

  @override
  String get agreementDisclaimerBody =>
      'This is an unofficial third-party client and is not affiliated with Pixiv Inc. To the extent permitted by law, the author is not responsible for loss or access failures caused by networks, accounts, third-party services, or events beyond control.';

  @override
  String get agreementUpdates =>
      'This agreement may change with product or legal requirements. Continued use means you accept the updated agreement.';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsGroupAppearance => 'Appearance';

  @override
  String get settingsGroupNetwork => 'Network & downloads';

  @override
  String get settingsGroupBrowse => 'Browsing';

  @override
  String get settingsGroupLibrary => 'My content';

  @override
  String get settingsGroupDeveloper => 'Developer';

  @override
  String get developerOptionsUnlocked => 'Developer options unlocked';

  @override
  String developerOptionsCountdown(int count) {
    return '$count more taps to unlock developer options';
  }

  @override
  String get settingsGroupData => 'Data';

  @override
  String get accountSettings => 'Account';

  @override
  String get networkSettings => 'Network';

  @override
  String get networkMode => 'Pixiv official network compatibility';

  @override
  String get networkModeHint =>
      'Retries compatibility routes when Pixiv won\'t open. Only affects official Pixiv domains — other traffic is never proxied.';

  @override
  String get networkModeListTitle => 'Network mode';

  @override
  String get networkModeAutomatic => 'Automatic';

  @override
  String get networkModeAutomaticHint =>
      'Picks a working connection automatically.';

  @override
  String get networkModeDirectOnly => 'Direct only';

  @override
  String get networkModeDirectOnlyHint =>
      'System connection only; for networks where direct access works.';

  @override
  String get networkModeCompatPrefer => 'Compatibility-first';

  @override
  String get networkModeCompatPreferHint =>
      'Tries compatibility routes first, direct as fallback; for networks where direct access is blocked.';

  @override
  String get networkEffectiveRoutes => 'Effective routes';

  @override
  String get networkEffectiveRoutesEmpty =>
      'No route learned yet — browse a bit and refresh.';

  @override
  String get networkRouteKindDirect => 'Direct';

  @override
  String get networkRouteKindCompat => 'Compat route';

  @override
  String get networkThirdParty => 'Third-party reachability';

  @override
  String get networkThirdPartyAuto =>
      'Checks once automatically when this page opens.';

  @override
  String get networkThirdPartyHint =>
      'Uses your system network — your VPN/proxy applies.';

  @override
  String get networkReachable => 'Reachable';

  @override
  String get networkUnreachable => 'Unreachable';

  @override
  String get networkChecking => 'Checking…';

  @override
  String get networkAdvanced => 'Advanced';

  @override
  String get networkAdvancedHint => 'Low-level options for advanced users.';

  @override
  String get networkAdvancedReset => 'Reset to defaults';

  @override
  String get networkAdvancedResetConfirm =>
      'Resets the DoH endpoints and the ECH front host to their defaults.';

  @override
  String get networkDoh => 'Use DoH for strict fallback';

  @override
  String get networkDohHint =>
      'When enabled, the fallback tier resolves via DoH (default Cloudflare DoH: domain endpoints pinned to static anycast IPs — no poisoned system round trip; custom endpoints resolve their own hostnames); otherwise the system DNS is used.';

  @override
  String get networkDohEndpoints =>
      'DoH endpoints (comma-separated, https URLs)';

  @override
  String get networkEchFrontHost => 'ECH front host';

  @override
  String get networkEchFrontHostHint =>
      'Domain queried for the HTTPS RR carrying the ECH config (default cloudflare-ech.com)';

  @override
  String get networkEchHostInvalid => 'Invalid front host name';

  @override
  String get networkProbe => 'Layered connectivity probe';

  @override
  String get networkProbeTitle => 'Layered connectivity probe';

  @override
  String get networkProbeHint =>
      'Checks Pixiv connectivity layer by layer to locate the failure.';

  @override
  String get frameProbeTitle => 'Frame probe';

  @override
  String get frameProbeHint =>
      'Records frame timings while you scroll. You can leave this page, scroll the target screen, then come back to stop and copy the report. Dev/profile builds only.';

  @override
  String get frameProbeStart => 'Start recording';

  @override
  String get frameProbeRecording => 'Recording';

  @override
  String get frameProbeCapHint =>
      'Frame cap reached — the oldest frames are being dropped.';

  @override
  String get frameProbeStop => 'Stop';

  @override
  String get networkProbeRun => 'Run probe';

  @override
  String get networkProbeRunning => 'Probing…';

  @override
  String get networkProbeNotRun => 'Not run yet';

  @override
  String get networkProbeHostFailed => 'Host probe failed';

  @override
  String get networkProbeCopied => 'Report copied';

  @override
  String get networkProbeDnsDiff =>
      'Additional evidence: system DNS and DoH share no public address.';

  @override
  String get networkProbeStepSystemDns => 'System DNS';

  @override
  String get networkProbeStepDoh => 'DoH';

  @override
  String get networkProbeStepTcp => 'TCP';

  @override
  String get networkProbeStepTls => 'TLS';

  @override
  String get networkProbeStepHttp => 'Minimal request';

  @override
  String get networkProbeStepEch => 'ECH';

  @override
  String get networkProbeStepNoSni => 'Empty SNI';

  @override
  String get networkProbeStepOk => 'OK';

  @override
  String get networkProbeStepFailed => 'Failed';

  @override
  String get networkProbeStepSkipped => 'Skipped';

  @override
  String get networkProbeConclusionAllReachable => 'Reachable';

  @override
  String get networkProbeConclusionDnsPolluted => 'DNS polluted';

  @override
  String get networkProbeConclusionSniBlocked => 'SNI blocked';

  @override
  String get networkProbeConclusionEchAvailable => 'Use ECH';

  @override
  String get networkProbeConclusionNoSniAvailable => 'Use empty SNI';

  @override
  String get networkProbeConclusionIpBlackholed => 'IP blackholed';

  @override
  String get networkProbeConclusionAppLayer => 'Application layer';

  @override
  String get networkProbeConclusionInconclusive => 'Inconclusive';

  @override
  String get networkProbeOverview => 'Overview';

  @override
  String get networkProbeWorst => 'Worst';

  @override
  String get networkProbeDetails => 'Details';

  @override
  String get networkProbeNotPersisted =>
      'Results are not kept — leaving this page discards them.';

  @override
  String get networkProbeAdviceAllReachable =>
      'All hosts reachable — nothing to change.';

  @override
  String get networkProbeAdviceEchAvailable =>
      'ECH works here — Automatic or Compatibility-first mode will use it.';

  @override
  String get networkProbeAdviceNoSniAvailable =>
      'Empty-SNI works here — Compatibility-first mode will use it.';

  @override
  String get networkProbeAdviceSniBlocked =>
      'Real SNI is blocked — try Compatibility-first mode.';

  @override
  String get networkProbeAdviceDnsPolluted =>
      'System DNS is poisoned — keeping DoH on bypasses it.';

  @override
  String get networkProbeAdviceIpBlackholed =>
      'IPs are blackholed — the app cannot bypass this; switch networks.';

  @override
  String get networkProbeAdviceAppLayer =>
      'Transport is fine — the failure is at the app layer; copy the report for feedback.';

  @override
  String get networkProbeAdviceInconclusive =>
      'Inconclusive — try another network or retry later.';

  @override
  String get copy => 'Copy';

  @override
  String get themeSettings => 'Theme';

  @override
  String get languageSettings => 'Language';

  @override
  String get translateSettings => 'Translate';

  @override
  String get browseSettings => 'Browse settings';

  @override
  String get downloadSettings => 'Download settings';

  @override
  String get historySettings => 'History';

  @override
  String get historyView => 'View browsing history';

  @override
  String get historyEmpty => 'No browsing history';

  @override
  String get historyLoadFailed => 'Failed to load history';

  @override
  String get historyDelete => 'Delete history';

  @override
  String get historyDeleteAll => 'Delete all history';

  @override
  String get historyDeleteHint => 'Deleted history cannot be recovered.';

  @override
  String get downloaderSettings => 'Download tasks';

  @override
  String get aboutSettings => 'About';

  @override
  String get signedOut => 'Not signed in';

  @override
  String get currentAccount => 'Current account';

  @override
  String get accountId => 'Account ID';

  @override
  String get reauthRequired => 'Re-authentication required';

  @override
  String get accountProfile => 'Profile';

  @override
  String get accountReadFailed => 'Failed to read account state';

  @override
  String get dismiss => 'Dismiss';

  @override
  String get profileEditTitle => 'Edit profile';

  @override
  String get profileEditLoadFailed => 'Failed to load profile';

  @override
  String get profileEditUnavailable =>
      'No in-app profile-edit route is available.';

  @override
  String get profileEditPending =>
      'Changes were submitted and await verification.';

  @override
  String get profileEditConfirmed => 'Profile confirmed and synchronized.';

  @override
  String get profileEditDisplayName => 'Display name';

  @override
  String get profileEditComment => 'Bio';

  @override
  String get profileEditWebpage => 'Web page';

  @override
  String get profileEditAvatar => 'Avatar';

  @override
  String get profileEditBackground => 'Background image';

  @override
  String get profileEditCurrentPassword => 'Current password';

  @override
  String get profileEditFieldUnsupported =>
      'This field is not supported by the current route';

  @override
  String get profileEditImageChoose => 'Choose a supported image';

  @override
  String get profileEditChooseImage => 'Choose image';

  @override
  String get profileEditSave => 'Save profile';

  @override
  String get profileEditLeaveTitle => 'Discard unsaved changes?';

  @override
  String get profileEditLeaveDetail =>
      'Your changes have not been submitted and will be lost.';

  @override
  String get profileEditLeaveConfirm => 'Discard changes';

  @override
  String get accountManagement => 'Account management';

  @override
  String get addAccount => 'Add account';

  @override
  String get switchAccount => 'Switch account';

  @override
  String get accountSwitching => 'Switching…';

  @override
  String get removeAccount => 'Remove account';

  @override
  String get removeAccountConfirm => 'Remove this account?';

  @override
  String get noAccounts => 'No accounts';

  @override
  String get profileReadOnly =>
      'This screen shows saved account metadata. Full profile editing belongs to the profile module.';

  @override
  String get serverDisplaySettings => 'Account display settings';

  @override
  String get serverDisplayHint =>
      'Stored by Pixiv; these flags shape what the API returns for this account.';

  @override
  String get serverShowAi => 'Show AI-generated works';

  @override
  String get serverRestrictedMode => 'Restricted mode';

  @override
  String get serverDisplayLoadFailed => 'Failed to load server settings';

  @override
  String get serverDisplayWriteFailed => 'Failed to save server setting';

  @override
  String get backupSettings => 'Backup & restore';

  @override
  String get backupHint =>
      'Exports settings, the mute list and browsing history. Credentials are never written to the file.';

  @override
  String get backupExport => 'Export backup';

  @override
  String get backupExportHint =>
      'Writes pixiv-func-backup-*.json into a directory you choose';

  @override
  String backupExported(String name) {
    return 'Exported $name';
  }

  @override
  String get backupExportFailed => 'Export failed';

  @override
  String get backupImport => 'Import backup';

  @override
  String get backupImportHint => 'Import from a JSON file; merge or overwrite';

  @override
  String get backupImportInvalid => 'Invalid backup file';

  @override
  String get backupImportFailed => 'Import failed';

  @override
  String get backupImportStrategyTitle => 'Choose how to import';

  @override
  String backupImportPrompt(
    int tags,
    int users,
    int works,
    int history,
    String account,
  ) {
    return 'The file contains $tags muted tags, $users muted users, $works muted works and $history history rows.\nExported by account: $account';
  }

  @override
  String get backupImportOverwriteNote =>
      'Overwrite clears local history and replaces muted works first; server-side mutes are add-only and are never deleted by an import.';

  @override
  String get backupMerge => 'Merge';

  @override
  String get backupOverwrite => 'Overwrite';

  @override
  String get backupMergeHint =>
      'Keep existing data and add the file\'s contents';

  @override
  String get backupOverwriteHint =>
      'Replace local data with the file\'s contents';

  @override
  String backupImportMergeConfirmTitle(
    int tags,
    int users,
    int works,
    int history,
  ) {
    return 'Merge will add $tags muted tags, $users muted users, $works muted works and $history history rows';
  }

  @override
  String get backupImportOverwriteConfirmTitle =>
      'Local history will be cleared; muted works and settings will follow the file';

  @override
  String backupImportDone(int tags, int users, int works, int history) {
    return 'Imported: +$tags tags, +$users users, $works work-mute changes, $history history rows';
  }

  @override
  String get imageSource => 'Image source';

  @override
  String get imageSourceNormal => 'Official (default)';

  @override
  String get imageSourcePixivCat => 'pixiv.cat mirror';

  @override
  String get imageSourcePixivRe => 'pixiv.re mirror';

  @override
  String get imageSourcePixivNl => 'pixiv.nl mirror';

  @override
  String get imageSourceCustom => 'Custom reverse proxy';

  @override
  String get imageSourceCustomHint =>
      'https://host[/path], e.g. https://i.pixiv.cat';

  @override
  String get imageSourceCustomUnset => 'Not configured';

  @override
  String get imageSourceCustomInvalid =>
      'Invalid source: needs https, a DNS host name and port 443';

  @override
  String get imageSourceApplyAndTest => 'Apply and test';

  @override
  String imageSourceTestOk(String code) {
    return 'Mirror reachable (HTTP $code)';
  }

  @override
  String get imageSourceTestFailed => 'Mirror connectivity test failed';

  @override
  String get imageSourceUnreachableMainland =>
      'Usually unreachable from mainland networks';

  @override
  String get imageSourceAuto => 'Auto (race mirrors on this network)';

  @override
  String imageSourceAutoWinner(String host) {
    return 'Current: $host';
  }

  @override
  String get imageSourceAutoPending =>
      'Not measured yet — falls back to direct';

  @override
  String get previewQuality => 'Preview quality';

  @override
  String get viewQuality => 'Viewer quality';

  @override
  String get detailQuality => 'Detail quality';

  @override
  String get qualityMedium => 'Medium';

  @override
  String get qualityLarge => 'Large';

  @override
  String get qualityOriginal => 'Original';

  @override
  String get scaleQuality => 'Viewer quality (original)';

  @override
  String get localHistory => 'Local browsing history';

  @override
  String get pixivHistory => 'Pixiv browsing history';

  @override
  String get blockR18 => 'Locally block R-18 works';

  @override
  String get blockAI => 'Locally block AI works';

  @override
  String get hideMuted => 'Hide muted works';

  @override
  String get hideMutedHint =>
      'When off, muted works appear as blurred cards; tap once to peek';

  @override
  String get mutedContent => 'Muted';

  @override
  String get mutedItemsSettings => 'Muted items';

  @override
  String get mutedTagsSection => 'Muted tags';

  @override
  String get mutedUsersSection => 'Muted users';

  @override
  String get mutedWorksSection => 'Muted works';

  @override
  String get mutedEmpty => 'Nothing muted yet';

  @override
  String get muteTagInputHint => 'Tag to mute';

  @override
  String get muteWork => 'Mute this work';

  @override
  String get unmuteWork => 'Unmute this work';

  @override
  String get muteAuthor => 'Mute author';

  @override
  String get unmuteAuthor => 'Unmute author';

  @override
  String get unmuteTag => 'Unmute';

  @override
  String muteFailed(Object error) {
    return 'Mute operation failed: $error';
  }

  @override
  String get reduceMotion => 'Reduce motion';

  @override
  String get reduceMotionHint =>
      'Turn off decorative animation: page transitions, list entrances and press feedback';

  @override
  String get maxDownloadCount => 'Maximum concurrent downloads';

  @override
  String get maxDownloadCountHint => 'Drag to preview; release to apply';

  @override
  String get namingRule => 'File naming rule';

  @override
  String get namingRuleHint => 'Leave empty to use the default name';

  @override
  String get saveFolder => 'Save folder';

  @override
  String get saveLocation => 'Save location';

  @override
  String get saveLocationAlbum => 'Album';

  @override
  String get saveLocationPixivAlbum => 'PixivFunc album (default)';

  @override
  String get saveLocationCustomAlbum => 'Custom album name';

  @override
  String get saveLocationCustomAlbumHint =>
      'Letters, digits, CJK and underscore only';

  @override
  String get saveLocationAlbumInvalid => 'Invalid album name';

  @override
  String get saveLocationSafFolder => 'Folder (system directory picker)';

  @override
  String get saveLocationSafFolderHint =>
      'Picks a directory via the system SAF and persists the grant';

  @override
  String get safStorageInternal => 'Internal storage';

  @override
  String safStorageSdCard(String volume) {
    return 'SD card ($volume)';
  }

  @override
  String get saveLocationUriCopied => 'Folder URI copied';

  @override
  String get namingPreset => 'File naming preset';

  @override
  String get namingPresetId => 'Work ID (default)';

  @override
  String get namingPresetArtistTitleId => 'Artist - title - ID';

  @override
  String get namingPresetTitleId => 'Title - ID';

  @override
  String get namingPresetCustom => 'Custom template';

  @override
  String get namingTemplate => 'Naming template';

  @override
  String namingTemplateHint(
    String artist,
    String title,
    String id,
    String page,
    String ext,
  ) {
    return '${artist}_${title}_${id}_p$page.$ext';
  }

  @override
  String get namingTemplateInvalid =>
      'Template has unsupported variables or illegal characters';

  @override
  String get namingPreview => 'Preview';

  @override
  String namingTemplateVariables(String variables) {
    return 'Variables: $variables; illegal characters become _, and long names are trimmed.';
  }

  @override
  String get notConfigured => 'Not configured';

  @override
  String get translateProvider => 'Translation service';

  @override
  String get translateGoogle => 'Google Translate';

  @override
  String get translateDisabled => 'Disabled';

  @override
  String get translateBaidu => 'Baidu Translate';

  @override
  String get translateLlm => 'Custom LLM (OpenAI-compatible)';

  @override
  String get translateBaiduCredential => 'Baidu AppID / secret';

  @override
  String get translateLlmCredential => 'LLM endpoint & key';

  @override
  String get translateBaiduAppId => 'AppID';

  @override
  String get translateBaiduSecret => 'Secret';

  @override
  String get translateLlmBaseUrl => 'Base URL (HTTPS)';

  @override
  String get translateLlmApiKey => 'API key';

  @override
  String get translateLlmModel => 'Model (optional)';

  @override
  String get translateCredentialsSave => 'Save to secure storage';

  @override
  String get translateCredentialsClear => 'Clear credentials';

  @override
  String get translateCredentialsClearConfirm =>
      'Deletes the stored credentials; they must be entered again before translation works.';

  @override
  String get translateCredentialsSaved => 'Saved to secure storage';

  @override
  String get translateCredentialsCleared => 'Credentials cleared';

  @override
  String get translateCredentialsStoreError =>
      'Secure storage operation failed';

  @override
  String get translateCredentialsInvalid =>
      'Incomplete input or endpoint is not HTTPS';

  @override
  String get translateBaiduHint =>
      'Baidu standard needs no verification but allows only 50k chars/month at 1 QPS, too little for comments; premium requires personal real-name verification (name + ID number) for 1M chars/month at 10 QPS. Credentials are used only for translation requests.';

  @override
  String get translateLlmCredentialHint =>
      'HTTPS endpoints only; translation uses a fixed prompt without model/advanced knobs. Comment text and translations are never persisted.';

  @override
  String get translateCredentialHint =>
      'Translation credentials are never written to ordinary settings; secure storage owns them when needed.';

  @override
  String get historySettingsHint =>
      'The history module reads these switches; disabled histories do not receive new records.';

  @override
  String get downloaderSettingsHint =>
      'Download tasks are maintained live by the shared DownloadManager.';

  @override
  String get downloadTasksEmpty => 'No download tasks';

  @override
  String get downloadQueued => 'Queued';

  @override
  String get downloadRunning => 'Downloading';

  @override
  String get downloadCanceling => 'Canceling';

  @override
  String get downloadSucceeded => 'Completed';

  @override
  String get downloadFailed => 'Failed';

  @override
  String get downloadCanceled => 'Canceled';

  @override
  String get retryDownload => 'Retry';

  @override
  String get cancelDownload => 'Cancel';

  @override
  String get downloadPaused => 'Paused';

  @override
  String get pauseDownload => 'Pause';

  @override
  String get downloadProcessing => 'Processing';

  @override
  String get downloadViewResult => 'View';

  @override
  String get downloadRemoveRecord => 'Remove';

  @override
  String downloadBatchCancelConfirm(int count) {
    return 'Cancel the $count selected download(s)? Unfinished progress will be discarded.';
  }

  @override
  String downloadBatchRemoveConfirm(int count) {
    return 'Remove the $count selected record(s)? Only the records are removed — downloaded files stay.';
  }

  @override
  String get resumeDownload => 'Resume';

  @override
  String downloadGroupTitle(int count) {
    return 'Batch download · $count items';
  }

  @override
  String downloadGroupProgress(int done, int count) {
    return '$done/$count completed';
  }

  @override
  String get downloadAuthorWorks => 'Download all works';

  @override
  String get downloadAuthorWorksTitle => 'Download all author works';

  @override
  String downloadAuthorEnumerating(int count) {
    return 'Enumerating works… $count found';
  }

  @override
  String downloadAuthorConfirmBody(int works, int pages) {
    return 'Download $works works ($pages pages) by this author.';
  }

  @override
  String downloadAuthorTruncated(int max) {
    return 'Too many works — only the first $max will be downloaded.';
  }

  @override
  String get downloadAuthorEmpty => 'This author has no downloadable works.';

  @override
  String downloadAuthorFailed(String error) {
    return 'Failed to enumerate works: $error';
  }

  @override
  String get downloadCaption => 'Export work caption';

  @override
  String get downloadCaptionHint =>
      'Save the title, author and caption as a matching .txt next to downloaded illusts and manga';

  @override
  String get aboutVersion => 'Version';

  @override
  String get aboutCheckUpdate => 'Check for updates';

  @override
  String get aboutCheckingUpdate => 'Checking for updates…';

  @override
  String get aboutUpdateAvailable => 'Update available';

  @override
  String get aboutUpdateOpen => 'View';

  @override
  String get aboutExportLogs => 'Export logs';

  @override
  String get aboutNoLogs => 'No logs yet';

  @override
  String get aboutUpdateNoUpdate => 'You are up to date';

  @override
  String get aboutUpdatePrerelease =>
      'A prerelease is available; the stable channel will not install it';

  @override
  String get aboutUpdateDownload => 'Download and install';

  @override
  String get aboutUpdateDownloading => 'Downloading and verifying…';

  @override
  String get aboutUpdateConfirmTitle => 'Confirm update';

  @override
  String get aboutUpdateConfirmDetail =>
      'Only an APK passing signature, size, hash, package and certificate checks will be installed. Continue?';

  @override
  String get aboutUpdatePermission =>
      'Allow this source to install apps, then confirm the installation again.';

  @override
  String get aboutUpdateStarted => 'The system installer was opened';

  @override
  String get aboutUpdateStore =>
      'Updates for this build are managed by F-Droid.';

  @override
  String get aboutUpdateUnavailable =>
      'Update checks are currently unavailable';

  @override
  String get aboutUpdateFailed =>
      'The update check or installation failed. Try again later.';

  @override
  String get aboutUpdateOffline =>
      'Could not reach the update server — check the network connection and try again';

  @override
  String get aboutUpdateRateLimited =>
      'GitHub rate limit reached — try again later';

  @override
  String get aboutUpdateInvalid =>
      'The update manifest is invalid — please report this';

  @override
  String get aboutUpdateBusy => 'An update task is already in progress';

  @override
  String get aboutUpdateCanceled => 'The update installation was canceled';

  @override
  String get aboutLicense => 'License';

  @override
  String get aboutAttribution => 'Attribution';

  @override
  String get aboutSource => 'Source code';

  @override
  String get aboutLicenseText =>
      'This project is based on the public Pixiv Func source and follows GNU AGPL v3.0.';

  @override
  String get aboutAttributionText => 'Copyright and maintained by Lopution.';

  @override
  String get settingsReadFailed => 'Failed to read settings';

  @override
  String get settingsWriteFailed => 'Failed to save settings';

  @override
  String get settingsSummaryOn => 'On';

  @override
  String get settingsSummaryOff => 'Off';

  @override
  String settingsHistorySummary(String local, String pixiv) {
    return 'Local $local · Pixiv $pixiv';
  }

  @override
  String settingsMutedSummary(int count) {
    return '$count muted items';
  }

  @override
  String settingsDownloadTasksSummary(int count) {
    return '$count active tasks';
  }

  @override
  String get settingsCredentialConfigured => 'Configured';

  @override
  String get settingsCredentialNotConfigured => 'Not configured';

  @override
  String get add => 'Add';

  @override
  String get viewerNoImages => 'No images to display';

  @override
  String get downloadAll => 'Download All';

  @override
  String get downloadQueuedMessage => 'Added to the download queue';

  @override
  String downloadSubmissionFailed(String error) {
    return 'Download failed: $error';
  }

  @override
  String get ugoiraSaveGif => 'Save GIF';

  @override
  String get ugoiraLoadCanceled => 'Loading was canceled';

  @override
  String get ugoiraLoginRequired => 'Sign in before saving the GIF';

  @override
  String get ugoiraSaved => 'GIF saved';

  @override
  String get ugoiraSaveCanceled => 'GIF save canceled';

  @override
  String ugoiraSaveFailed(String error) {
    return 'GIF save failed: $error';
  }

  @override
  String ugoiraArchiveInvalid(String error) {
    return 'The animation archive is invalid: $error';
  }

  @override
  String ugoiraFrameCorrupt(String error) {
    return 'An animation frame is corrupt: $error';
  }

  @override
  String ugoiraLoadFailed(String error) {
    return 'Animation failed to load: $error';
  }

  @override
  String get homeRecommended => 'Recommended';

  @override
  String get homeRanking => 'Ranking';

  @override
  String get homeMe => 'Me';

  @override
  String get homeExitHint => 'Press back again to exit';

  @override
  String get bookmarkIllust => 'Bookmark illustration';

  @override
  String get bookmarkNovel => 'Bookmark novel';

  @override
  String bookmarkOperationFailed(String error) {
    return 'Bookmark operation failed: $error';
  }

  @override
  String get save => 'Save';

  @override
  String get saved => 'Saved';

  @override
  String get retry => 'Retry';

  @override
  String get refresh => 'Refresh';

  @override
  String get relatedWorks => 'Related works';

  @override
  String get cancel => 'Cancel';

  @override
  String get confirm => 'Confirm';

  @override
  String get continueAction => 'Continue';

  @override
  String get rankingDay => 'Daily';

  @override
  String get rankingDayR18 => 'Daily (R-18)';

  @override
  String get rankingDayMale => 'Daily (Male favorite)';

  @override
  String get rankingDayMaleR18 => 'Daily (Male favorite & R-18)';

  @override
  String get rankingDayFemale => 'Daily (Female favorite)';

  @override
  String get rankingDayFemaleR18 => 'Daily (Female favorite & R-18)';

  @override
  String get rankingWeek => 'Weekly';

  @override
  String get rankingWeekR18 => 'Weekly (R-18)';

  @override
  String get rankingWeekOriginal => 'Weekly (Original)';

  @override
  String get rankingWeekRookie => 'Weekly (Rookie)';

  @override
  String get rankingWeekAi => 'Weekly (AI)';

  @override
  String get rankingWeekAiR18 => 'Weekly (AI & R-18)';

  @override
  String get rankingWeekR18G => 'Weekly (R-18G)';

  @override
  String get rankingMonth => 'Monthly';

  @override
  String get rankingEmpty => 'No ranking content';

  @override
  String rankingLoadFailed(String mode) {
    return '$mode failed to load';
  }

  @override
  String get rankingLoadMoreFailed => 'Failed to load more';

  @override
  String get profileWork => 'Works';

  @override
  String get profileBookmarked => 'Bookmarked';

  @override
  String get profileFollowing => 'Following';

  @override
  String get profileFans => 'Fans';

  @override
  String get profileMyPixiv => 'My Pixiv';

  @override
  String get profileAbout => 'About';

  @override
  String get profileIllust => 'Illustration';

  @override
  String get profileManga => 'Manga';

  @override
  String get profileNovel => 'Novel';

  @override
  String get searchTitle => 'Search';

  @override
  String get searchHint => 'Search works, users or tags';

  @override
  String get searchReverseImage => 'Reverse image';

  @override
  String get searchTrending => 'Trending tags';

  @override
  String get searchNoTrending => 'No trending tags';

  @override
  String get searchTrendingFailed => 'Failed to load trending tags';

  @override
  String get searchIllustManga => 'Illust & Manga';

  @override
  String get searchNovel => 'Novel';

  @override
  String get searchUser => 'User';

  @override
  String get searchCancel => 'Cancel';

  @override
  String get searchSubmit => 'Search';

  @override
  String get searchClear => 'Clear';

  @override
  String get searchLoading => 'Searching';

  @override
  String get searchNoResults => 'No search results';

  @override
  String get searchLoadFailed => 'Search failed';

  @override
  String get searchLoadMoreFailed => 'Failed to load more results';

  @override
  String get searchRetry => 'Retry';

  @override
  String get searchRefreshFailed => 'Refresh failed';

  @override
  String get searchInputEmpty => 'Enter a search term';

  @override
  String get searchReverseUnavailable => 'Reverse image search unavailable';

  @override
  String get searchReverseUnavailableDetail =>
      'No structured service has passed credential, terms and privacy review; the image is not uploaded or scraped through a web page.';

  @override
  String get searchReversePick => 'Choose image';

  @override
  String get searchReversePrivacy => 'Privacy notice';

  @override
  String get searchReversePrivacyDetail =>
      'The image is sent only after you confirm a search and temporary data is cleaned after cancellation or failure.';

  @override
  String get searchReversePreparing => 'Preparing image…';

  @override
  String get searchReverseSearching => 'Searching…';

  @override
  String get searchReverseCancel => 'Cancel';

  @override
  String get searchReverseUse => 'Start reverse search';

  @override
  String get searchReverseRetry => 'Choose another image';

  @override
  String get searchReverseReady => 'Image is ready';

  @override
  String get searchReverseNoResults => 'No matching results';

  @override
  String get searchReverseIntentFailed => 'The shared image cannot be used';

  @override
  String get searchReverseOpenExternal => 'Open source';

  @override
  String get searchReverseOpenFailed => 'Could not open the source link';

  @override
  String get searchReverseRateLimited => 'Too many searches, try again later';

  @override
  String searchReverseRateLimitedWait(int seconds) {
    return 'Try again in about $seconds seconds';
  }

  @override
  String get searchReverseDailyLimit =>
      'Daily anonymous search quota reached. Try again tomorrow.';

  @override
  String searchReverseChallenge(String engine) {
    return '$engine requires human verification. This search did not finish. Try again later.';
  }

  @override
  String get searchReversePageLoadFailed => 'The result page failed to load';

  @override
  String get searchReverseUploadTapHint =>
      'Tap the upload button on the page to search; the selected image is filled in automatically.';

  @override
  String get searchReverseUploadPickHint =>
      'Pick the same image again in the page’s file chooser.';

  @override
  String get searchReverseRetrySameEngine => 'Retry this engine';

  @override
  String get searchReverseEngineUnsupported =>
      'The selected image doesn\'t meet this engine\'s input limits';

  @override
  String get searchReverseIntro =>
      'The selected image is uploaded to the chosen engine; the result page opens inside the app.';

  @override
  String get searchReverseFailed => 'Search failed';

  @override
  String get searchReverseDone => 'Done';

  @override
  String searchReverseResultCount(int count) {
    return '$count results';
  }

  @override
  String get searchReverseEngineSwitch => 'Switch engine';

  @override
  String get searchNoRepresentative => 'This tag has no representative work';

  @override
  String get searchFilters => 'Filters';

  @override
  String get searchReset => 'Reset';

  @override
  String get searchApply => 'Apply';

  @override
  String get searchTarget => 'Search target';

  @override
  String get searchPartialTags => 'Partial tag match';

  @override
  String get searchExactTags => 'Exact tag match';

  @override
  String get searchTitleCaption => 'Title and caption';

  @override
  String get searchSort => 'Sort';

  @override
  String get searchDateDesc => 'Newest';

  @override
  String get searchDateAsc => 'Oldest';

  @override
  String get searchPopularDesc => 'Popular';

  @override
  String get searchPopularMaleDesc => 'Popular (male)';

  @override
  String get searchPopularFemaleDesc => 'Popular (female)';

  @override
  String get searchAiSection => 'AI works';

  @override
  String get searchAiAll => 'All';

  @override
  String get searchAiExclude => 'Hide AI';

  @override
  String get searchAiOnly => 'AI only';

  @override
  String get searchBookmarkSection => 'Bookmarks';

  @override
  String get searchMin => 'Min';

  @override
  String get searchMax => 'Max';

  @override
  String get searchRatioSection => 'Aspect ratio';

  @override
  String get searchRatioAny => 'Any';

  @override
  String get searchRatioLandscape => 'Landscape';

  @override
  String get searchRatioPortrait => 'Portrait';

  @override
  String get searchRatioSquare => 'Square';

  @override
  String get searchContentSection => 'Content type';

  @override
  String get searchContentAll => 'Illust·manga·ugoira';

  @override
  String get searchContentIllustUgoira => 'Illust·ugoira';

  @override
  String get searchContentIllust => 'Illust only';

  @override
  String get searchContentUgoira => 'Ugoira only';

  @override
  String get searchContentManga => 'Manga only';

  @override
  String get searchResolutionSection => 'Resolution';

  @override
  String get searchWidth => 'Width';

  @override
  String get searchHeight => 'Height';

  @override
  String get searchDuration => 'Published';

  @override
  String get searchAllTime => 'Any time';

  @override
  String get searchWithinDay => 'Within a day';

  @override
  String get searchWithinWeek => 'Within a week';

  @override
  String get searchWithinMonth => 'Within a month';

  @override
  String get searchStartDate => 'Start date';

  @override
  String get searchEndDate => 'End date';

  @override
  String get searchInvalidDateRange => 'Start date cannot be after end date';

  @override
  String get searchPopularPreviewHint =>
      'Without Pixiv Premium, popular sort uses preview results';

  @override
  String get searchNoSuggestions => 'No suggestions';

  @override
  String get searchSuggestionFill => 'Fill into search box';

  @override
  String get searchSuggestionSearch => 'Search now';

  @override
  String get searchModifyQuery => 'Edit search';

  @override
  String get searchUserAccount => 'Account';

  @override
  String get illustDetailTitle => 'Artwork';

  @override
  String get illustDetailCreateDateUnknown => 'Upload date unknown';

  @override
  String illustDetailCreateDate(String date) {
    return 'Uploaded on $date';
  }

  @override
  String illustDetailSize(int width, int height) {
    return 'Size: ${width}x$height';
  }

  @override
  String illustDetailOpenLinkFailed(String error) {
    return 'Could not open the link: $error';
  }

  @override
  String illustDetailRestricted(int id) {
    return 'This artwork has been deleted or restricted (ID: $id)';
  }

  @override
  String get illustDetailNotFound =>
      'This artwork does not exist or was deleted';

  @override
  String get illustDetailLoadFailed => 'Failed to load the artwork';

  @override
  String get commentTitle => 'Comments';

  @override
  String get commentInput => 'Add a comment';

  @override
  String get commentReply => 'Reply';

  @override
  String get commentReplyTo => 'Reply to';

  @override
  String get commentCancelReply => 'Cancel reply';

  @override
  String get commentSend => 'Send';

  @override
  String get commentDelete => 'Delete comment';

  @override
  String get commentDeleteConfirm => 'Delete this comment?';

  @override
  String get commentDeleteFailed => 'Failed to delete comment';

  @override
  String get commentSendFailed => 'Failed to send comment';

  @override
  String get commentLoadFailed => 'Failed to load comments';

  @override
  String get relatedLoadFailed => 'Failed to load related works';

  @override
  String get commentLoadMoreFailed => 'Failed to load more comments';

  @override
  String get commentNoResults => 'No comments';

  @override
  String get commentReplies => 'Replies';

  @override
  String get commentTranslate => 'Translate';

  @override
  String get commentTranslation => 'Translation';

  @override
  String get commentTranslationUnavailable =>
      'Translation is unavailable. Enable it in Settings.';

  @override
  String get commentTranslationFailed => 'Translation failed';

  @override
  String get commentTranslationInvalidCredentials =>
      'Translation credentials are invalid; check settings';

  @override
  String get commentTranslationRateLimited =>
      'Too many translations or quota exhausted';

  @override
  String get commentEmoji => 'Emoji';

  @override
  String get commentSending => 'Sending';

  @override
  String commentStampLabel(int id) {
    return 'Stamp $id';
  }

  @override
  String get commentStamps => 'Stamps';

  @override
  String get commentPermissionDenied => 'You can only delete your own comments';

  @override
  String get newTitle => 'New';

  @override
  String get newFollowing => 'Following';

  @override
  String get newEveryone => 'Everyone';

  @override
  String get newMyPixiv => 'My Pixiv';

  @override
  String get newIllust => 'Illust';

  @override
  String get newNovel => 'Novel';

  @override
  String get recommendedIllust => 'Illust';

  @override
  String get recommendedManga => 'Manga';

  @override
  String get recommendedNovel => 'Novel';

  @override
  String get recommendedUser => 'Users';

  @override
  String get recommendedEmpty => 'No recommendations';

  @override
  String get recommendedLoadFailed => 'Failed to load recommendations';

  @override
  String get recommendedLoadMoreFailed => 'Failed to load more';

  @override
  String get recommendedEnd => 'No more';

  @override
  String get newLoading => 'Loading new works';

  @override
  String get newEmpty => 'No content';

  @override
  String get newLoadFailed => 'Failed to load new works';

  @override
  String get newLoadMoreFailed => 'Failed to load more';

  @override
  String get newRetry => 'Retry';

  @override
  String get newRefreshFailed => 'Refresh failed';

  @override
  String get recommendedRefreshFailed => 'Refresh failed';

  @override
  String get profileId => 'User ID';

  @override
  String get profileAccount => 'Account';

  @override
  String get profileIntroduction => 'Introduction';

  @override
  String get profileBirthday => 'Birthday';

  @override
  String get profileGender => 'Gender';

  @override
  String get profileRegion => 'Region';

  @override
  String get profileJob => 'Job';

  @override
  String get profileWebsite => 'Website';

  @override
  String get profileWorkspace => 'Workspace';

  @override
  String get profileStats => 'Statistics';

  @override
  String get profileLoading => 'Loading user profile';

  @override
  String get profileNotFound => 'User does not exist or was removed';

  @override
  String get profileBlocked => 'This user profile is unavailable';

  @override
  String get profileLoadFailed => 'Failed to load user profile';

  @override
  String get profileItemsEmpty => 'No content';

  @override
  String get profileLoadMoreFailed => 'Failed to load more';

  @override
  String get profileRetry => 'Retry';

  @override
  String get profileNovelPending =>
      'Novel lists will be connected by the Novel Reader module';

  @override
  String get profileShare => 'Share user';

  @override
  String get profileShareHint => 'Share this user link';

  @override
  String get profileShareClose => 'Close';

  @override
  String get profileSettings => 'Settings';

  @override
  String get restrictSelector => 'Choose visibility';

  @override
  String get restrictPublic => 'Public';

  @override
  String get restrictPrivate => 'Private';

  @override
  String get follow => 'Follow';

  @override
  String get followed => 'Following';

  @override
  String get followUser => 'Follow user';

  @override
  String get followPrivately => 'Follow privately';

  @override
  String get unfollow => 'Unfollow';

  @override
  String get followFailed => 'Follow action failed';

  @override
  String get userPreviewFollow => 'Follow';

  @override
  String get novelLoading => 'Loading novel';

  @override
  String get novelNotFound => 'Novel does not exist or was removed';

  @override
  String get novelRestricted => 'This novel is restricted';

  @override
  String get novelContentUnavailable =>
      'The current API did not provide the novel body';

  @override
  String get novelLoadFailed => 'Failed to load novel';

  @override
  String get novelLayoutFailed => 'Failed to lay out the novel';

  @override
  String get novelRetry => 'Retry';

  @override
  String get novelNoContent => 'No body text';

  @override
  String get novelWords => 'words';

  @override
  String get novelSeries => 'Series';

  @override
  String get novelRanking => 'Novel Ranking';

  @override
  String get novelSeriesUnavailable => 'Series information unavailable';

  @override
  String get novelInfoTitle => 'Work info';

  @override
  String get novelPrevious => 'Previous novel';

  @override
  String get novelNext => 'Next novel';

  @override
  String get novelDecreaseFont => 'Decrease font size';

  @override
  String get novelIncreaseFont => 'Increase font size';

  @override
  String get novelReadingProgress => 'Reading progress';

  @override
  String get novelReaderSettings => 'Reading settings';

  @override
  String get novelSettingsSaveFailed =>
      'Couldn\'t save reading settings — applied for this session only';

  @override
  String get novelFontSize => 'Font size';

  @override
  String get novelLineHeight => 'Line height';

  @override
  String get novelThemeSystem => 'System';

  @override
  String get novelThemePaper => 'Paper';

  @override
  String get novelThemeSepia => 'Eye care';

  @override
  String get novelThemeNight => 'Night';

  @override
  String get aboutDisplayRefreshRate => 'Display refresh rate';

  @override
  String get cardActionBookmark => 'Bookmark';

  @override
  String get cardActionUnbookmark => 'Remove bookmark';

  @override
  String get cardActionDownload => 'Download';

  @override
  String get cardActionWatchLater => 'Watch later';

  @override
  String get cardActionRemoveWatchLater => 'Remove from Watch later';

  @override
  String get cardActionShare => 'Share';

  @override
  String get share => 'Share';

  @override
  String get openInBrowser => 'Open in browser';

  @override
  String get linkCopied => 'Link copied';

  @override
  String get copyLink => 'Copy link';

  @override
  String get openLink => 'Open link';

  @override
  String get watchLaterAdded => 'Added to Watch later';

  @override
  String get watchLaterTitle => 'Watch later';

  @override
  String get watchLaterEmpty => 'Stashed works appear here';

  @override
  String get watchLaterLoadFailed => 'Watch later failed to load';

  @override
  String get bookmarkEditTitle => 'Edit bookmark';

  @override
  String get bookmarkTags => 'Bookmark tags';

  @override
  String get bookmarkTagNewHint => 'Type a tag and press enter';

  @override
  String get bookmarkTagFilterEmpty => 'No loaded works match';

  @override
  String get bookmarkTagFilterHint => 'Filter loaded works';

  @override
  String get bookmarkTagSuggestions => 'Frequent tags';

  @override
  String get bookmarkTagsEmpty => 'No bookmark tags yet';

  @override
  String get bookmarkTagsLoadFailed => 'Failed to load bookmark tags';

  @override
  String get bookmarkTagsEnd => 'All tags loaded';

  @override
  String get seriesTitle => 'Series';

  @override
  String get seriesLoadFailed => 'Failed to load series';

  @override
  String get seriesLoadMoreFailed => 'Failed to load more';

  @override
  String get seriesEmpty => 'No works in this series yet';

  @override
  String seriesWorksCount(int count) {
    return '$count works';
  }

  @override
  String seriesEpisode(int order) {
    return 'Part $order';
  }

  @override
  String get seriesStartReading => 'Start reading';

  @override
  String seriesBackToEpisode(int order) {
    return 'Back to part $order';
  }

  @override
  String get seriesBackToLast => 'Back to last opened';

  @override
  String get seriesPrevious => 'Previous';

  @override
  String get seriesNext => 'Next';

  @override
  String get watchlistTitle => 'Watchlist';

  @override
  String get watchlistManga => 'Manga';

  @override
  String get watchlistNovel => 'Novel';

  @override
  String get watchlistEmpty => 'No series in your watchlist yet';

  @override
  String get watchlistLoadFailed => 'Failed to load watchlist';

  @override
  String get watchlistLoadMoreFailed => 'Failed to load more';

  @override
  String get watchlistAdd => 'Follow series';

  @override
  String get watchlistRemove => 'Unfollow series';

  @override
  String get watchlistNewContent => 'New';

  @override
  String get localNovelsTitle => 'Local novels';

  @override
  String get localNovelsEmpty => 'No imported local novels yet';

  @override
  String get localNovelsLoadFailed => 'Failed to load local novels';

  @override
  String get localNovelsImport => 'Import TXT';

  @override
  String get localNovelsImportFailed => 'Import failed';

  @override
  String localNovelsImported(String title) {
    return 'Imported \"$title\"';
  }

  @override
  String get localNovelsImportedLossy =>
      'Imported, but the encoding was not fully recognized — the text may contain mojibake';

  @override
  String get localNovelsDelete => 'Delete';

  @override
  String localNovelsDeleteConfirm(String title) {
    return 'Delete \"$title\"? The local file will be removed too.';
  }

  @override
  String get novelChapters => 'Chapters';

  @override
  String get localNovelFileInfo => 'File info';

  @override
  String localNovelFileEncoding(String encoding) {
    return 'Encoding: $encoding';
  }

  @override
  String localNovelFileImportedAt(String date) {
    return 'Imported $date';
  }

  @override
  String localNovelsChars(int count) {
    return '$count chars';
  }

  @override
  String localNovelContinue(int percent) {
    return 'Continue reading · $percent%';
  }

  @override
  String get profileSeries => 'Series';

  @override
  String get spotlightTitle => 'Spotlight';

  @override
  String get spotlightArticleLoadFailed => 'Failed to load article';

  @override
  String get spotlightCategoryAll => 'All';

  @override
  String get spotlightCategoryIllust => 'Illustrations';

  @override
  String get spotlightCategoryManga => 'Manga';

  @override
  String get spotlightLoadFailed => 'Failed to load spotlight';

  @override
  String get spotlightLoadMoreFailed =>
      'Failed to load more spotlight articles';

  @override
  String get spotlightEmpty => 'No spotlight articles';

  @override
  String get enableHaptics => 'Haptic feedback';

  @override
  String get enableHapticsHint =>
      'Vibrate on selections, saved actions and failures';

  @override
  String get downloadSelectPages => 'Select pages to download';

  @override
  String downloadSelectedCount(int selected, int total) {
    return '$selected of $total selected';
  }

  @override
  String get selectAll => 'Select all';

  @override
  String get done => 'Done';

  @override
  String viewerPageLabel(int page, int total) {
    return 'Page $page of $total';
  }

  @override
  String get tagActionSearch => 'Search this tag';

  @override
  String get tagActionCopy => 'Copy tag name';

  @override
  String get tagActionMute => 'Mute this tag';

  @override
  String get tagActionUnmute => 'Unmute this tag';

  @override
  String get tagActionMuteMode => 'Select tags to mute';

  @override
  String get tagCopied => 'Tag copied';

  @override
  String ugoiraExporting(int percent) {
    return 'Exporting GIF… $percent%';
  }

  @override
  String get viewerEnterFullscreen => 'Enter fullscreen';

  @override
  String get viewerExitFullscreen => 'Exit fullscreen';

  @override
  String get viewerFitScreen => 'Fit to screen';

  @override
  String get viewerSavePage => 'Save current page';

  @override
  String get viewerJumpToPage => 'Jump to page';

  @override
  String get viewerInfo => 'Artwork info';

  @override
  String get viewerOpenDetail => 'Open detail page';

  @override
  String illustPagesTotal(int count) {
    return '$count pages';
  }

  @override
  String get illustInfoJump => 'Jump to artwork info';

  @override
  String get manage => 'Manage';

  @override
  String selectedCount(int n) {
    return '$n selected';
  }

  @override
  String get undo => 'Undo';

  @override
  String get watchLaterRemoved => 'Removed from Watch later';

  @override
  String get watchlistOpenContents => 'Open contents';
}
