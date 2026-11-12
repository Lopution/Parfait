---
prefix: PREF
applies_to:
  - lib/core/settings/**
  - lib/app/window/**
  - lib/core/auth/credential_store.dart
  - lib/core/translation/**
  - lib/core/auth/account_transfer*.dart
reviewed: 2026-10-14
---

# Settings persistence and secrets

## Contents

- [Migration and writes](#migration-and-writes)
- [Secrets and transfer](#secrets-and-transfer)
- [Editable state](#editable-state)

## Migration and writes

### PREF-01 Settings migrate field by field and keep their sources
- **Rule:** `SettingsRepository` reads the allowlisted preference map once
  into the immutable `AppSettings`, validates each field against its own
  fallback and migrates legacy keys into the versioned JSON without
  deleting the source data. One damaged field never resets the others.
- **Why:** Deleting the source on migration lost settings when a later
  build had to roll back.
- **Check:** `test/app_settings_test.dart` "corrupt fields fall back independently and valid fields survive" "legacy individual keys migrate to the versioned JSON key"
- **Code:** `lib/core/settings/settings_repository.dart`, `lib/core/settings/app_settings.dart`

### PREF-02 A failed write keeps the previous value visible
- **Rule:** `SettingsController` queues writes and publishes the new value
  only after the write succeeds; a failure leaves the old value and
  surfaces `SettingsWriteException`.
- **Why:** Optimistic publication showed a setting as saved when it was
  not.
- **Check:** `test/app_settings_test.dart` "controller serializes writes and exposes the old value on failure"
- **Code:** `lib/core/settings/settings_controller.dart`

## Secrets and transfer

### PREF-03 Each secret family has its own store and never enters settings
- **Rule:** Every secret family has its own secure-storage namespace and
  store class (account tokens, translation credentials); families never
  share one. `AppSettings` serializes selectors only. Secrets are read from
  the store per request, not cached in providers or widgets, so clearing
  them takes effect on the next call. `toString` redacts the secret.
- **Why:** A secret cached in a provider survived "clear"; a shared
  namespace exported one family with another.
- **Check:** `test/app_settings_test.dart` "plain settings JSON never contains translation credentials", `test/translation_service_test.dart` "never exposes secrets in toString", `test/account_store_test.dart` "credential toString is redacted"
- **Code:** `lib/core/auth/credential_store.dart`, `lib/core/translation/translation_credentials.dart`

### PREF-04 Remote credentials travel over HTTPS only
- **Rule:** A configured endpoint with an `http://` base URL is rejected
  before any request is built.
- **Why:** User-supplied translation endpoints would otherwise send keys in
  clear text.
- **Check:** `test/translation_service_test.dart` "rejects plain HTTP endpoints as invalid credentials"
- **Code:** `lib/core/translation/translation_service.dart`

### PREF-05 A public translation provider has no secret state
- **Rule:** A credential-free public translation provider never reads or
  writes `TranslationCredentialStore`, never sends an authorization header or
  cookie, and keeps its endpoint/model selectors in ordinary validated
  settings. Provider selection and selectors remain independent of the
  Baidu/LLM secret families. Retired provider codes are never reused: the
  former web-login code maps to `disabled` on settings and backup import, and
  its secure-storage session keys are purged at app startup.
- **Why:** Public Index Translate replaced the former web-login provider;
  retaining cookie or key plumbing would create an unneeded secret boundary
  and could accidentally send stale credentials.
- **Check:** `test/index_translate_translation_test.dart` "matches the public
  request contract and strips disabled thinking"; `test/app_settings_test.dart`
  "Index Translate model and thinking settings round-trip independently"
- **Code:** `lib/core/translation/index_translate_translation.dart`,
  `lib/core/settings/app_settings.dart`

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

## Editable state

### PREF-07 A user-ordered list is an Arrangement saved only when edited
- **Rule:** Every list the user orders and hides (ranking categories, the
  bottom bar) persists as `Arrangement` entries `[{id, visible}]` and
  resolves through `Arrangement.resolve`: unknown and repeated ids are
  skipped, items the payload lacks are appended with their default
  visibility, and one item always stays shown. An arrangement equal to
  the defaults is saved as null.
- **Why:** User decision: one model for every customizable list. A saved
  copy of the defaults would freeze them, so items a later version adds
  or reorders by default would never reach users who never edited.
- **Check:** `test/ranking_categories_test.dart` "unknown and repeated ids are skipped, unmentioned items appended" "a payload hiding every known item still shows one"; `test/home_destination_test.dart` "a saved bar keeps Me and two destinations whatever it says"
- **Code:** `lib/core/settings/arrangement.dart`, `lib/core/ranking/ranking_catalog.dart`, `lib/core/navigation/home_destination.dart`

### PREF-08 The desktop window's place is a setting like any other
- **Rule:** The desktop window's size, position and maximized flag live in
  the same `AppSettings` JSON (`windowWidth`/`windowHeight`/`windowX`/
  `windowY`/`windowMaximized`); reads validate finite numbers and fall back
  to `null`, which means "open at the default place on the primary
  display". A restored place is fitted to the work area it belongs to
  (`lib/app/window/window_geometry.dart`: at most 90% of it, never below
  `480x640`, centred when under 30px remains on screen). A maximized window
  saves the ordinary place it had before, and a write is debounced 400ms
  after the last move; that delay is a save debounce, not a motion token.
- **Why:** A window that reopened at the runner's phone-shaped default, or
  off a display that had been unplugged, forced the user to place it again
  every launch; writing on every drag event cost a preferences write per
  frame.
- **Check:** `test/window_geometry_test.dart` "a first launch opens at the default size" "a saved place mostly off the work area is centred instead" "a saved place picks the display it overlaps most"; `test/app_settings_test.dart` "the desktop window place round-trips; damage falls back"
- **Code:** `lib/app/window/desktop_window.dart`, `lib/app/window/window_geometry.dart`, `lib/core/settings/app_settings.dart`, `lib/core/settings/settings_controller.dart`
