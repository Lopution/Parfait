# Android MethodChannel Contracts

> Executable contracts for the 10 Android channels registered from
> `android/app/src/main/kotlin/io/github/lopution/pixivfunc/`. Fact source:
> `.trellis/tasks/09-07-native-rust-hygiene/research/native-audit-recount.md`
> A.2 (HEAD `8c91c37`). This file is written as **shipped state at D0**, then
> the three blanket `*_error` channels are updated in place when D2 lands in
> the same worktree so a check agent can diff code against the tables.
>
> Do not change channel names, method names, or payload keys without a design
> decision. Do not change the updater signing/verifier contract in
> [release-artifacts.md](./release-artifacts.md).

---

## Conventions (shipped)

- Payload: `Map<String, Any?>` (or a scalar for `pixivfunc/widget`
  `notifySnapshotChanged`). Bytes are `ByteArray` / Dart `Uint8List`. No JSON
  strings on the channel.
- Registration (D3): IO channels register with a **serial** background
  `BinaryMessenger.TaskQueue`:
  `MethodChannel(messenger, name, StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue())`.
  Handlers on that queue run one at a time, so MediaStore
  `begin` → N×`write` → `finalize`/`abort` and SAF `create` → `write` →
  `close`/`delete` stay ordered. `MethodChannel.Result` may be completed from
  the TaskQueue thread or the main thread (Flutter documents `Result` as
  any-thread). Activity-bound methods are posted back to the main looper
  through `MainThreadPoster` (`AndroidMainThreadPoster` in `configure`;
  `ImmediateMainThreadPoster` in JVM `handle(...)` tests).
  Channels on a background TaskQueue: `pixivfunc/mediastore` (all methods),
  `pixivfunc/saf_tree` (`pickTree` posted to main),
  `pixivfunc/reverse_image_input` (`pickImage` / `openExternal` posted to
  main), github `pixivfunc/updater` (`installApk` `startActivity` posted to
  main). Staying on main: fdroid `pixivfunc/updater` (no archive IO),
  `pixivfunc/webprofile` (`CookieManager.getCookie` / `flush` are **not**
  documented as thread-safe — official docs only say a null callback on
  `setCookie` / `removeAllCookies` is safe from a thread without a Looper;
  see https://developer.android.com/reference/android/webkit/CookieManager),
  clipboard, intents, widget, `widget_background`.
- Bindings: 9 MethodChannels + 1 EventChannel
  (`pixivfunc/android_intents/events`). No `pixivfunc/notification*`. Share and
  deeplink are not independent channels (`ACTION_SEND` / VIEW go through
  intents). `getPlatformInfo` belongs to `pixivfunc/updater`.
- `login_webview_intercept` / `LoginWebViewPlatformView`: **gone** (0 hits).
- Three error styles coexist today:
  1. Blanket `result.error("<channel>_error", message, null)` +
     `catch (Exception)` — mediastore / saf_tree (non-specific path) /
     webprofile.
  2. Specific `result.error("<code>", …)` — reverse-image, intents, clipboard,
     SAF busy/unavailable/launch/permission.
  3. **Updater exception (keep):** github methods return
     `result.success({valid:false, errorCode})` or
     `{status:failed, errorCode}` — not `result.error`. fdroid uses style 2
     with code `disabled` for every method other than `getCapability` /
     `getPlatformInfo`.
- `call.argument<T>()!!` (D0): 8 sites in `MediaStoreChannel.kt`, 7 in
  `SafTreeChannel.kt`. A missing required argument throws
  `KotlinNullPointerException`, which the blanket `catch` turns into
  `mediastore_error` / `saf_error`. D2 replaces this with an early
  `result.error("<channel>_invalid_argument", "<name> missing", null)`.
- `SafTreeChannel.create` **ignores** Dart `ownerId` (Dart may send it;
  Kotlin does not read it). Keep this behaviour.

---

## Channel index

| # | Channel | Kind | Kotlin handler | Dart caller | Thread |
|---|---------|------|----------------|-------------|--------|
| 1 | `pixivfunc/mediastore` | Method | `MediaStoreChannel.kt` | `lib/core/platform/media_store_channel.dart` | background TaskQueue |
| 2 | `pixivfunc/saf_tree` | Method | `SafTreeChannel.kt` | `lib/core/platform/saf_tree.dart` | background TaskQueue; `pickTree` → main |
| 3 | `pixivfunc/reverse_image_input` | Method | `ReverseImageInputChannel.kt` | `lib/core/reverse_image/reverse_image_platform.dart`, `reverse_image_external.dart` | background TaskQueue; `pickImage` / `openExternal` → main |
| 4 | `pixivfunc/account_transfer_clipboard` | Method | `AccountTransferClipboardChannel.kt` | `lib/core/platform/account_transfer_clipboard.dart` | main |
| 5 | `pixivfunc/android_intents` | Method | `AndroidIntentChannel.kt` | `lib/core/platform/android_intent_channel.dart` | main |
| 6 | `pixivfunc/android_intents/events` | Event | `AndroidIntentChannel.kt` | `android_intent_channel.dart` (`onNewIntent`) | main |
| 7 | `pixivfunc/webprofile` | Method | `WebProfileChannel.kt` | `lib/core/profile/web_profile_session.dart` | main (`CookieManager` not documented thread-safe) |
| 8 | `pixivfunc/widget` | Method | `WidgetForegroundChannel.kt` | `lib/core/widget/widget_channel.dart` | main |
| 9 | `pixivfunc/widget_background` | Method (**direction reversed**) | `appwidget/WidgetHeadlessRunner.kt` | `lib/core/widget/widget_background.dart` | main (engine setup) |
| 10 | `pixivfunc/updater` | Method | `android/app/src/{github,fdroid}/…/DistributionUpdaterChannel.kt` | `lib/core/updater/update_platform.dart` | github: background TaskQueue (`installApk` → main); fdroid: main |

Unknown method on every MethodChannel: `result.notImplemented()`.

---

## 1. `pixivfunc/mediastore`

- **Handler:** `MediaStoreChannel.kt` (`configure` registers the channel).
- **Dart:** `MediaStoreMethods` / `MethodChannelMediaStoreSession` in
  `lib/core/platform/media_store_channel.dart`.
- **Thread:** serial background TaskQueue (all methods: `begin` / `write` /
  `finalize` / `abort` / `listPending` / `abortPending` hit
  `ContentResolver`). Stream/`Uri` `LruCache`s are handler-only. No Activity
  work.
- **SDK_INT:** `requireApi29()` and abort paths still contain `< Q` branches
  (dead at `minSdk = 29`; D4 deletes them). Do not change those branches in D2.

### Methods

| Method | Arguments | Required | Return | Notes |
|--------|-----------|----------|--------|-------|
| `begin` | `displayName: String`, `mimeType: String`, `ownerId: String?`, `relativePath: String?` | `displayName`, `mimeType` | `Int` (MediaStore row id) | `ownerId` written into `TITLE` as `pixivfunc-owner:<id>` when present. `relativePath` default `Pictures/PixivFunc`; custom path must start with `Pictures/`, length ≤ 128, no `..` / empty / `.` segments. `displayName` 1–255, no `/` `\`. `ownerId` if present must match `[A-Za-z0-9_.-]{1,128}`. |
| `write` | `id: Int`, `bytes: ByteArray` | both | `null` | Appends to the pending stream. |
| `finalize` | `id: Int` | `id` | `String` content URI | Clears `IS_PENDING`. |
| `abort` | `id: Int` | `id` | `null` | Best-effort delete of the pending row. |
| `listPending` | _(none)_ | — | `List<Map>` with `id: Int`, `displayName: String?`, `ownerId: String?` | Every pending row; Dart cleanup still requires an exact owner match. |
| `abortPending` | `id: Int`, `ownerId: String` | both | `Boolean` | Owner-checked delete. |

### Errors (D0 shipped)

Only `result.error("mediastore_error", <exception.message>, null)` from the
outer `catch (Exception)` — including `!!` NPE, `require()`
`IllegalArgumentException`, `IllegalStateException` from insert / open /
finalize, `SecurityException`, and `UnsupportedOperationException("unsupported")`
from `requireApi29()`.

Dart does **not** switch on `mediastore_error`. `abort()` swallows any
`PlatformException`. Other methods let `PlatformException` propagate.

### Errors (D2 — check against code)

| Situation | Code | Message |
|-----------|------|---------|
| Required argument null | `mediastore_invalid_argument` | `<name> missing` |
| Required argument wrong type | `mediastore_invalid_argument` | `<name> has wrong type` |
| `require()` / `IllegalArgumentException` (bad value) | `mediastore_invalid_argument` | exception message |
| `SecurityException` | `mediastore_permission` | exception message |
| `UnsupportedOperationException` (`requireApi29`) | `mediastore_unsupported` | exception message |
| `begin` insert / id-parse / begin-time `IllegalStateException` | `mediastore_insert_failed` | exception message |
| `write` failure (`IOException` or write-time `IllegalStateException` other than missing stream) | `mediastore_write_failed` | exception message |
| Missing pending stream / missing pending row / `FileNotFoundException` | `mediastore_not_found` | exception message |
| `finalize` update failed | `mediastore_finalize_failed` | exception message |
| Any other exception | `mediastore_io_failed` | exception message |

All codes match `^[a-z_]+$` and start with `mediastore_`.

---

## 2. `pixivfunc/saf_tree`

- **Handler:** `SafTreeChannel.kt`.
- **Dart:** `MethodChannelSafTree` in `lib/core/platform/saf_tree.dart`.
- **Thread:** serial background TaskQueue for `create` / `write` / `close` /
  `delete` (`ContentResolver` / `DocumentsContract`). `pickTree` posts
  `Activity.startActivityForResult` to the main looper. `onActivityResult`
  is always main. `pendingResult` is synchronized between the handler and
  `onActivityResult`; `appContext` is `@Volatile`. The open-stream
  `mutableMapOf` is handler-only.
- **`create` / `ownerId`:** Dart `create` may pass `ownerId`
  (`saf_tree.dart`). Kotlin **does not read** `ownerId`. Behaviour is
  intentional and unchanged.

### Methods

| Method | Arguments | Required | Return | Notes |
|--------|-----------|----------|--------|-------|
| `pickTree` | _(none)_ | — | `String?` tree URI, or `null` on user cancel | Starts `ACTION_OPEN_DOCUMENT_TREE`; persistable read+write grant. |
| `create` | `treeUri: String`, `displayName: String`, `mimeType: String`, (`ownerId` ignored) | `treeUri`, `displayName`, `mimeType` | `String` document URI | `displayName` 1–255, no `/` `\`; `mimeType` non-empty. |
| `write` | `uri: String`, `bytes: ByteArray` | both | `null` | |
| `close` | `uri: String` | `uri` | `null` | |
| `delete` | `uri: String` | `uri` | `null` | Closes then `ContentResolver.delete`. |

### Errors (D0 shipped)

| Code | When |
|------|------|
| `saf_busy` | Second `pickTree` while a picker is open. |
| `saf_unavailable` | `context` is not an `Activity`. |
| `saf_launch_failed` | `startActivityForResult` threw. |
| `saf_permission` | `takePersistableUriPermission` threw `SecurityException`. |
| `saf_error` | Outer `catch (Exception)` for create/write/close/delete (and `!!` NPE). |

`onActivityResult`: `RESULT_OK` with a tree URI → persist + `success(uri)`;
user cancel (`RESULT_OK` false **or** `data.data == null` at D0) →
`success(null)`. D0 uses `data.data!!` after the null check. D2: `RESULT_OK`
with a null URI is `saf_launch_failed` (not silent cancel).

### Errors (D2 — check against code)

Keep `saf_busy`, `saf_unavailable`, `saf_launch_failed`, `saf_permission`.

| Situation | Code |
|-----------|------|
| Required argument null / wrong type | `saf_invalid_argument` (`<name> missing` / `<name> has wrong type`) |
| `require()` / `IllegalArgumentException` | `saf_invalid_argument` |
| `SecurityException` | `saf_permission` |
| `create` `IllegalStateException` / other create failure | `saf_create_failed` |
| Missing open stream / `FileNotFoundException` | `saf_not_found` |
| `write` IO failure | `saf_write_failed` |
| `delete` failure | `saf_delete_failed` |
| `close` or other IO | `saf_io_failed` |
| `RESULT_OK` and `data.data == null` | `saf_launch_failed` |

All newly emitted codes match `^[a-z_]+$` and start with `saf_`.

---

## 3. `pixivfunc/reverse_image_input`

- **Handler:** `ReverseImageInputChannel.kt`.
- **Dart:** `lib/core/reverse_image/reverse_image_platform.dart`,
  `lib/core/reverse_image/reverse_image_external.dart`.
- **Thread:** serial background TaskQueue for `copyToTemp` (64 KiB file
  copy) and `deleteTemp`. `pickImage` (`startActivityForResult`) and
  `openExternal` (`startActivity`) are posted to the main looper.
  `onActivityResult` (including `encodeReference` metadata reads) stays on
  main. `pendingPickerResult` is synchronized.

| Method | Arguments | Required | Return |
|--------|-----------|----------|--------|
| `pickImage` | _(none)_ | — | `Map{uri, mimeType, sizeBytes, hasReadUriPermission}` or `null` (cancel) |
| `copyToTemp` | `uri: String` | non-blank | `Map{path, mimeType, sizeBytes}` |
| `deleteTemp` | `path: String` | non-blank | `Boolean` |
| `openExternal` | `url: String` | non-blank https | `Boolean` (`true`) |

### Errors (pre-existing; **keep** — Dart already maps them)

These do **not** use a `reverse_image_` prefix. Do not rename in D2.

| Code | When |
|------|------|
| `invalid_uri` | Missing/blank `uri` |
| `invalid_path` | Missing/blank `path` |
| `invalid_url` | Missing/blank `url` |
| `cleanup_failed` | `deleteTemp` threw |
| `external_unavailable` | `openExternal` threw / no browser |
| `malformed_response` | Picker `RESULT_OK` with no URI |
| `picker_busy` | Picker already active |
| `picker_failed` | Picker intent could not start |
| `permission_denied` | `codeFor(SecurityException)` |
| `input_unavailable` | `codeFor(FileNotFoundException)` |
| `input_failed` | `codeFor` other |

Hard limit: 10 MiB. Only `content:` URIs. `openExternal` requires `https`,
no userInfo / port / fragment.

---

## 4. `pixivfunc/account_transfer_clipboard`

- **Handler:** `AccountTransferClipboardChannel.kt`.
- **Dart:** `lib/core/platform/account_transfer_clipboard.dart`.
- **Thread:** main.

| Method | Arguments | Required | Return |
|--------|-----------|----------|--------|
| `write` | `text: String`, `fingerprint: String`, `clearAfterMs: Number` | all, plus fingerprint == SHA-256 hex of text; delay in `[1, 600000]` ms; text length `1..32768` | `true` |
| `read` | _(none)_ | — | `{text, fingerprint}` or `null` |
| `clearIfCurrent` | `fingerprint: String` | non-blank | `Boolean` |
| `capabilities` | _(none)_ | — | `{sensitiveMarkSupported: Boolean}` (`TIRAMISU+`) |

### Errors (pre-existing; **keep**)

| Code | When |
|------|------|
| `invalid_payload` | `write` validation failed |
| `too_large` | `read` text empty or `> 32768` |
| `invalid_fingerprint` | `clearIfCurrent` fingerprint blank |

`SDK_INT >= P` clear path is a D4 dead-true branch; do not touch in D2.

---

## 5. `pixivfunc/android_intents`

- **Handler:** `AndroidIntentChannel.kt`.
- **Dart:** `lib/core/platform/android_intent_channel.dart`.
- **Thread:** main.

| Method | Arguments | Required | Return |
|--------|-----------|----------|--------|
| `getInitialIntent` | _(none)_ | — | encode `Map` (see events) |
| `openUrl` | `url: String` | http(s) after trim | `true` |

### Errors (pre-existing; **keep**)

| Code | When |
|------|------|
| `invalid_url` | Missing, unparsable, or not `http`/`https` |
| `no_handler` | `startActivity` threw |

`TIRAMISU` `getParcelableExtra` is a **kept** `SDK_INT` branch (D4).

---

## 6. `pixivfunc/android_intents/events` (EventChannel)

- **Handler:** same `AndroidIntentChannel.kt` (`EventChannel.StreamHandler`).
- **Dart:** `MethodChannelAndroidIntentSource.onNewIntent`.
- **Thread:** main.
- **Direction:** native **pushes** on `onNewIntent` via
  `AndroidIntentChannel.dispatch`.
- **Event payload** (same as `getInitialIntent`):

| Key | Type |
|-----|------|
| `action` | `String` |
| `uri` | `String?` (`ACTION_SEND` uses `EXTRA_STREAM`) |
| `mimeType` | `String?` |
| `hasReadUriPermission` | `Boolean` |
| `sizeBytes` | `Long?` |
| `extraKeys` | `List<String>` |

No `result.error` on the event stream.

---

## 7. `pixivfunc/webprofile`

- **Handler:** `WebProfileChannel.kt`.
- **Dart:** `lib/core/profile/web_profile_session.dart`.
- **Host:** `https://www.pixiv.net`. Session predicate is Dart-side
  `hasWebProfileSession` (non-empty `PHPSESSID`); see
  [in-app-web-profile.md](./in-app-web-profile.md).
- **Thread:** main. D3 did **not** move this channel.
  `android.webkit.CookieManager` official docs do not mark `getCookie` or
  `flush` `@AnyThread` / thread-safe. They only document that
  `setCookie` / `removeAllCookies` with a **null** callback may be called
  from a thread without a Looper. `flush()` “will block the caller until it
  is done and may perform I/O” but gives no thread contract. Stay on the
  platform thread.
  https://developer.android.com/reference/android/webkit/CookieManager
- **Arguments:** none on either method. There is no D2
  `webprofile_invalid_argument` path today.

| Method | Arguments | Return |
|--------|-----------|--------|
| `readSession` | _(none)_ | `String?` raw Cookie header |
| `clearSession` | _(none)_ | `true` |

### Errors (D0 shipped)

Only `result.error("webprofile_error", <exception.message>, null)`.

Dart maps **any** `PlatformException` (and `MissingPluginException`) to
`null` / `false`. Classification stays the same if the code changes.

### Errors (D2 — check against code)

| Situation | Code |
|-----------|------|
| `SecurityException` | `webprofile_permission` |
| `readSession` threw | `webprofile_read_failed` |
| `clearSession` threw | `webprofile_clear_failed` |
| Other | `webprofile_io_failed` |

All codes match `^[a-z_]+$` and start with `webprofile_`.

---

## 8. `pixivfunc/widget`

- **Handler:** `WidgetForegroundChannel.kt`.
- **Dart:** `lib/core/widget/widget_channel.dart`.
- **Thread:** main.
- **No `result.error` today.** Dart treats `PlatformException` as best-effort
  (`debugPrint` / `hasAnyWidget` → `false`).

| Method | Arguments | Return |
|--------|-----------|--------|
| `notifySnapshotChanged` | scalar `Number?` → `Long` (default `0`) | `null` |
| `clearSnapshot` | _(none)_ | `null` |
| `requestRefresh` | _(none)_ | `null` |
| `hasAnyWidget` | _(none)_ | `Boolean` |

`notifySnapshotChanged` is **not** a `Map`. Do not wrap it.

---

## 9. `pixivfunc/widget_background` — direction reversed

Typical channels are Dart → native. This one is still a MethodChannel
**invoked by Dart**, but the **native worker is the receiver**:
`WidgetHeadlessRunner` creates a headless `FlutterEngine`, registers the
handler, then runs Dart entrypoint `widgetBackgroundMain`. Dart
(`lib/core/widget/widget_background.dart`) calls `result` once; native
parses `outcome` and releases the WorkManager latch.

| Method | Arguments | Required | Return |
|--------|-----------|----------|--------|
| `result` | `outcome: String` | present (null → `TRANSIENT`) | `null` |

`outcome` values Dart sends (`WidgetFeedOutcome.name` or the timeout path):

| Dart string | Native `WidgetHeadlessRunner.Outcome` |
|-------------|----------------------------------------|
| `written` | `WRITTEN` |
| `noAccount` | `NO_ACCOUNT` |
| `authRequired` | `AUTH_REQUIRED` |
| `transientFailure` (and any other) | `TRANSIENT` |

Unknown method: `notImplemented()`. No `result.error` today. No flavor
difference. Engine create / channel wire / destroy must stay on the main
thread (`FlutterJNI` `@UiThread`).

---

## 10. `pixivfunc/updater`

- **Handlers:** flavor source sets
  `android/app/src/github/kotlin/…/DistributionUpdaterChannel.kt` and
  `android/app/src/fdroid/kotlin/…/DistributionUpdaterChannel.kt`.
- **Dart:** `lib/core/updater/update_platform.dart`.
  `PlatformException.code` is copied onto `UpdatePlatformException`.
- **Thread:** github registers a serial background TaskQueue so
  `getPackageArchiveInfo` / APK hashing in `verifyApk` (and `deleteApk`
  file IO) leave the main thread. `installApk` validates the path on that
  queue, then posts `startActivity` to the main looper; Map results stay
  `{valid:false, errorCode}` / `{status:failed, errorCode}` byte-identical.
  fdroid has no archive IO and stays on main. D5 still owns helper dedup;
  do not change signing/verifier codes here.

### Methods (both flavors)

| Method | Arguments | github return | fdroid |
|--------|-----------|---------------|--------|
| `getCapability` | _(none)_ | `{flavor:"github", enabled: BuildConfig, storeManaged:false}` | `{flavor:"fdroid", enabled:false, storeManaged:true}` |
| `getPlatformInfo` | _(none)_ | `{packageName, version, versionCode, signingCertificateSha256, supportedAbis}` | same shape |
| `verifyManifestSignature` | `message: ByteArray`, `signature: ByteArray` | `{valid:true}` **or** `{valid:false, errorCode}` | `result.error("disabled", …)` |
| `verifyApk` | `path: String`, `packageName: String`, `signingCertificateSha256: String` | `{valid:true}` **or** `{valid:false, errorCode}` | `disabled` |
| `installApk` | `path: String` | `{status: permission_required\|started}` **or** `{status:failed, errorCode}` | `disabled` |
| `deleteApk` | `path: String` | `{deleted: Boolean}` | `disabled` |

### Map `errorCode` values (github only; **not** `result.error`)

`verifyManifestSignature`: `public_key_missing`, `message_missing`,
`signature_missing`, `signature_mismatch`, `algorithm_unavailable`.
Algorithm is `SHA256withECDSA` over the **raw** manifest bytes. Do not
change these codes (see [release-artifacts.md](./release-artifacts.md)).

`verifyApk`: `apk_path_invalid`, `apk_identity_missing`, `apk_missing`,
`apk_parse_failed`, `apk_package_mismatch`, `apk_signer_mismatch`,
`apk_verification_failed`.

`installApk`: `apk_path_invalid`, `apk_missing`, `installer_unavailable`.

### fdroid-only `disabled`

`result.error("disabled", "updates are managed by the F-Droid store", null)`
is reachable **only** on the fdroid flavor, and only for methods other than
`getCapability` / `getPlatformInfo`. Keep this code. It does not use an
`updater_` prefix; Dart already consumes `UpdatePlatformException('disabled')`.

---

## `widget_snapshot/active.json` file contract

Not a MethodChannel. Dart writes; native widgets read. Path:

- Dart: `getApplicationSupportDirectory()/widget_snapshot/active.json`
  (`lib/core/widget/widget_snapshot_store.dart`).
- Android: `context.filesDir/widget_snapshot/active.json`
  (`WidgetSnapshotReader.snapshotDirectory`).

### Pointer keys (`schemaVersion` must be `1`)

| Key | Type | Rule |
|-----|------|------|
| `schemaVersion` | integer | Must be `1`; any other → empty render state |
| `accountKey` | string | `[0-9a-fA-F]{1,128}` (native). Empty / too long / bad charset → empty |
| `accountRevision` | integer ≥ 0 | Missing / negative → empty |
| `generatedAtMs` | integer | Age `> 24 h` (`MAX_AGE_MS = 86_400_000`) → `stale=true` but still renderable if items are valid. Wrapped subtraction → stale |
| `items` | array | Length 1..8 (`MAX_ITEMS = 8`). Empty after parse → empty state |

### `items[]` keys

| Key | Type | Rule |
|-----|------|------|
| `illustId` | integer | `1..Int.MAX_VALUE` |
| `title` | string | length ≤ 512 (`MAX_TEXT_LENGTH`) |
| `userId` | integer | `1..Int.MAX_VALUE` |
| `userName` | string | length ≤ 512 |
| `imageFile` | string | **file name only** (no `/`, `\`, `..`). Resolved under `widget_snapshot/images/` |

### Limits

| Limit | Value | Where |
|-------|-------|--------|
| Snapshot file bytes | **64 KiB** (`65536`) | Dart `widgetSnapshotMaxBytes`; native `MAX_SNAPSHOT_BYTES` |
| Image file bytes | **1 MiB** (`1048576`) | Dart `widgetImageMaxBytes`; native `MAX_IMAGE_BYTES` |
| Snapshot age | **24 h** | native `MAX_AGE_MS`; stale flag |
| Item count | **8** | Dart `widgetSnapshotMaxItems`; native `MAX_ITEMS` |
| Text length | **512** | title / userName |
| Account key length | **128** | hex charset |

### Lock file

Both writers take an exclusive lock on `widget_snapshot/.write.lock` before
replacing `active.json` or clearing the store. Native `clear` holds the same
lock. A crash must not leave a half-written pointer (Dart stages via temp +
rename).

Malformed JSON, unknown schema, oversize file, path-escaping `imageFile`,
or a missing/empty/oversize image file all degrade to
`WidgetRenderState.empty` (open-app state). No secrets, tokens, cookies, or
URLs may enter this file.

---

## Pre-existing codes kept without a channel prefix

D2 only rewrites `mediastore_error`, `saf_error`, and `webprofile_error`.
These codes stay because Dart already switches on them (or copies
`PlatformException.code`):

| Code | Channel | Why kept |
|------|---------|----------|
| `invalid_uri`, `invalid_path`, `invalid_url`, `cleanup_failed`, `external_unavailable`, `malformed_response`, `picker_busy`, `picker_failed`, `permission_denied`, `input_unavailable`, `input_failed` | reverse_image_input | `ReverseImagePlatformException` / external launcher |
| `invalid_payload`, `too_large`, `invalid_fingerprint` | account_transfer_clipboard | Dart clipboard adapter |
| `invalid_url`, `no_handler` | android_intents | outbound URL opener |
| `disabled` | updater (fdroid) | `UpdatePlatformException` |
| Map `errorCode` values listed in §10 | updater (github) | success-payload contract; signing verifier |

`saf_busy` / `saf_unavailable` / `saf_launch_failed` / `saf_permission`
already match `saf_<reason>` and stay.

---

## 目标状态（D2–D5 后）

D2 (this task) applies the error-code tables marked **D2 — check against
code** above. Remaining child steps:

- **D2:** No more `call.argument<T>()!!`. Missing / wrong-type arguments
  emit `<channel>_invalid_argument` with the argument name in the message.
  Blanket `mediastore_error` / `saf_error` / `webprofile_error` are gone.
  Every new code is `^[a-z_]+$` and starts with `mediastore_` / `saf_` /
  `webprofile_`. Handlers are dispatchable without an Activity
  (`handle(call, result, deps)` + JVM tests).
- **D3 (done):** MediaStore, SAF, reverse-image, and github updater
  register with `makeBackgroundTaskQueue`. Per-stream begin/write/finalize
  (and SAF create/write/close) stay ordered because the queue is serial.
  Activity work (`pickTree`, `pickImage`, `openExternal`, github
  `installApk`) is posted to main; picker `pendingResult` state is
  synchronized. fdroid updater stays on main (no archive IO).
  `pixivfunc/webprofile` stays on main — `CookieManager.getCookie`/`flush`
  are not documented thread-safe. The **Thread** column above is the
  current fact.
- **D4:** Delete 12 dead `SDK_INT < Q/P/O` branches; keep 3× `TIRAMISU`.
  Delete `drawable-v21/launch_background.xml` and debug/profile redundant
  `INTERNET`. Do not change `http://pixiv.net` deep-link filters.
- **D5:** Shared `updater/UpdaterPlatformInfo.kt` for
  `platformInfo` / `packageInfo` / `signerSha256`. Flavor files keep only
  differences. Map `{valid:false, errorCode}` / `{status:failed, errorCode}`
  and fdroid `disabled` stay. Do not change `SHA256withECDSA` or the five
  manifest codes.

Channel names, method names, payload keys, and return shapes stay as in the
tables above through D2–D5.
