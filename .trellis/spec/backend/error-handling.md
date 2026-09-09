# Error Handling

> Error classification and propagation across the core and feature layers.

## Overview

The code keeps transport errors, parser errors, and domain/platform errors
distinct. A repository reports a typed failure at the boundary where it knows
the cause; a controller preserves that failure in its typed state; a feature
maps it to the existing feed, settings, dialog, or SnackBar presentation. No
new universal exception base class is needed.

## Error Types

`lib/core/network/api_error.dart` owns the sealed API family:

| Type | Meaning |
|---|---|
| `ApiNetworkError` | DNS, socket, or TLS transport failure |
| `ApiTimeout` | configured request timeout |
| `ApiCancelled` | caller cancellation |
| `ApiHttpError` | non-2xx response outside auth/rate-limit classes |
| `ApiUnauthorized` | auth failure after the refresh protocol or invalid refresh |
| `ApiRateLimited` | rate limit with optional `retryAfter` |
| `ApiParseError` | response does not match the expected schema |

Domain boundaries retain their own types where the operation needs them:
`CredentialStoreException`, `SettingsRepositoryException`,
`SettingsWriteException`, `HistorySyncException`, download exceptions,
`UpdatePlatformException`, and platform/channel exceptions. Cursor and payload
parsing errors remain observable `ApiParseError` values rather than becoming an
empty successful result.

## Propagation Patterns

- Repositories classify HTTP status, response shape, and transport failures;
  they do not show UI or catch an error merely to return an empty value.
- `PixivHttpClient` maps auth and rate-limit responses to `ApiUnauthorized` or
  `ApiRateLimited`, and keeps a bounded `ApiHttpError.detail` for diagnosis.
  Its auth refresh/replay rules are part of the network contract, not a page
  concern.
- Riverpod controllers expose `AsyncValue` or a sealed domain state. An
  `AsyncValue.guard` call is used for an explicit reload boundary; a known
  failure may instead become a typed state such as `IllustDetailError`.
- Feed pages use `FeedError` for an initial failure and `FeedTail` for a
  load-more failure. Both keep retry as an explicit action. Settings reads use
  `SettingsLoadError`; settings writes leave the previous value visible and
  report `SettingsWriteException`.
- Cancellation, disposal, and stale generation results are not published as
  new business data. The owning controller/store decides whether the result is
  stale before committing it.

## API and Platform Responses

Pixiv API repositories consume the response body as a typed JSON map and
return domain entities or `ApiError`; there is no common backend response
envelope to invent. `ApiHttpError.statusCode` carries the HTTP status and its
optional detail is bounded. `next_url` and entity fields are checked by their
own repository parser.

Android channels retain their established per-channel result codes. Channel
argument failures and method errors follow
[`android-channels.md`](./android-channels.md); updater methods keep their
`success({valid: false, errorCode})` / failed-map contract instead of being
converted to a generic `result.error` shape.

## Logging and UI Mapping

`log()` records diagnostic metadata only and is compiled out of release builds.
Error text shown by a feature comes from generated localization or an explicit
operation message. Shared SnackBars are emitted through
`showAppSnackBar`; feature pages do not log or present a second copy of the
same error classification.

## Common Mistakes

- Converting a parse or storage failure into an empty feed.
- Retrying a request after an HTTP response or a body may already have been
  delivered.
- Replacing a visible confirmed value with an optimistic mutation value when
  the operation has not succeeded.
- Catching an error only to discard its type, or exposing credentials and
  request bodies in an error string.
