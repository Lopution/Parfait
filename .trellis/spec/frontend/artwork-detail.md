---
prefix: DETAIL
applies_to:
  - lib/features/illust/**
  - lib/app/layout/app_breakpoints.dart
  - lib/app/layout/window_layout_spec.dart
  - lib/app/layout/two_pane.dart
reviewed: 2026-11-15
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

### DETAIL-02 A short first image sits low in its slot, the Hero inside it
- **Rule:** On compact widths (under 600dp) a short first illustration
  (single, or first of a set; not manga, ugoira, a panorama or two-pane)
  shown alone sits where centering it in 0.7 × viewport height would put
  it. Its slot is the band above it plus its ratio box; nothing below, so
  the expand button and the title follow right under the image. An
  expanded set drops the band. The Hero, placeholder and error states
  stay inside the ratio box, not the slot. Page 1 always goes through the
  slot box so expanding a set never remounts it. Outside selection the
  band carries the work's ambient light (THEME-19), rising from the image
  once it has landed. In selection, every
  page's badge keeps one inset from its image's top-end corner, moved
  down only by the part of the image the toolbar covers.
- **Why:** A wide image at the very top was hard to see and to tap; the
  matching band below it only pushed the title down. The flight landed on
  empty slot space, and the blank band was a third of the first screen;
  remounting page 1 lost its decode. On a portrait
  tablet the slot only opened a gap. A badge moved down a toolbar's
  height on an image the bar did not reach sat mid-image (user report,
  10-24).
- **Check:** `test/illust_detail_page_test.dart` "a short first image sits a band low; Hero and badge keep to it" "gives the first image of a set the same slot" "the band lights up from the image once it has landed"
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
- **Code:** `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/illust/detail/illust_detail_content.dart`

### DETAIL-05 Viewer jumps wait for the sheet to close
- **Rule:** The viewer's page-jump sheet pops with the page, the viewer
  awaits the sheet route's `completed`, then calls `jumpToPage`.
- **Why:** Jumping while the modal still blocked semantics tripped the
  semantics flush assertion (`node.built`).
- **Check:** `test/illust_detail_viewer_test.dart`
- **Code:** `lib/features/illust/viewer/image_viewer_page.dart`, `lib/features/illust/viewer/image_viewer_chrome.dart`

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

### DETAIL-15 Marks and stats under the title, the facts last; sections share one header
- **Rule:** In this order: the title; one line, wrapping as whole items,
  of the marks (AI-generated, R-18, R-18G; only those the work has) on
  tonal accent labels and the stats (views, bookmarks, the full posting
  time), read as one node, the stats as one sentence; the author on a
  `PersonCard` (PAGE-07), name over @account, with the follow button;
  the caption; the tags; then, as the block's last line, the facts
  (size, the page count for two or more pages, the tools when pixiv
  lists any, and "# n" with a copy glyph). Each fact sits behind its
  glyph in a box 4dp past its text sideways and 8dp up and down, the
  facts wrap whole, and every wrapped line starts its first glyph on the
  16dp margin. A tap on the ID copies the bare number and confirms with
  a snack bar; its target is its box. Every titled part of the page,
  inside the info block or below it, starts with `DetailSectionHeader`:
  a 48dp row whose action's label or glyph ends on the 16dp margin
  (LAYOUT-15). The info block has no bottom padding; the next header
  spaces itself. A series card shows "part n of m" once the series' work
  count is known.
- **Why:** User decisions. Headings with and without a button sat at two
  distances from their content. 10-21: the stats and author cards
  (`surfaceContainerLow`) were barely apart from the page ground
  (contrast 1.03 in light mode), so the block went compact, with glyph
  rows. 10-25: with every part shown the block read cluttered: the facts
  split the title from the author, and the plain author row did not show
  it opened the profile. The facts moved after the tags, the marks joined
  the stats, and the author took a card one tier up (`surfaceContainer`,
  1.08 light, 1.18 dark).
- **Check:** `test/illust_detail_page_test.dart` "marks and tools show only when set; the ID copies; headings align"
- **Code:** `lib/features/illust/detail/widgets/info_block.dart`, `lib/features/illust/detail/widgets/detail_section_header.dart`

### DETAIL-16 The info block's parts build as they near
- **Rule:** `InfoBlock` is a `SliverList.list` of parts (title, marks
  and stats, author, caption, tags, facts) that stay built once built; the
  artwork-info jump scrolls to its first part. A part that reads a store
  watches it itself.
- **Why:** As one box it was built with the page, below the fold of a
  long work too, in the push frame.
- **Check:** `test/illust_detail_actions_test.dart` "a long six-page work still reaches InfoBlock via the menu"
- **Code:** `lib/features/illust/detail/widgets/info_block.dart`, `lib/features/illust/detail/illust_detail_page.dart`

### DETAIL-17 The comment section writes in place
- **Rule:** The section opens with an entry pill (the signed-in user's
  avatar and a hint, 48dp or taller, a stamp key at its end), then up to
  three comment rows without a card, each opening the comments page.
  "See all" shows only over comments counted or on hand. A work known to
  take comments shows the pill while loading, an unknown one holds its
  place; with no comments the pill asks for the first; a failure is one
  line with retry; comments off is a lock line and no pill (API-04). The
  pill raises the composer over the page's bottom in place of the action
  bar, on the keyboard or, from the stamp key, the stamp panel; signed
  out it opens the sign-in. The composer lives on that surface
  (`CommentComposer.onGone`): it stands on the keyboard or panel as it
  rises and falls, shows over the upper half of its travel above the
  navigation bar, and the page drops it once the surface is down (a
  keyboard that never insets: it rests above the navigation bar after
  600ms). A keyboard is down once its inset is no more than the
  navigation bar's: some input methods leave the bar in the inset with
  nothing focused.
  The composer sets itself off the page with the bar shadow
  (`FuncSemanticTokens.barShadow`, as NAV-07), inside its own fade. The
  page stays live around it: a touch outside (`TapRegion`) sends it
  down and goes on to scroll, page or open what it landed on; back, a
  send, the page swiped away or the keyboard put away on its own send it
  down too, and unsent text stays as the work's draft. A sent comment
  heads the preview, and the count grows by one.
- **Why:** User decision (10-21): an "add comment" text button misaligned
  under the heading, and writing meant leaving the work for the comments
  page. A see-through barrier that swallowed every touch was tried and
  rejected: the page looked live but took nothing. A composer apart from
  its keyboard was rejected too (10-22): it stood alone while the input
  method woke, vanished at once on a touch outside and left the keyboard
  to fall alone, and stayed behind when only the keyboard was put away.
  User report (10-25): where the input method left the bar in the inset,
  the composer never went, back was blocked, and its top line, drawn
  outside the fade, stayed on screen; a shadow replaced the line (user
  decision).
- **Check:** `test/illust_detail_actions_test.dart` "the entry composes in place; a sent comment heads the preview"; `test/comments_replies_test.dart` "a composer on its surface goes with a keyboard down to the bar"
- **Code:** `lib/features/illust/detail/comments_preview_section.dart`, `lib/features/illust/detail/widgets/detail_comment_layer.dart`, `lib/app/widgets/comment_composer.dart`

## Chrome

### DETAIL-09 The action bar is the end-aligned capsule or pinned inspector bar
- **Rule:** On narrow single-column layouts, download and bookmark sit in one
  floating capsule (`DetailActionBar`) aligned to `AlignmentDirectional.bottomEnd`
  (`FuncSpacing.lg` margin, trailing scroll clearance increased by
  `FuncSpacing.md`), the heart on a tonal circle: 56dp high, an opaque surface
  with an outline on a layer lift (THEME-20). Comments are written from the
  page's comment section (DETAIL-17). The top bar carries only the ⋮ menu;
  share, editing the bookmark, watch later, page selection, work info and the
  two mutes are ⋮ entries with text labels; no action depends only on a long
  press (FB-03). In two-pane mode (`DETAIL-14`), `DetailActionBar` is omitted
  and the secondary inspector pins `DetailActionBar`'s bookmark and download
  controls together with inline Share and one deduplicated ⋮ menu (omitting
  Share and work info, keeping at most one ⋮ button globally).
- **Why:** User decision (11-03): an opaque capsule prevents smudged scroll
  text and backdrop passes. Bottom-end alignment keeps center-bottom artwork
  unobstructed in portrait feeds, while pinning inline actions in the two-pane
  inspector removes duplicate top-bar and floating chrome over wide stages.
- **Check:** `test/illust_detail_actions_test.dart` "the ⋮ menu carries the long-press actions too"
- **Code:** `lib/features/illust/detail/widgets/detail_action_bar.dart`, `lib/features/illust/detail/illust_detail_content.dart`, `lib/features/illust/detail/illust_detail_page.dart`

### DETAIL-14 Landscape detail is a stage, bounded overlay, and pinned inspector
- **Rule:** When `AppBreakpoints.useTwoPaneDetailOf` sees the page area
  (the window less the shell rail, `HomeShellChrome.contentSizeOf`) at
  least 480dp (`AppBreakpoints.compactHeight`) tall and either in a
  foldable posture (`FoldPosture.book` or `FoldPosture.tabletop`) or at
  least 600dp (`AppBreakpoints.medium`) wide with `height / width < 1.2`
  (tall portrait windows keep the single-column article layout per
  DETAIL-18), the detail page renders `AdaptiveTwoPane`: the primary pane holds
  only the image pager over `AmbientWash` (or `surfaceContainerLow` while
  selecting pages), and the secondary inspector pane pins `DetailAuthorCard`
  and the inline inspector action bar above a divider and the scrollable
  metadata/comments column at 0.38 of the width kept within 340–460dp (and
  pointer-resizable with persisted fraction under a stable `Stack` root so
  pointer/touch switches never rebuild panes). Across `FoldPosture.book`, panes
  align strictly to the vertical hinge edges minus ambient rail offset
  (`localToGlobal`); across `FoldPosture.tabletop`, panes split vertically
  around the horizontal hinge with the artwork above and the pinned inspector
  and actions below. When `AppBreakpoints.useBoundedDetailOverlayOf` holds on
  large flat screens (`>= 960×600` in `FoldPosture.flat`), pushed detail routes
  open via `FuncPage(boundedOverlayOnWide: true)` (non-opaque while bounded so
  the feed stays onstage, remaining opaque when full-screen) and
  `DetailOverlayFrame` over a scrim (`detail-overlay-scrim`), preserving the
  feed scroll position underneath and dismissing on scrim click, back or Esc.
  A resize across the two-pane line fades the page in over
  `MotionTokens.branchSwitch` rather than swapping it in one frame; only one
  layout is ever in the tree, since both show the same work and one route
  cannot hold the same hero tag twice. The image pager takes a sideways swipe at
  twice the device's touch slop (`pagingGestureSettings`); at its first or last
  image it hands the swipe on to the work pager around it through
  `SwipePagerScope`, and a swipe between images only turns the image. A work not
  built yet draws the image the grid already decoded on the stage, fitted as
  the pager fits a page, with the info column on the page's ground (C10).
- **Why:** On a turned phone the single column showed half an image;
  hinge-unaware widths overlapped foldable creases; pointer desktops need
  adjustable column splits while keeping touch tablets hinge-safe. Keeping the
  feed mounted behind a bounded wide overlay preserves feed context on tablets
  and desktops without edge-to-edge full-screen disorientation, while pinning
  actions inside the inspector pane avoids floating capsules overlapping art or
  the tabletop hinge.
- **Check:** `test/layout_breakpoints_test.dart` "two-pane detail needs a landscape area at least medium wide" "the secondary column stays between its bounds" "renders primary and secondary side by side" "AdaptiveTwoPane avoids vertical book hinge including rail" "AdaptiveTwoPane splits vertically on tabletop hinge" "AdaptiveTwoPane pointer handle resizes and saves ratio"; `test/illust_detail_actions_test.dart` "splits into image pager and meta column" "a layout switch fades the page in rather than swapping it"; `test/illust_detail_pager_test.dart` "an image pager at its last page hands the swipe to the work pager" "an image pager at its first image hands a backward swipe to the work pager, then follows the finger" "a two-pane stand-in paints the grid image on the stage"
- **Code:** `lib/app/layout/app_breakpoints.dart`, `lib/app/layout/two_pane.dart`, `lib/app/layout/window_layout_spec.dart`, `lib/app/navigation/func_page.dart`, `lib/features/illust/detail/widgets/detail_overlay_frame.dart`, `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/illust/detail/illust_detail_content.dart`, `lib/features/illust/detail/widgets/detail_image_pager.dart`, `lib/features/illust/detail/illust_detail_pager_page.dart`

### DETAIL-18 Single-column detail text keeps the article width
- **Rule:** In the single-column layout, when the page's content area is
  wider than `ContentWidths.article` (700dp), the info block and the
  comments preview sit in a centred 700dp column (their own page margin
  inside it) so a line holds roughly 40–60 characters; the artwork pages
  and the related-works grid stay at the page's full width. Narrower
  pages are unchanged.
- **Why:** On a large portrait window the caption and comments ran the
  window's ~900dp width in one line each, hard to read and unlike the
  feed's text columns.
- **Check:** `test/illust_detail_page_test.dart` "text keeps the article column on a large portrait"
- **Code:** `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/illust/detail/illust_detail_content.dart`, `lib/app/layout/sliver_width_builder.dart`

### DETAIL-10 The download button listens to the manager itself
- **Rule:** The detail download button subscribes to
  `DownloadManager.changes` (progress included) and shows the whole work's
  state: ring, saved check, or failure. The detail page and the viewer
  refresh their page badges on `events` of their own work only.
- **Why:** `events` carries terminal events only; rebuilding the page per
  progress tick was costly. A batch of another work rebuilt every open
  detail page once per saved page.
- **Check:** `test/illust_detail_download_test.dart`
- **Code:** `lib/features/illust/detail/widgets/detail_action_bar.dart`, `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/illust/viewer/image_viewer_page.dart`

### DETAIL-11 One page counter that never hard-cuts
- **Rule:** Page numbers on the detail page come only from
  `DetailPageCounter`: hidden for single-page and ugoira works and during
  selection, shown after the entry transition, `IgnorePointer`, fading in
  and out. A page whose only visible strip is behind the status bar and
  toolbar counts as off screen. Its collapse pill fades out while the
  collapse button at the end of the set is half on screen, so one
  collapse shows at a time; that position is read from the button's
  render box after layout, since a sliver child scrolled off but still in
  the cache extent stops painting and never reports hidden.
- **Why:** Several counters disagreed; the counter hung over the info
  block. Two collapse controls at once read as two different actions.
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
