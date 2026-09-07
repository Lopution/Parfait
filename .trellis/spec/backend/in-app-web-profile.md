# In-App Web Profile Transport

> Official same-origin profile read/write used by the native editor.

---

## Scenario: In-app Pixiv profile save

### 1. Scope / Trigger

Profile Save is a cross-layer write: native form → repository selector →
Android `CookieManager` session → `PixivPolicyHttpClient` (`pixivWeb`) →
current Pixiv SPA AJAX. Future sessions must not reopen a profile-edit
WebView, fall back to a mock/read-only success, or POST a partial profile
object that clears privacy / external-service fields.

### 2. Signatures

```dart
Future<ProfileCapabilities> ProfileEditRepository.loadCapabilities(...);
Future<UserEntity> ProfileEditRepository.loadDraft(...);
Future<ProfileEditOutcome> ProfileEditRepository.submit(
  ProfileSubmitRequest request, {
  CancelToken? cancelToken,
});

Future<String?> WebProfileSession.readSessionCookie();
bool hasWebProfileSession(String? cookie);
```

```
GET  https://www.pixiv.net/settings/profile
GET  https://www.pixiv.net/ajax/my_profile?lang=zh
POST https://www.pixiv.net/ajax/my_profile/update
```

Android channel: `pixivfunc/webprofile` (`readSession`, `clearSession`).
Host for cookies: `https://www.pixiv.net`.

### 3. Contracts

- Session: raw `Cookie` header from Android `CookieManager`. A session exists
  only when a cookie name/value pair has name `PHPSESSID` (case-insensitive)
  and a non-empty value. `device_token` alone is not a session. Do not use
  cookie-string length as the predicate.
- CSRF: parse `/settings/profile` HTML (meta tag, hidden `ct`/`tt` input, or
  escaped `serverSerializedPreloadedState.api.token`) and send it as
  `x-csrf-token`. Do not send `tt` as a multipart field; the current SPA
  does not require it.
- Read: GET `/ajax/my_profile?lang=zh` and keep the complete profile object
  (use `body.profile` when present, otherwise `body`).
- Write: POST multipart to `/ajax/my_profile/update`:
  - `profile`: JSON of the merged complete object
  - `profile_image`: optional avatar file
  - `cover_image`: optional background file
- Merge: apply only edited text fields (`name`, `comment`, `webpage`). Leave
  every other field untouched. When uploading an image, set the matching JSON
  URL to null so the server does not keep the old URL:
  - avatar upload → `profileImage: null`
  - background upload → `coverImage: null`
- Transport: `PixivPolicyHttpClient(purpose: PixivDestinationPurpose.pixivWeb)`.
  No second proxy/SNI stack and no profile-edit WebView.
- After a successful update envelope (`error != true`), refresh via
  `UserRepository.fetchDetail`. The selector must reuse the same
  `PixivWebProfileEditRepository` instance so `loadDraft`'s snapshot remains
  available if that App API refresh fails.
- UI: `lib/features/profile/profile_edit_page.dart` stays a native form.
  Keep `lib/features/login/login_webview_page.dart` as the OAuth login page
  only. Keep `WebProfileChannel` / `WebProfileSession` as the session bridge.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Missing / empty `PHPSESSID` | `ProfileEditChannel.unavailable` / `ProfileEditSubmitFailure.unavailable`; no network |
| Settings HTML has no CSRF | unavailable, retryable; do not POST |
| GET `/ajax/my_profile` non-2xx or `error: true` | `ProfileEditSubmitFailure`; do not POST |
| POST envelope `error: true` even on HTTP 200 | `ProfileEditSubmitFailure` with server `message`; never `ProfileEditConfirmed` |
| 401 / 403 | unavailable (session expired); retryable |
| `ApiCancelled` | rethrow to `ProfileEditController` |
| `http.RequestAbortedException` | convert to `ApiCancelled` and rethrow; never wrap as submit failure |
| App API `fetchDetail` fails after a successful POST | apply the patch to the cached draft and still return `ProfileEditConfirmed` |
| Empty patch | `ProfileEditFailureCode.invalid` |
| No session on the selector | `PixivProfileEditRepository` unavailable fallback; never fake success |

### 5. Good / Base / Bad Cases

- Good: login WebView established `PHPSESSID`; Save posts the complete merged
  profile plus optional image parts; CSRF is a header; local stores update
  only after `ProfileEditConfirmed`.
- Base: App API refresh fails after the web POST succeeded; the confirmed
  user is the cached draft with edited text fields applied.
- Bad: opening `/settings/profile` in a WebView; POSTing only nickname /
  comment / webpage; treating `device_token` as a session; mapping cancel /
  abort to `ProfileEditSubmitFailure`; returning success when the JSON
  envelope has `error: true`.

### 6. Tests Required

- `hasWebProfileSession`: null/empty/`device_token`/empty `PHPSESSID` →
  false; non-empty `PHPSESSID` → true.
- Protocol test: GET settings, GET `/ajax/my_profile?lang=zh`, POST
  `/ajax/my_profile/update` with `profile` JSON, `x-csrf-token`, no `tt`
  field, and preserved unedited keys.
- Image test: `profile_image` / `cover_image` parts present and
  `profileImage` / `coverImage` JSON values are null.
- Envelope `error: true` → failure, not confirmed.
- Pre-cancelled `CancelToken` and `RequestAbortedException` → `ApiCancelled`.
- `loadDraft` then successful POST then failing `fetchDetail` → confirmed
  user keeps unedited fields and applies the patch.

### 7. Wrong vs Correct

**Wrong**: construct a new `PixivWebProfileEditRepository` on every
`loadCapabilities` / `loadDraft` / `submit` call. The post-save App API
fallback then has no draft and a successful Pixiv write is shown as failure.

**Correct**: cache the web adapter on the selector for the life of the
provider, pass the same `WebProfileSession`, and only construct the
unavailable fallback when `PHPSESSID` is absent.

**Wrong**: catch every `Object` from `client.send` and return
`ProfileEditSubmitFailure`. Abort then looks like a save error.

**Correct**: `on ApiCancelled { rethrow; }` and
`on http.RequestAbortedException { throw const ApiCancelled(); }`.
