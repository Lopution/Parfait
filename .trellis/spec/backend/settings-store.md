---
prefix: PREF
applies_to:
  - lib/core/settings/**
  - lib/core/auth/credential_store.dart
  - lib/core/translation/**
  - lib/core/auth/account_transfer*.dart
reviewed: 2026-10-12
---

# Settings persistence and secrets

### PREF-01 Settings migrate field by field and keep their sources
- **Rule:** `SettingsRepository` reads the allowlisted preference map once
  into the immutable `AppSettings`, validates each field against its own
  fallback and migrates legacy keys into the versioned JSON without
  deleting the source data. One damaged field never resets the others.
- **Why:** Deleting the source on migration lost settings when a later
  build had to roll back.
- **Check:** `test/settings_test.dart` "corrupt fields fall back independently and valid fields survive" "legacy individual keys migrate to the versioned JSON key"
- **Code:** `lib/core/settings/settings_repository.dart`, `lib/core/settings/app_settings.dart`

### PREF-02 A failed write keeps the previous value visible
- **Rule:** `SettingsController` queues writes and publishes the new value
  only after the write succeeds; a failure leaves the old value and
  surfaces `SettingsWriteException`.
- **Why:** Optimistic publication showed a setting as saved when it was
  not.
- **Check:** `test/settings_test.dart` "controller serializes writes and exposes the old value on failure"
- **Code:** `lib/core/settings/settings_controller.dart`

### PREF-03 Each secret family has its own store and never enters settings
- **Rule:** Every secret family has its own secure-storage namespace and
  store class (account tokens, translation credentials); families never
  share one. `AppSettings` serializes selectors only. Secrets are read from
  the store per request, not cached in providers or widgets, so clearing
  them takes effect on the next call. `toString` redacts the secret.
- **Why:** A secret cached in a provider survived "clear"; a shared
  namespace exported one family with another.
- **Check:** `test/settings_test.dart` "plain settings JSON never contains translation credentials", `test/translation_service_test.dart` "never exposes secrets in toString", `test/account_store_test.dart` "credential toString is redacted"
- **Code:** `lib/core/auth/credential_store.dart`, `lib/core/translation/translation_credentials.dart`

### PREF-04 Remote credentials travel over HTTPS only
- **Rule:** A configured endpoint with an `http://` base URL is rejected
  before any request is built.
- **Why:** User-supplied translation endpoints would otherwise send keys in
  clear text.
- **Check:** `test/translation_service_test.dart` "rejects plain HTTP endpoints as invalid credentials"
- **Code:** `lib/core/translation/translation_service.dart`

### PREF-05 A web-login credential lives in the secure store
- **Rule:** A web session used as a credential (Doubao) is copied from the
  WebView cookie store into the secure store when the login page sees the
  session cookie, and requests send the stored copy. Signing out deletes
  the stored copy and only that site's cookies (host and parent domain),
  never `removeAllCookies`.
- **Why:** Pixiv logout clears the shared WebView store, which silently
  signed users out of translation; clearing all cookies did the reverse.
- **Check:** `test/settings_test.dart` "signing out of Doubao clears the session and its cookies"
- **Code:** `lib/core/translation/doubao_web_translation.dart`

### PREF-06 The account-transfer envelope is closed
- **Rule:** The envelope carries exactly `version`, `payloadType`,
  `payload{accountId, userId, credential{accessToken, refreshToken[,
  cookie]}}` and `checksum`; anything else is a design decision. A new
  secret family adds tests that settings JSON, the envelope and `toString`
  exclude it and that clearing it reports "not configured".
- **Why:** The envelope sits on the clipboard; extra fields would leak
  other secrets.
- **Check:** `test/account_transfer_service_test.dart` "exported envelope carries only the account credential, never translation secrets"
- **Code:** `lib/core/auth/account_transfer.dart`, `lib/core/auth/account_transfer_service.dart`
