---
prefix: DETAIL
applies_to:
  - lib/features/illust/**
  - lib/app/widgets/feed/desktop_inspector_scope.dart
  - lib/app/layout/app_breakpoints.dart
  - lib/app/layout/window_layout_spec.dart
  - lib/app/layout/two_pane.dart
reviewed: 2026-11-23
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

### DETAIL-02 A short first image sits low in its slot, the Hero inside it
- **Rule:** On compact widths (< 600dp), a short first illustration shown alone (a single-page work or the first page of a collapsed set; not manga, ugoira, panorama, or two-pane) applies top band `max(0, 0.7 * viewportHeight - natural) / 2` only when `>= kToolbarHeight` (56dp); smaller bands collapse to 0 so portrait works sit cleanly under `statusInset`. Expanding a set drops the band and adjusts scroll offset so page 1 stays flush under `statusInset`. Hero, placeholder, and errors stay inside the ratio box (always routed through the slot box so expanding never remounts page 1). Outside selection, the band shows `AmbientWash` (THEME-19); selection badges on multi-page works offset only by the toolbar overlap on that image (single-page works omit page-selection mode, and tapping blank margins in selection mode preserves selected pages).
- **Why:** Wide images hugged the top edge while sub-toolbar bands split toolbar icons across portrait artwork edges, remounting page 1 dropped its decode, and blank-area taps accidentally discarded multi-page selections.
- **Check:** `test/illust_detail_page_test.dart` "a short first image sits a band low; Hero and badge keep to it" "a portrait 3:4 image collapses sub-toolbar band so icons stay over artwork" "gives the first image of a set the same slot" "the band lights up from the image once it has landed"; `test/illust_detail_download_test.dart` "blank-area tap keeps page selection, single-page hides select-pages, and ugoira bottom button routes to GIF export"
- **Code:** `lib/features/illust/detail/illust_detail_scroll.dart`, `lib/features/illust/detail/illust_detail_shells.dart`, `lib/features/illust/detail/widgets/page_image.dart`

### DETAIL-03 A panorama scrolls before the pager takes over
- **Rule:** A page whose natural height is under 60% of 280dp renders in a 280dp (clamped to finite pane height) horizontally scrollable viewport opened centered without an outer `AspectRatio` squash, handing horizontal swipes to the detail pager only at its edges.
- **Why:** Ultra-wide works were unreadable thumbnails, outer `AspectRatio` squashed panoramas in two-pane stages, and greedy recognizers trapped the pager.
- **Check:** `test/illust_detail_pager_test.dart` "a panorama scrolls first and hands the swipe on at its edge"; `test/illust_detail_page_test.dart` "two-pane panorama preserves 280dp height, tag block mode shows Done & intercepts back, single tag mute confirms silently on right-click, and TranslationPanel avoids nested SelectableText"
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

### DETAIL-07 Sections replace their states without fades
- **Rule:** Below-the-fold section states swap in place without `StateFade`.
- **Why:** Wrapping self-fading images stacked double fades.
- **Check:** manual
- **Code:** `lib/features/illust/detail/related_illusts_section.dart`

### DETAIL-08 First-page failures retry by themselves
- **Rule:** Sections wrap their body in `AutoRetry` so transient first-page failures retry twice (1.5 s, 3 s, respecting `Retry-After`) before showing an error row.
- **Why:** Transient network blips left dead sections.
- **Check:** manual
- **Code:** `lib/features/illust/detail/on_demand_sliver.dart`

### DETAIL-15 Marks and stats under the title, the facts last; sections share one header
- **Rule:** Info order: title; wrapping line of tonal marks (AI/R-18/R-18G) + stats (views, bookmarks, full posting time as one semantics sentence); author `PersonCard` (`surfaceContainer`, PAGE-07) with follow button; caption; single-line ellipsized `TagChip`s; trailing wrapped facts (dimensions, page count >= 2, tools, tappable copy-ID chip) aligned to the 16dp margin. Every titled section starts with `DetailSectionHeader` (48dp row aligned to 16dp margin, LAYOUT-15); series cards show "part n of m" once known.
- **Why:** User decisions: consistent header spacing, clear card hierarchy for the author entry, and clean grouping of marks with stats and technical facts at the end.
- **Check:** `test/illust_detail_page_test.dart` "marks and tools show only when set; the ID copies; headings align"
- **Code:** `lib/features/illust/detail/widgets/info_block.dart`, `lib/features/illust/detail/widgets/detail_section_header.dart`

### DETAIL-16 The info block's parts build as they near
- **Rule:** `InfoBlock` is a `SliverList.list` whose parts stay built once built and watch their own stores; artwork-info jump scrolls to its first part.
- **Why:** One monolithic box built offscreen sections during the push frame.
- **Check:** `test/illust_detail_actions_test.dart` "a long six-page work still reaches InfoBlock via the menu"
- **Code:** `lib/features/illust/detail/widgets/info_block.dart`, `lib/features/illust/detail/illust_detail_page.dart`

### DETAIL-17 The comment section writes in place
- **Rule:** The section shows an entry pill (user avatar, hint, stamp key, >= 48dp tall) above up to three borderless comment rows; "See all" appears only with counted/loaded comments; comments-off shows a lock line with no pill (API-04). Tapping raises `CommentComposer` (`onGone`) attached to the keyboard or stamp panel above `barShadow` while the page remains interactive (`TapRegion` dismisses while passing touches through; unsent drafts persist; sent comments prepend and increment count). Keyboards are treated as dismissed once inset `<=` navigation bar height (600 ms fallback for non-insetting touch IMEs; under `InputModality.pointer`, switching to `keyboard` marks the surface ready and collapses open emoji/stamp panels immediately without the 600 ms hold).
- **Why:** User decisions: compose in place without leaving the page or blocking touches behind an opaque barrier, handle touch IMEs that leave nav-bar insets behind cleanly, and keep desktop/pointer input instant.
- **Check:** `test/illust_detail_actions_test.dart` "the entry composes in place; a sent comment heads the preview"; `test/comments_replies_test.dart` "a composer on its surface goes with a keyboard down to the bar" "the panel rises on a spring and waits for the keyboard"
- **Code:** `lib/features/illust/detail/comments_preview_section.dart`, `lib/features/illust/detail/widgets/detail_comment_layer.dart`, `lib/app/widgets/comment_composer.dart`, `lib/app/layout/input_modality.dart`

## Chrome

### DETAIL-09 The action bar is a centered opaque capsule or pinned inspector bar
- **Rule:** Single-column pushed detail pages center a 56dp opaque `DetailActionBar` capsule (`FuncSemanticTokens.surface`, `brandHairline`, `layerLift`, THEME-20) for download and bookmark above the safe inset, with ⋮ in the top bar holding share, bookmark edit, watch later, page selection, info jump, and mutes (FB-03). Two-pane stage (`DETAIL-14`) and `embeddedInspector: true` (`DesktopGalleryInspector`) omit the outer `AppBar` and floating capsule, pinning the author summary (`DetailAuthorCard` in stage; compact 18dp avatar header with expand/close buttons in inspector) directly above the inline action bar.
- **Why:** Mobile keeps thumb-reachable opaque actions without frosted smearing, while wide stages and inspectors avoid occluding artwork or duplicating chrome.
- **Check:** `test/illust_detail_actions_test.dart` "the ⋮ menu carries the long-press actions too" "splits into image pager and meta column"
- **Code:** `lib/features/illust/detail/widgets/detail_action_bar.dart`, `lib/features/illust/detail/illust_detail_menu.dart`, `lib/features/illust/detail/illust_detail_shells.dart`, `lib/features/illust/detail/illust_detail_page.dart`

### DETAIL-14 Landscape stage, bounded modal overlay, and universal desktop gallery inspector
- **Rule:** Desktop galleries expose `DesktopGalleryControls` density at `HomeShellChrome.contentSizeOf(context).width >= AppBreakpoints.medium` (600dp) and support `DesktopDetailMode.modal` (pushed stage) and `inspector` (`HomeShellChrome.contentSizeOf(context).width >= desktopInspectorHostMinWidth` [760dp] via `DesktopInspectableGallery`, opening a 420–520dp trailing `DesktopGalleryInspector`; on `FormFactor.pc` `FeedDensity.standard`, `minCardExtent: 204` keeps 1280px at 3 masonry columns and 1440px at 5). Switching tabs/dates (`scopeKey`) or entering feed multi-select closes any open inspector automatically. The inspector mounts `IllustDetailPage(embeddedInspector: true)` under `'desktop-inspector'` Hero scope with full history/media/action parity (`Esc`/back exits sub-modes then closes pane; expanding forwards `heroScope` and `pagerSource`). Pushed detail routes enter `AdaptiveTwoPane` when `AppBreakpoints.useTwoPaneDetailOf` holds (pairing `AmbientWash` `DetailImagePager` with bottom-corner hover chevrons, wheel paging, and unfocused `ArrowLeft`/`ArrowRight` against a 340–460dp hinge-aware resizable meta pane). Outside bounded `DetailOverlayFrame`, `IllustDetailTwoPaneShell` applies `MediaQuery.paddingOf` to stage controls, image padding, and inspector header/scroll bottom (splitting top vs bottom insets cleanly under `FoldPosture.tabletop` while keeping `AmbientWash` full-bleed). Pointer-mode outer artwork pager buttons use dedicated `previousArtworkTooltip`/`nextArtworkTooltip` + `UiIcons.arrowBack`/`arrowForward` inset `16dp` clear of the right scrollbar so outer artwork navigation never collides with inner page chevrons or the metadata scrollbar. Wide flat screens (`>= 960x600`) float `DetailOverlayFrame` via `FuncPage(boundedOverlayOnWide: true)` anchored with a `GlobalKey` across resizes (NAV-21), dimming `ShellRail` via `HomeShellModalScrim` (NAV-20), and showing close (`UiIcons.close`, `closeButtonTooltip`) across all states. `IllustDetailPage` (`DetailKeyboardShortcuts`, gated on `DetailPageActivity` and non-editing focus) and `ImageViewerPage` (`buildImageViewerShortcuts`) support `B` (bookmark toggle), `Ctrl/Cmd+S` (download all / save active page), and `Ctrl/Cmd+C` (desktop original-image copy, yielding to `SelectableRegion` / `EditableText`).
- **Why:** Enables fast side-by-side browsing or focused modal stages with full feature parity, safe-area clearance, accurate rail-subtracted breakpoints, desktop keyboard ergonomics, and collision-free artwork vs page controls across foldables and desktops.
- **Check:** `test/layout_breakpoints_test.dart` "two-pane detail needs a landscape area at least medium wide" "the secondary column stays between its bounds" "renders primary and secondary side by side" "AdaptiveTwoPane avoids vertical book hinge including rail" "AdaptiveTwoPane splits vertically on tabletop hinge" "AdaptiveTwoPane pointer handle resizes and saves ratio"; `test/illust_detail_actions_test.dart` "splits into image pager and meta column" "a layout switch fades the page in rather than swapping it" "IllustDetailTwoPaneShell applies SafeArea insets outside overlay and adapts for tabletop hinge"; `test/illust_detail_pager_test.dart` "an image pager at its last page hands the swipe to the work pager" "an image pager at its first image hands a backward swipe to the work pager, then follows the finger" "a two-pane stand-in paints the grid image on the stage" "keyboard [ / ] and Shift+Arrows turn artworks; pointer edge hover arrows navigate" "DetailImagePager supports hover arrows, mouse wheel, and unfocused arrow keys"; `test/illust_detail_page_test.dart` "DetailPageImage shows pointer click cursor, context menu, and desktop shortcuts"; `test/illust_detail_viewer_test.dart` "Ctrl+S saves active page and B toggles bookmark"; `test/home_branch_stack_test.dart` "ShellRail dims behind bounded DetailOverlayFrame and dismisses on tap"; `test/feed_selection_test.dart` "touch tablet enters multi-select via card sheet, landscape phone bar clears bottom nav, and inspector respects content width & auto-closes"
- **Code:** `lib/app/layout/app_breakpoints.dart`, `lib/app/layout/two_pane.dart`, `lib/app/layout/window_layout_spec.dart`, `lib/app/navigation/func_page.dart`, `lib/app/widgets/feed/feed_grid.dart`, `lib/app/widgets/feed/desktop_gallery_controls.dart`, `lib/app/widgets/feed/desktop_inspectable_gallery.dart`, `lib/app/widgets/feed/desktop_inspector_scope.dart`, `lib/features/illust/detail/widgets/desktop_gallery_inspector.dart`, `lib/features/illust/detail/widgets/detail_overlay_frame.dart`, `lib/features/illust/detail/widgets/detail_keyboard_shortcuts.dart`, `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/illust/detail/illust_detail_shells.dart`, `lib/features/illust/detail/widgets/detail_image_pager.dart`, `lib/features/illust/detail/illust_detail_pager_page.dart`, `lib/features/illust/viewer/image_viewer_shortcuts.dart`, `lib/features/illust/viewer/image_viewer_page.dart`

### DETAIL-18 Single-column detail text keeps the article width
- **Rule:** On single-column content areas wider than `ContentWidths.article` (700dp), info block and comments preview center inside a 700dp column while artwork and related grid keep full width.
- **Why:** Full-width ~900dp portrait lines were hard to read.
- **Check:** `test/illust_detail_page_test.dart` "text keeps the article column on a large portrait"
- **Code:** `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/illust/detail/illust_detail_shells.dart`, `lib/features/illust/detail/illust_detail_menu.dart`, `lib/app/layout/sliver_width_builder.dart`

### DETAIL-10 The download button listens to the manager itself
- **Rule:** `DetailDownloadButton` subscribes to `DownloadManager.changes` for live progress; detail and viewer pages refresh page badges only on terminal `events` matching their own work.
- **Why:** Rebuilding whole detail pages per progress tick or unrelated batch events wasted frames.
- **Check:** `test/illust_detail_download_test.dart` "download feedback opens tasks after the detail is disposed" "multi-page works expose an explicit selection action"
- **Code:** `lib/features/illust/detail/widgets/detail_action_bar.dart`, `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/illust/viewer/image_viewer_page.dart`

### DETAIL-11 One page counter that never hard-cuts
- **Rule:** `DetailPageCounter` is the sole page counter (hidden for single-page, ugoira, and selection; `IgnorePointer`; fades after entry transition). A page visible only behind the status/toolbar counts off-screen; its collapse pill fades out while the bottom collapse button is half visible (read via render box after layout).
- **Why:** Multiple counters disagreed and dual collapse pills confused users.
- **Check:** `test/illust_detail_page_test.dart` "an illustration set opens on its first image"
- **Code:** `lib/features/illust/detail/widgets/detail_page_counter.dart`

### DETAIL-13 Prompt anchors notify after layout
- **Rule:** `PromptAnchors` defers build/layout notifications to one post-frame callback.
- **Why:** Notifying during `LayoutBuilder` mutated prompt layout mid-`performLayout`.
- **Check:** manual
- **Code:** `lib/app/widgets/prompt_anchor.dart`

### DETAIL-19 Pointer viewer wheel zoom, multi-page hover scrubber, wide info panel and selectable detail text
- **Rule:** `ImageViewerPage` aligns top/bottom bar insets on `FuncSpacing.sm`, pins chrome open under `pinsImmersiveChromeForAccessibility`, mounts a bare-glyph `BookmarkSwitchButton` in its bottom bar under `ArtworkControls` alongside bookmark/edit-bookmark actions in the right-click context menu and wide info panel (`image_viewer_actions.dart`), binds `B` (toggle bookmark) and `Shift+B` (open bookmark edit sheet, also wired in `DetailKeyboardShortcuts`), zooms around the cursor on vertical mouse wheel (ignoring `dy == 0` horizontal scrolls; snapping 0.94–1.06 and zoom-outs at `1.0x` cleanly to `Matrix4.identity()` without corner-locking; cancelling in-flight zoom animations on `InteractiveViewer.onInteractionStart`; Shift+wheel turns pages from `dy` or `dx`), uses localized `viewerZoomIn` (2.5×) in the right-click menu, binds desktop `<`/`>` page arrows directly to chrome visibility while excluding hidden chrome and page-nav buttons from keyboard focus via `ExcludeFocus(excluding: !visible)`, shows the hover thumbnail scrubber only for `pages >= 2` with explicit active-drag tracking so dragging back over the starting page never flickers the preview bubble, and on `>= 840dp` docks a 320dp trailing info panel (filled info toggle on `MotionTokens.chrome` with leaving `IgnorePointer`; `Esc`/back closes panel before viewer; author/tag links pop viewer before navigating). Standalone detail pages wrap metadata in `SelectionArea` (excluding chrome, collapsed `ExpandableText` fades, and touch `TagChip`s via `SelectionContainer.disabled`); `IllustDetailPagerPage` hosts one outer `SelectionArea` outside its slope-gated pager drag recognizer. Batch tag-muting mode displays an explicit header + Done action and intercepts back (`PopScope`/embedded back) before popping the detail page; single-tag menu mute confirms via `FB-15` and right-click stays haptic-silent.
- **Why:** Desktop needs predictable wheel zoom, interruptible animations, chrome-synced arrows, flicker-free scrubbing, hidden-chrome focus hygiene, docked info, reversible tag-mute controls, viewer bookmark access, and text selection without breaking touch swipes or stacking stale viewer routes.
- **Check:** `test/illust_detail_viewer_test.dart` "ImageViewer supports wheel zoom with 1.0x snap, multi-page hover scrubber, and wide info panel pop-before-navigate" "ImageViewer exposes bottom bookmark button and Shift+B edit sheet"; `test/illust_detail_page_test.dart` "SelectionArea wraps detail and comments text while excluding IllustCard, collapsed fade, and touch tags" "two-pane panorama preserves 280dp height, tag block mode shows Done & intercepts back, single tag mute confirms silently on right-click, and TranslationPanel avoids nested SelectableText"
- **Code:** `lib/features/illust/viewer/image_viewer_page.dart`, `lib/features/illust/viewer/image_viewer_actions.dart`, `lib/features/illust/viewer/image_viewer_chrome.dart`, `lib/features/illust/viewer/image_viewer_shortcuts.dart`, `lib/features/illust/detail/widgets/detail_keyboard_shortcuts.dart`, `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/illust/detail/illust_detail_pager_page.dart`, `lib/features/illust/detail/illust_detail_menu.dart`, `lib/features/illust/detail/widgets/info_block.dart`, `lib/app/widgets/tag_actions_sheet.dart`, `lib/app/widgets/expandable_text.dart`, `lib/app/widgets/tag_chips.dart`
