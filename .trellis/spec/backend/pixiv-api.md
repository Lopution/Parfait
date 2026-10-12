---
prefix: API
applies_to:
  - lib/core/search/**
  - lib/core/illust/**
  - lib/core/entity/**
  - lib/core/series/**
reviewed: 2026-10-12
---

# Pixiv API behaviour the code depends on

### API-01 Free accounts get popular results from the preview endpoint
- **Rule:** The App API silently ignores `sort=popular_desc` for free
  accounts, so a non-premium popular search goes to
  `/v1/search/popular-preview/*`, which rejects a `sort` parameter.
  `Account.isPremium` comes from the OAuth `user.is_premium` field.
- **Why:** Free users saw date-sorted results labelled popular.
- **Check:** `test/search_models_test.dart` "preview query drops the sort the preview endpoint rejects"
- **Code:** `lib/core/search/search_repository.dart`, `lib/core/search/search_models.dart`

### API-02 Search durations and bounds are resolved on the client
- **Rule:** Duration presets resolve to `start_date`/`end_date`; never send
  `within_last_*`. A reversed min/max pair is rejected (`toQuery` throws)
  instead of swapped; stored filters decode negatives away and put
  reversed pairs in order.
- **Why:** The server ignored `within_last_*`; a wire-only swap made the
  client-side predicate filter every result out.
- **Check:** `test/search_models_test.dart` "duration presets resolve into absolute start/end dates" "a reversed bound pair is rejected on the wire" "stored bounds decode in order and without negatives"
- **Code:** `lib/core/search/search_models.dart`

### API-03 Page sizes come from the web pages endpoint
- **Rule:** `meta_pages` carries no per-page size. Multi-page works fetch
  `/ajax/illust/{id}/pages` (`pixivWeb` purpose, cookie optional) after the
  detail is Ready, without awaiting it; a failure leaves the work-level
  ratio. Single-page works never call it.
- **Why:** The work-level ratio letterboxed pages of other shapes.
- **Check:** `test/illust_detail_controller_test.dart` "single-page detail never hits the pages endpoint" "web pages failure keeps the detail ready with fallback ratios"
- **Code:** `lib/core/illust/illust_detail_repository.dart`, `lib/core/illust/illust_detail_controller.dart`

### API-04 The comment count is unknown in list payloads
- **Rule:** Only the detail API and the comments response carry the
  comment count. An unknown count is null, never 0, and a payload without
  it keeps a known one.
- **Why:** Feed payloads reset counts to 0.
- **Check:** `test/illust_store_test.dart` "a feed payload without a comment count keeps the known one"
- **Code:** `lib/core/entity/illust_store.dart`

### API-05 Only illust series can be listed per user
- **Rule:** A user's series list is `/v1/user/illust-series`; no endpoint
  lists a user's novel series, so the profile series tab counts illust
  series only.
- **Why:** A novel series count promised a list that cannot be loaded.
- **Check:** `test/series_repository_test.dart` "validateUserSeriesCursor pins path and user id"
- **Code:** `lib/core/series`
