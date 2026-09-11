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
  String get later => 'You can change it later in the settings';

  @override
  String get dark => 'Dark';

  @override
  String get light => 'Light';

  @override
  String get system => 'Follow the System';

  @override
  String get loginTitle => 'Register or Login';

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
  String loginFailed(String error) {
    return 'Login failed: $error';
  }

  @override
  String loginFailedType(String type) {
    return 'Login failed ($type)';
  }

  @override
  String get networkCompatibility => 'Automatic compatibility network';

  @override
  String get networkCompatibilityHint =>
      'Direct HTTPS is tried first; only official Pixiv destinations may try a strict HTTPS candidate after an explicit transport failure. Other traffic is never proxied and certificate checks stay enabled.';

  @override
  String get getMoreHelp => 'Get more help >>';

  @override
  String get useLoginWithClipboardHint =>
      'Or use\\nlong press on the avatar to copy account data';

  @override
  String get useLoginWithClipboard => 'Login with clipboard data';

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
  String get settingsTitle => 'Settings';

  @override
  String get accountSettings => 'Account';

  @override
  String get networkSettings => 'Network';

  @override
  String get networkMode => 'Auto compatibility mode';

  @override
  String get networkModeHint =>
      'Direct by default; only Pixiv official hosts may retry via a strict HTTPS tier after a clear transport failure. No other traffic is proxied and certificate checks are never disabled.';

  @override
  String get networkModeListTitle => 'Network mode';

  @override
  String get networkModeAutomatic => 'Automatic';

  @override
  String get networkModeAutomaticHint =>
      'Standard network stack: selects a reachable route per host group.';

  @override
  String get networkModeDirectOnly => 'Direct only';

  @override
  String get networkModeDirectOnlyHint =>
      'System DNS + real SNI direct connection. For networks known to be reachable directly.';

  @override
  String get networkAdvanced => 'Advanced';

  @override
  String get networkAdvancedHint =>
      'DoH endpoints, ECH front host and other details.';

  @override
  String get networkAdvancedReset => 'Reset to defaults';

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
      'Probes the four official Pixiv hosts layer by layer: system DNS → DoH → TCP → TLS(real SNI) → minimal request. TCP ok but TLS handshake fails = SNI blocked.';

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
  String get blockTagSettings => 'Blocked tags';

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
  String get reopen => 'Reopen';

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
  String get removeAccount => 'Remove account';

  @override
  String get removeAccountConfirm => 'Remove this account?';

  @override
  String get noAccounts => 'No accounts';

  @override
  String get profileReadOnly =>
      'This screen shows saved account metadata. Full profile editing belongs to the profile module.';

  @override
  String get imageSource => 'Image source';

  @override
  String get imageSourceNormal => 'Official CDN (system DNS / HTTPS)';

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
  String get maxDownloadCount => 'Maximum concurrent downloads';

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
  String get saveLocationUseCustomAlbum => 'Use custom album';

  @override
  String get saveLocationAlbumInvalid => 'Invalid album name';

  @override
  String get saveLocationSafFolder => 'Folder (system directory picker)';

  @override
  String get saveLocationSafFolderHint =>
      'Picks a directory via the system SAF and persists the grant';

  @override
  String get saveLocationSafPicked => 'Folder selected';

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
  String namingTemplateVariables(
    String artist,
    String title,
    String id,
    String page,
    String ext,
    String date,
  ) {
    return 'Variables: $artist $title $id $page $ext $date; illegal characters become _, and long names are trimmed.';
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
  String get blockTagInputHint => 'Enter a tag to add it';

  @override
  String get noBlockedTags => 'No blocked tags';

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
  String get aboutVersion => 'Version';

  @override
  String get aboutCheckUpdate => 'Check for updates';

  @override
  String get aboutCheckingUpdate => 'Checking for updates…';

  @override
  String get aboutUpdateAvailable => 'Update available';

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
  String get aboutLicense => 'License';

  @override
  String get aboutAttribution => 'Attribution';

  @override
  String get aboutSource => 'Source code';

  @override
  String get aboutLicenseText =>
      'This project is based on the public Pixiv Func source and follows GNU AGPL v3.0.';

  @override
  String get aboutAttributionText => 'Original author: git-xiaocao.';

  @override
  String get settingsReadFailed => 'Failed to read settings';

  @override
  String get settingsWriteFailed => 'Failed to save settings';

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
  String get relatedWorks => 'Related works';

  @override
  String get cancel => 'Cancel';

  @override
  String get confirm => 'Confirm';

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
  String get searchReverseDailyLimit => '今日匿名搜索额度已用完，明天再试';

  @override
  String get searchReverseChallenge =>
      'SauceNAO requires human verification. This search did not finish. Try again later.';

  @override
  String get searchReversePageLoadFailed => 'The result page failed to load';

  @override
  String get searchReverseIntro =>
      'The selected image is uploaded anonymously to SauceNAO; the result page opens inside the app.';

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
  String get searchNoSuggestions => 'No suggestions';

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
  String get novelRetry => 'Retry';

  @override
  String get novelNoContent => 'No body text';

  @override
  String get novelWords => 'words';

  @override
  String get novelSeries => 'Series';

  @override
  String get novelSeriesUnavailable => 'Series information unavailable';

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
}
