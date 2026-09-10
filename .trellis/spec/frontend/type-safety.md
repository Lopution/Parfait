# Type Safety

> Sound Dart conventions at API, persistence, and widget boundaries.

## Overview

The app uses Dart sound null safety. Wire data is `Map<String, Object?>` after
it crosses the JSON boundary; domain models, enums, sealed states, and typed
Riverpod providers carry it from there. Parsing belongs to the owning core
repository/model, not to a feature widget.

## Type Organization

- Entity and request types live in their `lib/core/<domain>/` owner.
- Shared JSON reads live in `lib/core/entity/json_read.dart`. Its `read*`
  functions are used for optional feed fields and its `require*` functions
  express required wire fields with `FormatException`.
- Async controllers expose `AsyncValue<T>` or a sealed `T` state. A feed uses
  `PagedFeedState` and ordered typed IDs rather than an untyped page map.
- UI constructors use domain types, enums, `Widget`/typed callbacks, and
  immutable fields. A UI option bag of `dynamic` values is not a project
  contract.

## JSON and Validation

`jsonDecode` is normalized at the repository boundary. Consumers use typed
accessors such as `readOptionalString`, `readNextUrl`, `requireString`,
`requirePositiveInt`, and `readMap`; they do not repeat casts for the same
payload fields. Required fields produce a parse error, while an optional field
that is absent is represented by `null` or its documented default.

Cursor, URI, ID, and enum validation stays with the repository or model that
owns that wire contract. A parser returns a typed entity or an observable
`ApiParseError`; it does not make malformed input look like an empty success.

## Strict Analyzer Patterns

With strict casts, raw types, and inference enabled, write collection types at
boundaries and type intermediate values before passing them to a model:

```dart
final values = <String, Object?>{};
final items = <IllustEntity>[];
final count = (row['count'] as num).toInt();
```

Use `Future<void>` and an explicit `await` for owned asynchronous work. Use
`unawaited` only when the caller intentionally starts an independent operation
whose owner handles its errors.

## Nullable Values and `!`

Prefer an early return, a local promotion, or an explicit state branch. `!` is
appropriate after the code has established the value, such as reading an
entity immediately after the same store merge or using a required widget
constructor field. It is not a substitute for parsing or account ownership
checks.

## Common Mistakes

- Passing `Map<String, dynamic>` through multiple layers and parsing the same
  fields again in each consumer.
- Using a raw `List`/`Map`, `Object` option bag, or `dynamic` callback in a
  public widget/provider contract.
- Casting an optional API field as non-null without the repository contract
  proving it is required.
- Hiding a parse failure behind a default entity or empty list.
