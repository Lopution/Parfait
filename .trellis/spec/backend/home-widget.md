---
prefix: WIDGET
applies_to:
  - lib/core/widget/**
  - android/app/src/main/kotlin/io/github/lopution/parfait/appwidget/**
reviewed: 2026-10-12
---

# Android home widget

### WIDGET-01 The snapshot is a secret-free render cache
- **Rule:** `active.json` holds only schema version, a truncated
  non-reversible account key, the account revision, a timestamp and up to
  eight items with positive ids, bounded text and an image file name; never
  a URL, cookie, token or plaintext account id. Native code never creates
  an API, credential, DNS or TLS client.
- **Why:** The snapshot crosses into another process and must not become a
  second credential store.
- **Check:** `test/widget_snapshot_test.dart` "snapshot payload contains no URL or credential fields" "rejects non-positive ids and path-like image refs"
- **Code:** `lib/core/widget/widget_snapshot.dart`

### WIDGET-02 A new generation flips the pointer last
- **Rule:** Writers take `.write.lock`, stage uniquely named images and a
  temporary pointer, then replace `active.json` last; a failed stage keeps
  the active generation. Native reads only referenced files below the
  snapshot directory, and anything malformed renders the open-app state.
- **Why:** Clearing the pointer before staging left an empty widget after a
  failed download.
- **Check:** `test/widget_snapshot_store_test.dart` "failed image staging leaves the active generation untouched" "image reference escaping the image dir is not resolved"
- **Code:** `lib/core/widget/widget_snapshot_store.dart`

### WIDGET-03 Publication rechecks the owner; auth failure compares the account only
- **Rule:** A generation captures account id and credential revision and
  rechecks both before publishing; a change makes it `superseded` without
  touching the newer owner's state. The `auth_required` branch compares the
  account id only, then clears the snapshot.
- **Why:** Handling a 401 advances the credential revision, so comparing
  revisions there classified every real auth failure as `superseded` and
  left stale artwork on the home screen.
- **Check:** `test/widget_feed_loader_test.dart` "account switch during generation cannot publish the old account" "auth failure clears render state (no stale artwork)"
- **Code:** `lib/core/widget/widget_feed_loader.dart`

### WIDGET-04 Transient failures keep the last good snapshot
- **Rule:** `no_account` and same-account `auth_required` clear the
  snapshot; network, parse, image and storage failures keep the
  same-account last good snapshot and retry through bounded WorkManager
  work. No failure becomes an empty success.
- **Why:** One failed cover blanked the widget.
- **Check:** `test/widget_feed_loader_test.dart` "transient network failure keeps same-account last-good" "single cover failure keeps last-good and reports transient"
- **Code:** `lib/core/widget/widget_feed_loader.dart`

### WIDGET-05 Work is unique, bounded and only for live widgets
- **Rule:** Periodic work uses one unique name per widget family and account
  revision with `KEEP`; refresh clicks are one-shot `KEEP`. Removing the
  last widget cancels its work. The coordinator starts nothing (no account
  subscription, load or schedule) unless `hasAnyWidget`, and rechecks on
  resume.
- **Why:** Resize storms cancelled in-flight generations; users without a
  widget paid for background loads.
- **Check:** `test/widget_coordinator_test.dart` "closed widget gate starts nothing and issues no loads or native requests", `android/app/src/test/kotlin/io/github/lopution/parfait/appwidget/WidgetWorkContractTest.kt` "periodic and one-shot names carry family and account revision"
- **Code:** `lib/core/widget/widget_coordinator.dart`, `android/app/src/main/kotlin/io/github/lopution/parfait/appwidget`

### WIDGET-06 Widget clicks open only exact work links
- **Rule:** Pending intents are explicit, immutable, non-exported and
  unique per slot; the accepted link is exactly
  `parfait://illusts/<positive-id>`.
- **Why:** Exported or mutable intents let other apps inject routes.
- **Check:** `test/intent_router_test.dart` "parfait scheme typed routes"
- **Code:** `android/app/src/main/kotlin/io/github/lopution/parfait/appwidget`
