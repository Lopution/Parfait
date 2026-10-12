---
reviewed: 2026-10-12
---

# Backend

Data, platform and build code: `lib/core`, `android/`, `plugins/rhttp`,
`.github/workflows`, `tool/`. Format and admission rules for every spec
file are in the [spec root](../index.md).

## Pre-Development Checklist

1. Run `python3 tool/check_spec.py --for <paths you will change>` and read
   the files it lists. Without paths yet, pick from the table below.
2. Read [guides](../guides/index.md).
3. Rules marked "User decision" are not yours to change; ask first.

## Files

| File | Read when |
|---|---|
| [stores.md](./stores.md) | Entity stores, bookmarks, follows, optimistic toggles, mutations, account boundaries. |
| [paging.md](./paging.md) | Feed controllers, cursors, load-more pacing, the commit gate, the data worker. |
| [history.md](./history.md) | Browsing history, its database and the Pixiv history outbox. |
| [images.md](./images.md) | Image loading, decoding, the image worker, caches, ugoira and GIF export. |
| [network.md](./network.md) | Pixiv transport, routes, ECH, auth refresh, rate limits, segmented downloads. |
| [downloads.md](./downloads.md) | The download manager, sinks, recovery and file naming. |
| [reverse-image.md](./reverse-image.md) | Reverse image search input and providers. |
| [profile-edit.md](./profile-edit.md) | Editing the Pixiv profile and the web session behind it. |
| [pixiv-api.md](./pixiv-api.md) | Pixiv endpoints whose behaviour is not what their shape suggests. |
| [errors.md](./errors.md) | Error types, user-facing failure copy, CrashLog, logging. |
| [settings-store.md](./settings-store.md) | Persisted settings, secrets, credentials, account transfer. |
| [android.md](./android.md) | Platform channels, intents, haptics, the login WebView. |
| [home-widget.md](./home-widget.md) | The Android home widget, its snapshot and background work. |
| [rust-plugin.md](./rust-plugin.md) | The rhttp fork, FRB versions, Cargo features. |
| [release.md](./release.md) | APK builds, signing, size gates, the updater, CI workflows, toolchain upgrades. |

## Quality Check

- `python3 tool/check_spec.py --diff` lists the spec files for your
  changes; confirm each rule there still holds.
- `dart format --output=none --set-exit-if-changed lib test` and
  `flutter analyze` are clean.
- Run the tests named in the **Check** fields of the rules you touched,
  plus `test/architecture/`.
- Kotlin changes: `./gradlew :app:testGithubDebugUnitTest
  :app:testFdroidDebugUnitTest` from `android/`.
- Rust or FRB changes: `cargo test --locked` and `tool/frb_check.sh`.
