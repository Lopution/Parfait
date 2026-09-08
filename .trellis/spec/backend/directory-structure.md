# Directory Structure

> How backend code is organized in this project.

---

## Overview

<!--
Document your project's backend directory structure here.

Questions to answer:
- How are modules/packages organized?
- Where does business logic live?
- Where are API endpoints defined?
- How are utilities and helpers organized?
-->

(To be filled by the team)

---

## Directory Layout

```
<!-- Replace with your actual structure -->
src/
├── ...
└── ...
```

---

## Module Organization

<!-- How should new features/modules be organized? -->

(To be filled by the team)

---

## Naming Conventions

<!-- File and folder naming rules -->

(To be filled by the team)

---

## Examples

<!-- Link to well-organized modules as examples -->

(To be filled by the team)

## HTTP client ownership (C5e)

Production code never constructs `http.Client()` or `HttpClient()` inline.
Both are owned by Riverpod providers in `lib/core/network/http_client_providers.dart`:

- `thirdPartyHttpClientProvider` — all third-party `package:http` traffic
  (comment translation, SauceNAO reverse image search, update APK download).
- `resolverHttpClientProvider` — `dart:io` client for resolver/probe-grade
  traffic (update manifest fetch). Use this only where `connectionFactory`
  steering matters; prefer the third-party provider otherwise.

Store classes may keep an optional client *parameter* as a test seam, but the
production wiring must pass the provider-managed instance. The Pixiv API
stack (`pixiv_http_client`, `oauth_service`) and the policy-steered route
clients (`secure_resolver` `_staticMappedClient`, probe fallbacks) are owned
by the native-rust hygiene track (task 09-07 native-rust-hygiene, D) and are
explicitly out of scope here.
