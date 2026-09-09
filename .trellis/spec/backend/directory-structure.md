# Directory Structure

> How the application's data, service, and platform code is organized.

## Overview

This repository is a Flutter application. Its backend-like code lives in
`lib/core/`, where entities, repositories, Riverpod controllers/stores, and
platform adapters are kept independent of feature widgets. The app shell is in
`lib/app/`; feature composition is in `lib/features/`. The import direction is
enforced by `test/architecture/layering_test.dart`:

```text
lib/app/       -> lib/core/ and lib/app/
lib/features/  -> lib/core/, lib/app/, and the routes facade
lib/core/      -> lib/core/ only
```

`lib/app/navigation/routes.dart` is the single approved cycle boundary: it
imports feature page entry points and feature code imports that typed facade
instead of another feature's page.

## Directory Layout

```text
lib/
├── app/                 shell, theme, motion, navigation, shared widgets
├── features/<feature>/  page and feature-only UI composition
└── core/<domain>/        entity, repository, controller, store, platform code

plugins/rhttp/rhttp/     vendored Rust-backed HTTP package
android/app/src/main/    Android channel and widget implementation
test/                    app tests and test/helpers fixtures
```

The direct `core` domains and their primary owner are:

| Domain | Primary owner | Responsibility |
|---|---|---|
| `auth` | `AccountStore`, `CredentialStore` | account identity, secure credentials, OAuth |
| `bookmark` | `BookmarkStore` | account-scoped bookmark mutation state |
| `comments` | `CommentStore` | comment/reply entities and actions |
| `download` | `DownloadManager` | typed download jobs, sinks, recovery |
| `entity` | `IllustStore` | canonical illustration entities and merge rules |
| `history` | `HistoryRepository` | local history database and Pixiv outbox |
| `i18n` | `ReplicaLanguage` | persisted language selection and lookup support |
| `illust` | feed/detail controllers and repositories | illustration API state |
| `mutation` | `MutationBoundary` | account-owned mutation identity and lifecycle |
| `navigation` | `RouteObserver` | route visibility observation |
| `network` | `PixivHttpClient`, policy providers | Pixiv transport, errors, and route policy |
| `new` | `NewFeedController` | New feed state and repository boundary |
| `novel` | `NovelStore` | canonical novel entities and reader data |
| `paging` | `PagedFeedController` | initial/refresh/load-more feed phases |
| `platform` | channel interfaces and adapters | Android/desktop platform boundaries |
| `profile` | profile controllers/repositories | account-owned profile editing and feeds |
| `reverse_image` | `ReverseImageSearchController` | input ownership and provider capability |
| `search` | search controllers/repositories | query, filter, and result state |
| `settings` | `SettingsRepository`, `SettingsController` | versioned preferences and consumers |
| `ugoira` | asset/export providers | animated-media decoding and export |
| `updater` | `UpdateService` | signed release metadata and APK update flow |
| `user` | `UserStore`, `FollowStore` | canonical user and relationship state |
| `widget` | `WidgetCoordinator` | Android home-widget snapshot lifecycle |

## Module Organization

- Put API models, parsing, repositories, stores, Notifiers, and platform
  interfaces in the owning `lib/core/<domain>/` directory. Keep a repository
  and its controller in separate files when both exist.
- Keep pages and page-only view-model composition in
  `lib/features/<feature>/`. A feature must not become the owner of a shared
  entity, HTTP client, preference key, or mutation state.
- Put cross-feature UI in `lib/app/widgets/` and app-wide route/motion/theme
  code in `lib/app/`. The shared widget consumes typed core state; it does not
  recreate a repository or store.
- Put Android channel implementation in the Android source sets and keep the
  Dart side under `lib/core/platform/` or its owning domain. Channel names and
  payloads are documented in
  [`android-channels.md`](./android-channels.md).
- Keep the Rust HTTP fork under `plugins/rhttp/rhttp/`; its FRB and Cargo
  rules are documented in [`rust-plugin.md`](./rust-plugin.md).

## HTTP Client Ownership

Production code obtains clients from providers in
`lib/core/network/http_client_providers.dart` or from the Pixiv policy stack.
There are three distinct ownership paths:

| Stack | Provider/owner | Consumers |
|---|---|---|
| Pixiv API and OAuth | `pixivHttpClientProvider` and `PixivNetworkFactory` | Pixiv API repositories, account/auth flows |
| ordinary third-party `package:http` | `thirdPartyHttpClientProvider` | translation, SauceNAO, updater APK download |
| resolver/probe `dart:io` | `resolverHttpClientProvider` | DoH, resolver, and probe-grade traffic |

Do not construct a production `http.Client` or `HttpClient` inline. The
resolver client is used where `connectionFactory` steering is part of the
contract; ordinary third-party traffic uses the shared package client.

## Naming and Upgrade Rules

- Files use the responsibility suffixes already present in the domain:
  `*_entity.dart`, `*_models.dart`, `*_repository.dart`, `*_controller.dart`,
  `*_store.dart`, and `*_platform.dart`.
- Public types in `core` are part of a typed contract. A private helper stays
  private to its library unless a test or cross-library owner requires it.
- Flutter stable upgrades follow the Android matrix validated by the pinned
  SDK. Changes to AGP, Kotlin, `compileSdk`, lockfiles, or the `material_ui`
  family are coupled changes and are recorded in the relevant task research.

## Examples and Enforcement

- `lib/core/history/` is the database boundary: callers use
  `HistoryRepository`, not raw SQLite operations.
- `lib/core/network/` owns error classification and the three client paths.
- `lib/core/user/` owns follow state while
  `lib/app/widgets/follow_switch_button.dart` owns only its presentation.
- `test/architecture/layering_test.dart` checks import direction, data-layer
  file placement, and feature-private shared-widget naming. CI runs it with
  the app test suite.
