---
prefix: DETAIL
applies_to:
  - lib/features/illust/**
  - lib/app/widgets/feed/desktop_inspector_scope.dart
  - lib/app/layout/app_breakpoints.dart
  - lib/app/layout/window_layout_spec.dart
  - lib/app/layout/two_pane.dart
reviewed: 2026-11-28
---

# Artwork detail page and viewer

## Contents

- [Images](#images)
- [Sections below the work](#sections-below-the-work)
- [Chrome](#chrome)

## Images

### DETAIL-01 Size each page by its decoded ratio
- **Rule:** Multi-page works size each page by its decoded frame, never by a fixed outer `AspectRatio` (including inside two-pane `DetailImagePager`); estimated boxes only hold the slot until decode.
- **Why:** App API `meta_pages` omits per-page dimensions, so work-level ratios letterboxed differing pages and squashed panoramas in two-pane view.
- **Check:** `test/illust_detail_page_test.dart` "two-pane panorama preserves 280dp height, tag block mode shows Done & intercepts back, single tag mute confirms silently on right-click, and TranslationPanel avoids nested SelectableText"
- **Code:** `lib/features/illust/detail/widgets/page_image.dart`, `lib/features/illust/detail/widgets/detail_image_pager.dart`

### DETAIL-03 A panorama scrolls before the pager takes over
- **Rule:** A page whose natural height is under 60% of 280dp renders in a 280dp (clamped to finite pane height) horizontally scrollable viewport opened centered without an outer `AspectRatio` squash, handing horizontal swipes to the detail pager only at its edges.
- **Why:** Ultra-wide works were unreadable thumbnails and outer `AspectRatio` squashed panoramas in two-pane stages.
- **Check:** `test/illust_detail_page_test.dart` "two-pane panorama preserves 280dp height, tag block mode shows Done & intercepts back, single tag mute confirms silently on right-click, and TranslationPanel avoids nested SelectableText"
- **Code:** `lib/features/illust/detail/widgets/page_image.dart`, `lib/features/illust/detail/widgets/detail_image_pager.dart`

### DETAIL-04 An illustration set opens folded, without AnimatedSize
- **Rule:** On narrow layouts multi-page illustrations open on page 1 plus an expand button (manga shows all pages) without wrapping the lazy sliver in `AnimatedSize`. Page selection expands first; folding from deep in the set lands at the end of page 1.
- **Why:** `AnimatedSize` forced eager build of every full-size page at once.
- **Check:** `test/illust_detail_page_test.dart` "an illustration set opens on its first image"
- **Code:** `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/illust/detail/illust_detail_shells.dart`, `lib/features/illust/detail/illust_detail_menu.dart`

### DETAIL-05 Viewer jumps wait for the sheet to close
- **Rule:** The viewer's page-jump sheet pops with the target page; the viewer awaits the sheet route's `completed` future before calling `jumpToPage`.
- **Why:** Jumping while the modal still blocked semantics triggered the `node.built` semantics assertion.
- **Check:** `test/illust_detail_viewer_test.dart` "scrubbing jumps to the target page without building crossed pages"
- **Code:** `lib/features/illust/viewer/image_viewer_page.dart`, `lib/features/illust/viewer/image_viewer_chrome.dart`

## Sections below the work

### DETAIL-06 Below-the-fold sections load on demand
- **Rule:** Related works, comment preview, and author's other works use `OnDemandSliver`: requests wait until on-screen and current in the pager for 300 ms, holding a static placeholder (never a spinner) beforehand. `IllustSeriesSection` gates recent-episode writes on `DetailPageActivity.of(context)` so prebuilt neighbours never overwrite "Continue episode N". Paging only calls `loadMore` on already-loaded providers.
- **Why:** Prebuilt pager neighbours fired premature requests, overwrote series reading state, and off-screen spinners ticked frames continuously.
- **Check:** `test/illust_detail_pager_test.dart` "only the current page requests its related works" "a neighbour requests once it has stayed settled"; `test/series_feed_test.dart` "inactive DetailPageActivity skips recording recent series open until active"
- **Code:** `lib/features/illust/detail/on_demand_sliver.dart`, `lib/features/illust/detail/detail_page_activity.dart`, `lib/features/illust/detail/widgets/illust_series_section.dart`

### DETAIL-08 First-page failures retry by themselves
- **Rule:** Sections wrap their body in `AutoRetry` so transient first-page failures retry twice (1.5 s, 3 s, respecting `Retry-After`) before showing an error row.
- **Why:** Transient network blips left dead sections.
- **Check:** manual
- **Code:** `lib/features/illust/detail/on_demand_sliver.dart`

### DETAIL-17 The comment section writes in place
- **Rule:** The section shows an entry pill (>= 48dp tall) above up to three borderless comment rows; comments-off shows a lock line with no pill (API-04). Tapping raises `CommentComposer` (`onGone`) while the page remains interactive (`TapRegion` dismisses while passing touches through; unsent drafts persist; sent comments prepend and increment count).
- **Why:** User decisions: compose in place without leaving the page or blocking touches behind an opaque barrier.
- **Check:** `test/illust_detail_actions_test.dart` "the entry composes in place; a sent comment heads the preview"
- **Code:** `lib/features/illust/detail/comments_preview_section.dart`, `lib/features/illust/detail/widgets/detail_comment_layer.dart`, `lib/app/widgets/comment_composer.dart`

## Chrome

### DETAIL-09 The action bar is a centered opaque capsule or pinned inspector bar
- **Rule:** Single-column pushed detail pages center a 56dp opaque `DetailActionBar` capsule for download and bookmark above the safe inset, with ⋮ in the top bar holding share, bookmark edit, watch later, page selection, info jump, and mutes (FB-03). Two-pane stage (`DETAIL-14`) and `embeddedInspector: true` (`DesktopGalleryInspector`) omit the outer `AppBar` and floating capsule, pinning the author summary directly above the inline action bar.
- **Why:** Mobile keeps thumb-reachable opaque actions without frosted smearing, while wide stages and inspectors avoid occluding artwork or duplicating chrome.
- **Check:** `test/illust_detail_actions_test.dart` "the ⋮ menu carries the long-press actions too" "bottom inset and margin both clear the gesture area"
- **Code:** `lib/features/illust/detail/widgets/detail_action_bar.dart`, `lib/features/illust/detail/illust_detail_menu.dart`, `lib/features/illust/detail/illust_detail_shells.dart`, `lib/features/illust/detail/illust_detail_page.dart`

### DETAIL-14 Landscape stage, bounded modal overlay, and universal desktop gallery inspector
- **Rule:** Desktop galleries expose `DesktopGalleryControls` density at `HomeShellChrome.contentSizeOf(context).width >= AppBreakpoints.medium` (600dp) and support `DesktopDetailMode.modal` and `inspector` (`>= 760dp` via `DesktopInspectableGallery`). Switching tabs/dates (`scopeKey`) or entering feed multi-select closes any open inspector automatically. Pushed detail routes enter `AdaptiveTwoPane` when `AppBreakpoints.useTwoPaneDetailOf` holds; wide flat screens (`>= 960x600`) float `DetailOverlayFrame` via `FuncPage(boundedOverlayOnWide: true)`, dimming `ShellRail` via `HomeShellModalScrim` (NAV-20). `IllustDetailPage` and `ImageViewerPage` support `B` (bookmark toggle) and `Ctrl/Cmd+S` (download/save active page).
- **Why:** Enables side-by-side browsing or focused modal stages with safe-area clearance, accurate rail-subtracted breakpoints, and desktop keyboard ergonomics.
- **Check:** `test/layout_breakpoints_test.dart` "two-pane detail needs a landscape area at least medium wide" "the secondary column stays between its bounds" "renders primary and secondary side by side" "AdaptiveTwoPane avoids vertical book hinge including rail" "AdaptiveTwoPane splits vertically on tabletop hinge" "AdaptiveTwoPane pointer handle resizes and saves ratio"; `test/illust_detail_actions_test.dart` "tabletop hinge splits artwork above inspector action bar" "IllustDetailTwoPaneShell applies SafeArea insets outside overlay and adapts for tabletop hinge" "bounded wide detail overlay keeps underlying feed alive and closes on scrim tap"; `test/illust_detail_viewer_test.dart` "Ctrl+S saves active page and B toggles bookmark"; `test/home_branch_stack_test.dart` "ShellRail dims behind bounded DetailOverlayFrame and dismisses on tap"; `test/feed_selection_test.dart` "touch tablet enters multi-select via card sheet, landscape phone bar clears bottom nav, and inspector respects content width & auto-closes"
- **Code:** `lib/app/layout/app_breakpoints.dart`, `lib/app/layout/two_pane.dart`, `lib/app/layout/window_layout_spec.dart`, `lib/app/navigation/func_page.dart`, `lib/app/widgets/feed/desktop_gallery_controls.dart`, `lib/app/widgets/feed/desktop_inspectable_gallery.dart`, `lib/app/widgets/feed/desktop_inspector_scope.dart`, `lib/features/illust/detail/widgets/desktop_gallery_inspector.dart`, `lib/features/illust/detail/widgets/detail_overlay_frame.dart`, `lib/features/illust/detail/widgets/detail_keyboard_shortcuts.dart`, `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/illust/detail/illust_detail_shells.dart`, `lib/features/illust/viewer/image_viewer_shortcuts.dart`, `lib/features/illust/viewer/image_viewer_page.dart`

### DETAIL-10 The download button listens to the manager itself
- **Rule:** `DetailDownloadButton` subscribes to `DownloadManager.changes` for live progress; detail and viewer pages refresh page badges only on terminal `events` matching their own work.
- **Why:** Rebuilding whole detail pages per progress tick or unrelated batch events wasted frames.
- **Check:** `test/illust_detail_download_test.dart` "download feedback opens tasks after the detail is disposed" "multi-page works expose an explicit selection action"
- **Code:** `lib/features/illust/detail/widgets/detail_action_bar.dart`, `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/illust/viewer/image_viewer_page.dart`

### DETAIL-11 One page counter that never hard-cuts
- **Rule:** `DetailPageCounter` is the sole page counter (hidden for single-page, ugoira, and selection; `IgnorePointer` so taps pass through to open the viewer).
- **Why:** Multiple counters disagreed and intercepting pointers blocked taps on the artwork.
- **Check:** `test/illust_detail_page_test.dart` "an illustration set opens on its first image" "tapping the pill spot reaches the artwork viewer"
- **Code:** `lib/features/illust/detail/widgets/detail_page_counter.dart`

### DETAIL-13 Prompt anchors notify after layout
- **Rule:** `PromptAnchors` defers build/layout notifications to one post-frame callback.
- **Why:** Notifying during `LayoutBuilder` mutated prompt layout mid-`performLayout`.
- **Check:** manual
- **Code:** `lib/app/widgets/prompt_anchor.dart`

### DETAIL-19 Accessible viewer chrome and reversible tag-mute controls
- **Rule:** `ImageViewerPage` pins chrome open under `pinsImmersiveChromeForAccessibility` and resets zoom on system back before popping. Batch tag-muting mode displays an explicit header + Done action and intercepts back (`PopScope`/embedded back) before popping the detail page; single-tag menu mute confirms via `FB-15` and right-click stays haptic-silent.
- **Why:** Keeps viewer chrome accessible, prevents accidental back exits while zoomed, and keeps tag muting reversible without stacking stale routes.
- **Check:** `test/illust_detail_viewer_test.dart` "accessibleNavigation pins ImageViewerPage chrome open" "system back while zoomed resets to fit and keeps the route" "viewer pages announce a per-page image and chrome controls"; `test/illust_detail_page_test.dart` "two-pane panorama preserves 280dp height, tag block mode shows Done & intercepts back, single tag mute confirms silently on right-click, and TranslationPanel avoids nested SelectableText"
- **Code:** `lib/features/illust/viewer/image_viewer_page.dart`, `lib/features/illust/detail/illust_detail_page.dart`, `lib/app/widgets/tag_actions_sheet.dart`
