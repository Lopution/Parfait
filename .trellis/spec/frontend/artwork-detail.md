---
prefix: DETAIL
applies_to:
  - lib/features/illust/**
reviewed: 2026-10-12
---

# Artwork detail page and viewer

## Contents

- [Images](#images)
- [Sections below the work](#sections-below-the-work)
- [Chrome](#chrome)

## Images

### DETAIL-01 Size each page by its decoded ratio
- **Rule:** Multi-page works size each page by its decoded frame, never by
  a fixed `AspectRatio` on the container. The estimated box only holds the
  slot until the decode lands.
- **Why:** The App API's `meta_pages` carries no per-page size, so the
  work-level ratio letterboxed every page of another shape.
- **Check:** manual
- **Code:** `lib/features/illust/detail/widgets/page_image.dart`

### DETAIL-02 A short first image sits in a fixed slot, the Hero inside it
- **Rule:** On narrow layouts a short first illustration (single, or first
  of a set; not manga, ugoira or two-pane) is centered at its own ratio in
  a slot of 0.7 × viewport height. The Hero, placeholder and error states
  stay inside the ratio box, not the slot. Page 1 always goes through the
  slot box so expanding a set never remounts it.
- **Why:** The flight landed on empty slot space; remounting page 1 lost
  its decode.
- **Check:** `test/illust_detail_page_test.dart` "gives the first image of a set the same slot"
- **Code:** `lib/features/illust/detail/widgets/page_image.dart`

### DETAIL-03 A panorama scrolls before the pager takes over
- **Rule:** A page whose natural height is under 60% of 280dp shows in a
  280dp viewport that scrolls sideways, opens centered, and claims only
  swipes it can still follow; at its edge the detail pager wins.
- **Why:** Ultra-wide works were unreadable thumbnails; a greedy recognizer
  trapped the pager.
- **Check:** `test/illust_detail_pager_test.dart` "a panorama scrolls first and hands the swipe on at its edge"
- **Code:** `lib/features/illust/detail/widgets/page_image.dart`

### DETAIL-04 An illustration set opens folded, without AnimatedSize
- **Rule:** On narrow layouts an illustration with several pages shows
  page 1 and an expand button; manga shows every page. The new pages
  appear without wrapping the lazy sliver in `AnimatedSize`. Page
  selection expands the set first. Folding from deep in the set lands at
  the end of page 1.
- **Why:** `AnimatedSize` around the page sliver built every full-size page
  at once.
- **Check:** `test/illust_detail_page_test.dart` "an illustration set opens on its first image"
- **Code:** `lib/features/illust/detail/illust_detail_page.dart`

### DETAIL-05 Viewer jumps wait for the sheet to close
- **Rule:** The viewer's page-jump sheet pops with the page, the viewer
  awaits the sheet route's `completed`, then calls `jumpToPage`.
- **Why:** Jumping while the modal still blocked semantics tripped the
  semantics flush assertion (`node.built`).
- **Check:** `test/illust_detail_viewer_test.dart`
- **Code:** `lib/features/illust/viewer/image_viewer_page.dart`

## Sections below the work

### DETAIL-06 Below-the-fold sections load on demand
- **Rule:** Related works, the comment preview and the author's other works
  go through `OnDemandSliver`: nothing is requested until the section is
  on screen and its pager page has been current for 300 ms. Until then it
  holds a static placeholder, never a spinner. A paging check may call
  `loadMore` only on a provider that already exists and has loaded.
- **Why:** The pager prebuilds neighbours; swiping through works fired
  requests for each. An off-screen spinner kept producing frames.
- **Check:** `test/illust_detail_pager_test.dart` "only the current page requests its related works" "a neighbour requests once it has stayed settled"
- **Code:** `lib/features/illust/detail/on_demand_sliver.dart`, `lib/features/illust/detail/detail_page_activity.dart`

### DETAIL-07 Sections replace their states without fades
- **Rule:** A section's placeholder, skeleton, states and content replace
  each other in place, without `StateFade`.
- **Why:** A section fading around images that fade on their own stacked
  two fades.
- **Check:** manual
- **Code:** `lib/features/illust/detail/related_illusts_section.dart`

### DETAIL-08 First-page failures retry by themselves
- **Rule:** The sections wrap their body in `AutoRetry`: a network,
  timeout, rate-limit or 5xx failure of the first page retries twice
  (1.5 s, then 3 s, at least the server's Retry-After) before the error
  row waits for the user.
- **Why:** Transient failures on the detail page left dead sections.
- **Check:** manual
- **Code:** `lib/features/illust/detail/on_demand_sliver.dart`

## Chrome

### DETAIL-09 The action bar is the centered capsule
- **Rule:** On narrow layouts download, comments and bookmark sit in one
  floating capsule (`DetailActionBar`), the heart on a tonal circle; the
  top bar carries only the ⋮ menu. Share, page selection and work info are
  ⋮ entries with text labels; no action depends only on a long press.
- **Why:** User decision. An M3 floating toolbar with a separate bookmark
  FAB was tried and rejected.
- **Check:** manual
- **Code:** `lib/features/illust/detail/widgets/detail_action_bar.dart`

### DETAIL-10 The download button listens to the manager itself
- **Rule:** The detail download button subscribes to
  `DownloadManager.changes` (progress included) and shows the whole work's
  state: ring, saved check, or failure.
- **Why:** `events` carries terminal events only; rebuilding the page per
  progress tick was costly.
- **Check:** `test/illust_detail_download_test.dart`
- **Code:** `lib/features/illust/detail/widgets/detail_action_bar.dart`

### DETAIL-11 One page counter that never hard-cuts
- **Rule:** Page numbers on the detail page come only from
  `DetailPageCounter`: hidden for single-page and ugoira works and during
  selection, shown after the entry transition, `IgnorePointer`, fading in
  and out. A page whose only visible strip is behind the status bar and
  toolbar counts as off screen.
- **Why:** Several counters disagreed; the counter hung over the info
  block.
- **Check:** `test/illust_detail_page_test.dart`
- **Code:** `lib/features/illust/detail/widgets/detail_page_counter.dart`

### DETAIL-12 The top bar draws in as page 1 leaves
- **Rule:** The body extends behind the top bar; page 1 starts below the
  status bar. The toolbar is transparent while page 1 is under it, then
  surface and title fade in over the last `kToolbarHeight`. The scroll edge
  line stays off until the bar is fully drawn. After a Hero push the bar
  and action bar start hidden and appear once the route animation
  completes; the route status is read after the first frame.
- **Why:** A translucent bar over the flight and two stacked edges looked
  broken; the proxy animation reports `completed` before the push starts.
- **Check:** `test/hero_transition_test.dart`
- **Code:** `lib/features/illust/detail/illust_detail_page.dart`, `lib/app/widgets/app_top_bar.dart`

### DETAIL-13 Prompt anchors notify after layout
- **Rule:** `PromptAnchors` notifications raised during build or layout are
  deferred to one post-frame notify.
- **Why:** An anchor under a `LayoutBuilder` mutated the prompt layout in
  the middle of `performLayout`.
- **Check:** manual
- **Code:** `lib/app/widgets/prompt_anchor.dart`
