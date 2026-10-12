---
prefix: PROF
applies_to:
  - lib/core/profile/**
  - lib/features/profile/profile_edit_page.dart
reviewed: 2026-10-12
---

# Profile editing

## Contents

- [Draft and commit](#draft-and-commit)
- [Channels](#channels)

## Draft and commit

### PROF-01 Send only dirty supported fields
- **Rule:** A draft captures the account id, base values and the channel's
  capabilities. The patch holds only fields that differ from the base;
  unsupported dirty fields stay visible as field errors and are never sent.
- **Why:** Sending untouched fields overwrote changes made on the web.
- **Check:** `test/profile_edit_test.dart` "builds a minimal patch from dirty supported fields only" "unsupported dirty fields stay visible and never reach the repository"
- **Code:** `lib/core/profile/profile_edit_controller.dart`

### PROF-02 Commit only a confirmed result for the current owner
- **Rule:** A confirmed response commits to `AccountStore` first, then to
  `UserStore`, after checking the current account owns the returned user.
  Verification-pending, field errors, cancellation and failure never
  update stored metadata; an account switch cancels and discards late
  results.
- **Why:** A late response after an account switch renamed the new account.
- **Check:** `test/profile_edit_test.dart` "confirmed response commits only after the ownership check" "late confirmed response after account switch cannot commit" "verification pending never commits effective user metadata"
- **Code:** `lib/core/profile/profile_edit_controller.dart`, `lib/core/profile/profile_edit_store_bridge.dart`

### PROF-03 Passwords and images are short-lived
- **Rule:** The current password is a submit input only: never in the
  draft, storage, prefilled fields or diagnostics, and cleared in the
  submit's `finally`. Selected images are validated owned handles, cleaned
  exactly once on replacement, cancel, dispose and every terminal result.
- **Why:** Credentials must not outlive the request; temp images leaked.
- **Check:** `test/profile_edit_test.dart` "current password is cleared from the submit request lifecycle" "profile image preparation validates metadata and cleans up once" "cancel releases selected images and leaves no stale path"
- **Code:** `lib/core/profile/profile_edit_controller.dart`, `lib/core/profile/profile_image.dart`

## Channels

### PROF-04 Web channel with a session, App API otherwise
- **Rule:** The selector uses the web channel when the WebView cookie jar
  holds a non-empty `PHPSESSID`, else the App API channel
  (`v1/user/profile/edit`, no background image). It caches each adapter
  for the provider's life. Editing is a native form; never open a
  profile-edit WebView.
- **Why:** The OAuth login does not reliably plant a web cookie, which made
  the editor permanently unavailable; a fresh adapter per call lost the
  draft the post-save fallback needs.
- **Check:** `test/web_profile_repository_test.dart` "does not use unrelated or empty cookie values as a session" "keeps the local draft when App API refresh fails after save", `test/app_api_profile_edit_test.dart` "capabilities advertise the app-api channel and fields"
- **Code:** `lib/core/profile/profile_edit_repository.dart`

### PROF-05 The web save posts the complete merged profile
- **Rule:** The web channel reads the CSRF token from the settings page and
  sends it as `x-csrf-token`; it reads the complete profile object, applies
  only edited text fields, and posts it with optional image parts, setting
  the matching image URL to null when uploading. Requests go through
  `PixivPolicyHttpClient` with the `pixivWeb` purpose.
- **Why:** Posting a partial object cleared privacy and external-service
  fields; a kept image URL made the server ignore the upload.
- **Check:** `test/web_profile_repository_test.dart` "round-trips the profile and posts multipart update" "uploads selected images and clears matching JSON image URLs"
- **Code:** `lib/core/profile/web_profile_repository.dart`

### PROF-06 An error envelope is a failure; cancel stays cancel
- **Rule:** A JSON envelope with `error: true` is a failure even on HTTP
  200. Cancellation and `http.RequestAbortedException` rethrow as
  `ApiCancelled`, never as a submit failure.
- **Why:** Failed saves showed as success; aborts showed as save errors.
- **Check:** `test/web_profile_repository_test.dart` "does not report success when update envelope contains an error" "request abort is rethrown as ApiCancelled", `test/app_api_profile_edit_test.dart` "a soft JSON error envelope on HTTP 200 surfaces as a failure"
- **Code:** `lib/core/profile/web_profile_repository.dart`, `lib/core/profile/app_api_profile_edit_repository.dart`
