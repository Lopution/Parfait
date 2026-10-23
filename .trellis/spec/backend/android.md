---
prefix: DROID
applies_to:
  - android/app/src/main/kotlin/**
  - android/app/src/github/**
  - android/app/src/fdroid/**
  - android/app/src/main/AndroidManifest.xml
  - lib/core/platform/**
  - lib/core/auth/oauth_service.dart
  - lib/features/login/**
reviewed: 2026-10-14
---

# Android channels and platform boundaries

## Contents

- [Channel conventions](#channel-conventions)
- [Specific channels](#specific-channels)
- [Untrusted input and login](#untrusted-input-and-login)

## Channel conventions

### DROID-01 IO channels run on a serial background queue
- **Rule:** Channels that do file or `ContentResolver` IO (MediaStore, SAF,
  reverse-image input, the github updater, fonts) register with
  `messenger.makeBackgroundTaskQueue()`; Activity work is posted to the
  main looper through `MainThreadPoster`. `parfait/webprofile`, clipboard,
  intents, haptics and accessibility stay on main.
- **Why:** The serial queue keeps begin → write → finalize ordered off the
  UI thread; `CookieManager` is not documented as thread-safe.
- **Check:** `android/app/src/test/kotlin/io/github/lopution/parfait/SafTreeChannelTest.kt` "pickTree is posted to main", `android/app/src/test/kotlin/io/github/lopution/parfait/ReverseImageInputChannelTest.kt` "pickImage is posted to main"
- **Code:** `android/app/src/main/kotlin/io/github/lopution/parfait`

### DROID-02 Arguments and errors keep each channel's style
- **Rule:** Payloads are maps (bytes as `ByteArray`), never JSON strings.
  Required arguments go through `ChannelArgs` and fail with
  `<channel>_invalid_argument` before the operation. MediaStore, SAF, web
  profile, haptics and accessibility use `<channel>_<reason>` codes;
  reverse-image, intents and clipboard keep their unprefixed codes. Unknown
  methods return `notImplemented()`. Names, methods and payload keys change
  only by a design decision.
- **Why:** Dart maps these exact codes; renaming broke error handling.
- **Check:** `android/app/src/test/kotlin/io/github/lopution/parfait/MediaStoreChannelTest.kt` "begin missing displayName is invalid_argument" "unknown method is notImplemented"
- **Code:** `android/app/src/main/kotlin/io/github/lopution/parfait`

## Specific channels

### DROID-03 The updater reports failures in its result map
- **Rule:** The github updater returns `{valid: false, errorCode}` or
  `{status: failed, errorCode}`, never `result.error`; the fdroid flavor
  answers `disabled` for every method except `getCapability` and
  `getPlatformInfo`.
- **Why:** Dart reads these maps and the `disabled` code as they are.
- **Check:** `test/updater_flavor_contract_test.dart` "each flavor owns the same updater channel with different capability"
- **Code:** `android/app/src/github`, `android/app/src/fdroid`

### DROID-04 SAF create ignores ownerId
- **Rule:** `SafTreeChannel.create` does not read the `ownerId` Dart may
  send; keep it that way.
- **Why:** SAF ownership is checked on the Dart side; a Kotlin check would
  reject resumable documents.
- **Check:** `android/app/src/test/kotlin/io/github/lopution/parfait/SafTreeChannelTest.kt` "create ignores ownerId and still succeeds"
- **Code:** `android/app/src/main/kotlin/io/github/lopution/parfait/SafTreeChannel.kt`

### DROID-06 Haptics degrade by tier and respect the system switch
- **Rule:** The haptics tier (composition, predefined, system, none) is
  probed once per engine; the system haptics switch is read on every call.
  A `SecurityException` from the vibrator demotes to the `View` haptic
  constants for the rest of the process. Dart's `play` never throws.
- **Why:** Some ROMs refuse the vibrator; users with haptics off still felt
  vibrator-based effects.
- **Check:** `android/app/src/test/kotlin/io/github/lopution/parfait/HapticPlannerTest.kt` "a refused vibrator demotes to view constants and replays" "system touch feedback off silences the vibrator"
- **Code:** `android/app/src/main/kotlin/io/github/lopution/parfait/HapticsChannel.kt`

### DROID-09 The transfer clipboard clears only its own content
- **Rule:** An exported account envelope is written with its SHA-256
  fingerprint, marked sensitive where supported, and given a bounded
  expiry. Clearing on request goes through `clearIfCurrent(fingerprint)`,
  so content the user copied afterwards survives; a malformed read is not
  cleared. The expiry is a persisted record of the clip's label and system
  timestamp, never its text: it is swept only while the activity has
  window focus, and a sweep reads only `getPrimaryClipDescription`. Copy
  never promises that the clear happens.
- **Why:** An unconditional clear erased whatever the user had copied
  after starting an import. Android 10+ hides the clipboard from apps
  without focus, so an in-process timer that fired in the background, or
  died with the process, never cleared; reading clip text from another app
  raises Android 12's access notice.
- **Check:** `test/account_transfer_service_test.dart` "conditional clear does not erase content copied after import started" "clipboard read is explicit and malformed input is not cleared", `android/app/src/test/kotlin/io/github/lopution/parfait/PendingTransferClearTest.kt` "an expired export is cleared on the next sweep, even after the process died" "content copied after the export survives and the record is dropped" "without a record a sweep never looks at the clipboard"
- **Code:** `lib/core/platform/account_transfer_clipboard.dart`, `android/app/src/main/kotlin/io/github/lopution/parfait/AccountTransferClipboardChannel.kt`, `android/app/src/main/kotlin/io/github/lopution/parfait/PendingTransferClear.kt`

## Untrusted input and login

### DROID-07 Intents are untrusted input
- **Rule:** The intent channel forwards only action, opaque URI, MIME, read
  grant and bounded size. `IntentRouter` accepts VIEW only for exact Pixiv
  and app schemes, hosts and paths, and SEND only with one `EXTRA_STREAM`
  content URI, a read grant, a concrete `image/*` type and a bounded size.
  Everything else is an observable rejection, not an empty route.
- **Why:** Malformed links crashed routing; file URIs could reach private
  files.
- **Check:** `test/android_platform_boundary_test.dart` "rejects SEND without the exact stream extra and read grant" "rejects foreign, file and oversized shared payloads", `test/intent_router_test.dart` "malformed pixiv links are UnknownRoute, never crash"
- **Code:** `lib/core/platform/intent_router.dart`, `android/app/src/main/kotlin/io/github/lopution/parfait/AndroidIntentChannel.kt`

### DROID-08 The login WebView does not police navigation
- **Rule:** Whatever Pixiv's login page loads, third-party identity
  providers included, may load. The boundary is the authorization code:
  bound to a live one-use PKCE session, `state` compared when present, a
  missing, empty or duplicated `code` rejected. Only
  `AppLifecycleState.detached` ends a PKCE session.
- **Why:** An allowlist rejected destinations Pixiv itself chose; ending
  the session on background broke logins that read a code from another app.
- **Check:** `test/login_navigation_test.dart` "carries every destination the Pixiv login page chooses" "backgrounding the app keeps the login session usable", `test/login_navigation_decision_test.dart` "pixiv://account without a code aborts the session"
- **Code:** `lib/features/login`, `lib/core/auth/oauth_service.dart`

### DROID-10 One WebView plugin; Windows stops navigations as they start
- **Rule:** Embedded pages use `flutter_inappwebview` on every platform.
  `WebNavigationGuard` asks before a main-frame navigation
  (`shouldOverrideUrlLoading`) except on Windows, where it stops the
  navigation as it starts (`onLoadStart`); the login page also runs the
  decision on `onUpdateVisitedHistory` there. The reverse-image upload
  page stops navigations as they start on every platform.
- **Why:** A second plugin (`webview_flutter`) shipped about 130 KB of Dart
  for the same job. WebView2 implements the hook with CDP
  `Fetch.requestPaused`, which aborted Pixiv's authorize → login redirect
  chain mid-way; server-side redirects there can skip `onLoadStart`.
- **Check:** `test/login_navigation_test.dart` "an invalid OAuth callback ends the attempt" "Windows stops the callback as it starts or lands in history"
- **Code:** `lib/app/widgets/web_navigation_guard.dart`, `lib/features/login/login_webview_page.dart`, `lib/features/search/reverse_image_search_page.dart`
