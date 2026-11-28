---
prefix: TRANS
applies_to:
  - lib/app/navigation/func_page.dart
  - lib/app/motion/page_transitions.dart
  - lib/app/motion/hero_*.dart
  - lib/app/motion/drag_to_dismiss.dart
  - lib/app/pixiv_image.dart
  - lib/app/widgets/feed/illust_card*.dart
  - lib/features/illust/**
  - android/app/src/main/AndroidManifest.xml
reviewed: 2026-11-28
---

# Page transitions, back gesture and Hero flights

## Contents

- [Back gesture](#back-gesture)
- [Hero flights](#hero-flights)
- [Image hand-off](#image-hand-off)

## Back gesture

### TRANS-02 iOS edge-swipe gesture and pager coexistence
- **Rule:** Never install `CupertinoPageTransitionsBuilder` or `CupertinoPageRoute` directly. On iOS only, `FuncPage` attaches a leading-edge inward back detector within `24dp + safe-area edge padding`, gated on `isCurrent`, non-`fullscreenDialog`, active branch `TickerMode`, and `popGestureEnabled` (`canPop`, no `PopScope(canPop: false)`, and no pending local-history pop). `NovelReaderStage` leaves `canPop: true` on iOS even while reader chrome is open (restoring `SystemUiMode.edgeToEdge` on pop), while dirty-form `PopScope(canPop: false)` guards stay unchanged. Android and desktop keep `handleStartBackGesture` false.
- **Why:** Protects horizontal pagers, dirty-form `PopScope` guards (TRANS-03), and offstage branches (TRANS-04) while enabling consistent native iOS swipe-back.
- **Check:** `test/func_page_test.dart` "iOS edge-swipe pops active visible route from left 24dp edge without stealing pager drags" "iOS edge-swipe respects PopScope dirty-form guard and stays off on offstage branches"; `test/novel_reader_stage_test.dart` "iOS left-edge swipe pops NovelReaderStage even while chrome is visible and restores edgeToEdge"
- **Code:** `lib/app/navigation/func_page.dart`, `lib/app/navigation/route_animation.dart`, `lib/features/novel/novel_reader_stage.dart`

### TRANS-03 Back uses PopScope.onPopInvokedWithResult
- **Rule:** Pages use `PopScope.onPopInvokedWithResult` (never `WillPopScope`), keeping `enableOnBackInvokedCallback` enabled and blocking pops when unsaved edits need confirmation.
- **Why:** Supports Android predictive back-to-home without discarding dirty forms.
- **Check:** `test/func_page_test.dart` "a dirty profile editor confirms on the back gesture instead of popping"
- **Code:** `lib/features/profile/profile_edit_page.dart`

### TRANS-04 The back gesture is the back button
- **Rule:** No route or observer takes the Android/desktop system back gesture (`handleStartBackGesture` returns false); commits route through `handlePopRoute`, popping only the visible branch or root overlay. Never add `PredictiveBackPageTransitionsBuilder`.
- **Why:** User decision: in-app predictive-back previews conflicted with custom slide, Hero, sheet, and offstage-branch transitions.
- **Check:** `test/func_page_test.dart` "only the visible branch answers the back gesture" "a root-level page owns the gesture over the whole shell"
- **Code:** `lib/app/navigation/func_page.dart`

## Hero flights

### TRANS-07 Hero tags are scoped per surface; only the branch on screen pairs
- **Rule:** All Hero tags use `illustHeroTag(scope, id)` with stable per-surface scopes (`'history'`, `'me-history'`, etc.); routes without a matching source skip Hero cleanly; `HomeBranchStack` wraps inactive branches in `HeroMode(enabled: false)`. Flights ignore deactivated endpoints without throwing.
- **Why:** Prevented root overlays like the viewer from flying to matching cards in hidden branches or crashing on mid-flight route removal.
- **Check:** `test/architecture/ui_conventions_test.dart` "Hero uses only the shared illustHeroTag family", `test/hero_transition_test.dart` "the viewer pairs only with the branch on screen" "Hero flight ignores deactivated endpoints without throwing"
- **Code:** `lib/app/motion/hero_transition.dart`, `lib/app/widgets/home_branch_stack.dart`

### TRANS-08 Opening a work never waits for the image
- **Rule:** Cards may start `PixivImage.preload` on pointer-down but push immediately; the detail page's first frame paints `initialEntity` using the card's preview URL and worker entry without fetching the large image twice.
- **Why:** Awaiting preload delayed taps and duplicate URL requests wasted bandwidth.
- **Check:** `test/hero_transition_test.dart` "detail page fetches large image once after Hero flight settles"; `test/pixiv_image_pipelines_test.dart` "a preload lands on the entry of the widget that will show it"
- **Code:** `lib/app/widgets/feed/illust_card.dart`, `lib/features/illust/detail/widgets/page_image.dart`

### TRANS-14 Drag-to-dismiss yields to controls that own their drag
- **Rule:** Omnidirectional controls under `DragToDismiss` (e.g. scrubber) claim pointers via `allowPointer`; transient drag overlays mount after the slider in its `Stack`.
- **Why:** Prevented vertical thumb drift or inserted overlays from breaking scrubber drags.
- **Check:** `test/illust_detail_viewer_test.dart` "scrubbing jumps to the target page without building crossed pages"
- **Code:** `lib/app/motion/drag_to_dismiss.dart`, `lib/features/illust/viewer/image_viewer_chrome.dart`

### TRANS-21 Every artwork flight checks its card end
- **Rule:** `inspectHeroFlight` verifies card-ended flights are live, on-page, and match `noteHeroCardOpened` within 2 s (skipping detail-to-viewer), logging anomalies (last 20) to `HeroAnomalyLog` and surfacing a prompt when developer options are unlocked.
- **Why:** Captures rare real-device flight glitches with route and box diagnostics.
- **Check:** `test/hero_transition_test.dart` "a failed anomaly write is logged and the next one lands"
- **Code:** `lib/app/motion/hero_anomaly.dart`, `lib/core/debug/hero_anomaly_log.dart`, `lib/features/settings/pages/frame_probe_page.dart`

## Image hand-off

### TRANS-15 PixivImage owns every quality hand-off
- **Rule:** Quality/URL upgrades go through `PixivImage` gaplessly (keeping previous decoded frames until ready; no caller-managed ready flags or blank loading swaps, except top-square card hand-offs).
- **Why:** Per-page ready flags flashed blank frames between qualities.
- **Check:** `test/pixiv_image_variants_test.dart` "quality handoff keeps an old decoded frame placeholder"
- **Code:** `lib/app/pixiv_image.dart`

### TRANS-16 Fade cold loads only
- **Rule:** Cold loads fade the placeholder off an already-painted image (300 ms linear); already-decoded targets and recycled slots showing another work swap without fading; feed cards key by scope and work ID.
- **Why:** Avoids grey cross-fades, white Hero flashes, and recycled-slot dissolves.
- **Check:** `test/pixiv_image_variants_test.dart` "the same URL on a reused slot keeps the cold-load fade"
- **Code:** `lib/app/pixiv_image.dart`, `lib/app/widgets/feed/feed_grid.dart`

### TRANS-17 Decoded images survive backgrounding
- **Rule:** The app binding retains decoded image frames on Android `TRIM_MEMORY_UI_HIDDEN`, clearing only live streams and `rootBundle`.
- **Why:** Avoids re-fading every artwork on app resume.
- **Check:** manual
- **Code:** `lib/main.dart`

### TRANS-18 Pager neighbours paint a decode, never a load
- **Rule:** Unbuilt pager pages render `PixivImage.decodedStandIn` (or bare surface) at the exact detail rect, fading it off on the effects spring once settled and built (instant off-screen or under reduced motion); `findChildIndexCallback` maps by work ID.
- **Why:** Eliminated landing jumps and wrong-work rebuilds when feed lists shifted.
- **Check:** `test/illust_detail_pager_test.dart` "a rewritten feed list keeps the viewport on the same work"
- **Code:** `lib/features/illust/detail/illust_detail_pager_page.dart`

### TRANS-19 The viewer decodes a preview first, the whole file once zoomed
- **Rule:** Viewer pages decode at `ImageViewerPage.previewDecodeWidth` (2x screen width) until zoomed to `fullDecodeScale` (1.5x), keeping a stable transition key across the upgrade; return Hero and `openImageViewer` preload match preview width.
- **Why:** Full originals are tens of megabytes and stalled swipes; mismatched return widths triggered double decodes.
- **Check:** `test/illust_detail_viewer_test.dart` "a page decodes a preview until zoomed, then the whole file"
- **Code:** `lib/features/illust/viewer/image_viewer_page.dart`, `lib/app/navigation/routes.dart`
