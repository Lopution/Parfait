---
prefix: REV
applies_to:
  - lib/core/reverse_image/**
  - lib/features/search/reverse_image*.dart
reviewed: 2026-10-12
---

# Reverse image search

### REV-01 One controller owns the input from pick to cleanup
- **Rule:** The in-app picker and Android `ACTION_SEND` share one
  controller. The platform passes only opaque `content://` metadata; the
  controller checks MIME against the file signature, dimensions and pixel
  budget before any full decode, and owns exactly one temporary file,
  cleaned on every terminal path. Errors carry no paths.
- **Why:** A pixel bomb or mislabeled file could exhaust memory; leaked
  temp files piled up.
- **Check:** `test/reverse_image_search_test.dart` "rejects a pixel bomb before any full image decode" "rejects a MIME declaration that does not match the file bytes" "picker and SEND references share preparation and terminal cleanup"
- **Code:** `lib/core/reverse_image`

### REV-02 Large images are scaled, not refused
- **Rule:** Within the hard limits (32 MiB, 12288 px, 64 Mpx), an image
  over 2048 px on its long edge or 8 MiB is scaled to a 2048 px JPEG
  before preview.
- **Why:** Phone photos exceeded engine upload limits and were refused.
- **Check:** `test/reverse_image_search_test.dart` "a large image is scaled to a 2048 long edge JPEG, not refused"
- **Code:** `lib/core/reverse_image`

### REV-03 The image outlives each search
- **Rule:** The held image survives success, no match and failure, so
  another engine can run; only a new pick, cancel or leaving the page
  releases it. "Try another" skips failed, empty and unfit engines.
- **Why:** Users had to pick the image again for each engine.
- **Check:** `test/reverse_image_search_test.dart` "a failed engine keeps the input and switches to another" "the next engine skips failed, empty and unfit engines"
- **Code:** `lib/core/reverse_image`

### REV-04 Providers never fake results
- **Rule:** A provider declares a typed capability and returns typed
  outcomes. It never turns HTML or a challenge into result cards and never
  returns an empty success without evidence; results show in the engine's
  own page, and a challenge falls back to its upload form in the
  controlled WebView (HTTPS only). An unavailable provider is a visible
  terminal failure.
- **Why:** Scraped result pages broke silently and read as "no match".
- **Check:** `test/reverse_image_search_test.dart` "unavailable provider is an explicit terminal failure" "a challenge falls back to the engine upload form in the browser"
- **Code:** `lib/core/reverse_image`
