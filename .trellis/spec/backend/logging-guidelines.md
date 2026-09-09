# Logging Guidelines

> Diagnostic logging for the Flutter application and its core services.

## Overview

`lib/core/log.dart` owns the application logging outlet through
`void log(String message)`. It calls Flutter's `debugPrint` in non-release
builds and returns immediately in release builds. Existing callers use this
single function from widget coordination, background work, network probes, and
feature-level diagnostics.

## Levels and Message Shape

The project does not maintain a second level-aware logging framework. A call
site chooses a short source prefix and appends the event or classified error:

```dart
log('WidgetBackground: outcome ${result.outcome.name}');
log('probe ${target.host} failed: $error');
```

Use the owning class or operation as the prefix, keep values useful for
diagnosis, and preserve the existing `log(String message)` signature. Do not
add a new logger or make feature code call `debugPrint` directly.

## What to Log

Log lifecycle boundaries and bounded metadata that explain a failed operation:
background/widget outcomes, route or probe kind, HTTP status, error type,
account-boundary transitions without the account secret, and size/budget
decisions. Classified errors may be logged when their `toString()` contract is
safe for diagnostics.

## What Not to Log

Never log access/refresh tokens, cookies, secure-storage payloads, translation
credentials, request bodies, response bodies, or full account-transfer
envelopes. Do not turn a URL with query credentials into a log line. Keep
diagnostics at the event/host/status level used by the existing callers.

## Common Mistakes

- Calling `print` or `debugPrint` from a new core service instead of using
  `log()`.
- Logging the complete exception payload when a type, status, or operation is
  enough.
- Treating a debug log as a user-visible error or as evidence that an
  operation succeeded.
