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
reviewed: 2026-11-23
---

# Page transitions, back gesture and Hero flights

## Contents

- [Page transitions and back](#page-transitions-and-back)
- [Hero flights](#hero-flights)
- [Image hand-off](#image-hand-off)

## Page transitions and back

### TRANS-01 Per-platform page transitions
- **Rule:** `FuncPage` uses `CupertinoPageTransition` + `TurnCurve` over `MotionTokens.pageTransition` (500 ms) on Android and iOS (plus iOS edge-swipe, TRANS-02), and a 150 ms `MotionTokens.desktopPageTransition` fade+slide on Desktop, collapsing to instant under `ReducedMotion` while keeping leaving-route `IgnorePointer` and covered-shell motion. No user transition setting or per-feature route transition exists; legacy `pageTransitionStyle` is ignored. Shared-element pages use TRANS-09.
- **Why:** Matches mobile spatial slides and snappy desktop navigation while handling mid-push reversal smoothly.
- **Check:** `test/func_page_test.dart` "a page slides in from the trailing edge over the page below" "back mid-push turns the slide where it is; the page below answers" "desktop uses the lightweight 150ms fade-and-slide transition and respects reduced motion"; `test/navigation_router_test.dart` "openDownloadTasks lands on /downloads; the shell moves aside"; `test/pop_snapshot_paint_test.dart` "a TurnCurve goes on from where it turns, on the other curve"; `test/app_settings_test.dart` "values saved by older versions carry over; retired keys are never"
- **Code:** `lib/app/navigation/func_page.dart`, `lib/app/motion/motion_tokens.dart`, `lib/core/settings/app_settings.dart`

### TRANS-02 iOS edge-swipe gesture and pager coexistence
- **Rule:** Never install `CupertinoPageTransitionsBuilder` or `CupertinoPageRoute` directly. On iOS only, `FuncPage` attaches a leading-edge inward back detector within `24dp + safe-area edge padding`, gated on `isCurrent`, non-`fullscreenDialog`, active branch `TickerMode`, and `popGestureEnabled` (`canPop`, no `PopScope(canPop: false)`, and no pending local-history pop). Wide iPad `boundedOverlayOnWide` routes (both shared-element and non-shared) keep the outer route stationary so `DetailOverlayFrame` fades its full-screen scrim in place via `RouteAnimationScope.popGestureOf` while sliding only the foreground card; wide `SettingsPage`'s nested detail `Navigator` uses `FuncPage` on iOS (`buildSettingsDetailRoute`). `NovelReaderStage` leaves `canPop: true` on iOS even while reader chrome is open (restoring `SystemUiMode.edgeToEdge` on pop), while dirty-form `PopScope(canPop: false)` guards stay unchanged. Android and desktop keep `handleStartBackGesture` false.
- **Why:** Protects horizontal pagers, dirty-form `PopScope` guards (TRANS-03), and offstage branches (TRANS-04) while enabling consistent native iOS swipe-back across iPad overlays, nested settings, and the novel reader without sliding dark scrims across the screen.
- **Check:** `test/func_page_test.dart` "iOS edge-swipe pops active visible route from left 24dp edge without stealing pager drags" "iOS edge-swipe respects PopScope dirty-form guard and stays off on offstage branches" "iOS bounded DetailOverlayFrame keeps scrim stationary while sliding card on edge-swipe and Settings nested detail uses FuncPage"; `test/novel_reader_stage_test.dart` "iOS left-edge swipe pops NovelReaderStage even while chrome is visible and restores edgeToEdge"
- **Code:** `lib/app/navigation/func_page.dart`, `lib/app/navigation/route_animation.dart`, `lib/features/illust/detail/widgets/detail_overlay_frame.dart`, `lib/features/settings/settings_helpers.dart`, `lib/features/settings/settings_page.dart`, `lib/features/novel/novel_reader_stage.dart`

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

### TRANS-06 Transitions snapshot only what does not move live
- **Rule:** `FuncTransitionGuard` keeps entering and covered pages live while snapshotting popping pages and settled reveals (settled 650 ms after cover began so press feedback finishes; touching a revealing page turns it live immediately). Pages under shared-element routes (`underSharedElement`, including the home shell under the viewer) stay live throughout flights.
- **Why:** Snapshotting leaving pages saves raster cost without freezing entering animations, return-flight interaction, or active touch responses.
- **Check:** `test/func_page_test.dart` "the entering page stays live while a transition runs"; `test/pop_snapshot_paint_test.dart` "a finger on a settled reveal turns it live until it ends" "a reveal inside the press window keeps the page live"; `test/hero_transition_test.dart` "the viewer leaves whole and square; the detail page answers mid-flight"
- **Code:** `lib/app/motion/page_transitions.dart`

## Hero flights

### TRANS-07 Hero tags are scoped per surface; only the branch on screen pairs
- **Rule:** All Hero tags use `illustHeroTag(scope, id)` with stable per-surface scopes (`'history'`, `'me-history'`, etc.); routes without a matching source skip Hero cleanly; `HomeBranchStack` wraps inactive branches in `HeroMode(enabled: false)`.
- **Why:** Prevented root overlays like the viewer from flying to matching cards in hidden branches.
- **Check:** `test/architecture/ui_conventions_test.dart` "Hero uses only the shared illustHeroTag family", `test/hero_transition_test.dart` "the viewer pairs only with the branch on screen"
- **Code:** `lib/app/motion/hero_transition.dart`, `lib/app/widgets/home_branch_stack.dart`

### TRANS-08 Opening a work never waits for the image
- **Rule:** Cards may start `PixivImage.preload` on pointer-down but push immediately; the detail page's first frame paints `initialEntity` using the card's preview URL and worker entry.
- **Why:** Awaiting preload delayed taps and mismatched URLs flashed placeholders.
- **Check:** `test/hero_transition_test.dart` "a top-square card flies its square over the whole work; the page image "; `test/pixiv_image_pipelines_test.dart` "a preload lands on the entry of the widget that will show"
- **Code:** `lib/app/widgets/feed/illust_card.dart`

### TRANS-09 Shared-element pages cover a still page, then show
- **Rule:** Hero pages use `FuncPage(sharedElement: true)` (`MotionTokens.sharedElement` 450 ms, no slide, still live underlying page): detail pages layer `sharedElementBackdrop` (`sharedElementBackdropIn`/`Out`) then content (`sharedElementContentIn`/`Out`, primed at 1/255 alpha from frame 1 so text rasterizes before reveal); viewer fades whole (`sharedElementFadeIn`, `Curves.easeInOutCubic` reverse). Reversals use `TurnCurve`; Hero uses `illustHeroCurve`; leaving pages ignore touches and `didChangePrevious`; opening pages block touches until visible; landed detail exits punch `HeroLiftHole` (viewer does not); `IllustPagerSource.aimHomeFlight` skips offscreen cards. Never change transition widget structure or set `canTransitionTo: false`.
- **Why:** User decision: clean backdrop-then-content reveal without raster stalls, offscreen flights, double-tap viewer launches, or sliding underlying feeds on double-back.
- **Check:** `test/func_page_test.dart` "a shared-element page covers a still page" "the viewer stage fades whole, with no background" "two backs in a row leave the page under the shared-element"; `test/hero_transition_test.dart` "the viewer leaves whole and square; the detail page answers mid-flight" "an image sent back mid-flight turns where it is"; `test/architecture/ui_conventions_test.dart` "Hero uses only the shared illustHeroTag family"; `test/illust_card_badges_test.dart` "the pager image flies back only to a card on screen"
- **Code:** `lib/app/navigation/func_page.dart`, `lib/app/navigation/routes.dart`, `lib/app/motion/hero_transition.dart`, `lib/app/widgets/feed/feed_grid.dart`

### TRANS-10 The card page's bars ride over a card flight; other flights clip
- **Rule:** Card flights (`IllustHeroCardFrame`) capture top/bottom bar bands (with `LiftableShadow`) and slide them off/on with solid backgrounds while hiding real `LiftableBar`s and unclipping viewport bounds, releasing on shuttle `deactivate` (re-lifting if reparented). `boundedOverlayOnWide` routes skip bar capture and drive `HomeShellModalScrim` continuously from `RouteAnimationScope.of(context)`. Other flights interpolate global chrome clips via `HeroPageCover` using shuttle geometry and flight-overlay status insets (`edgeToEdge` viewer has no top chrome). `HeroChrome` hides overlapping artwork chrome until landing (`holdable` opaque bars clip below).
- **Why:** User decision: keeps bars riding naturally over card flights without hard mid-bar cuts, 1-frame bar flashes, or status-inset jumps between detail and viewer.
- **Check:** `test/hero_lifted_bars_test.dart` "a card flight lifts the card page's bars over the image" "a card flight shows the feed under the bars it lifts, and ", `test/hero_transition_test.dart` "Hero pop flight is occluded by the chrome" "Hero push from a nested feed stays intact" "chrome over a flight steps aside until the landing" "detail and viewer: the clip runs between the work page's top ", `test/home_branch_stack_test.dart` "wide HomePage modal scrim starts at 0.0 on frame 0 and decays monotonically on pop or interrupt"
- **Code:** `lib/app/motion/hero_rect_clip.dart`, `lib/app/motion/hero_transition.dart`, `lib/app/motion/hero_lifted_bars.dart`, `lib/app/navigation/func_page.dart`, `lib/app/widgets/func_bottom_nav.dart`, `lib/app/widgets/app_top_bar.dart`, `lib/features/profile/profile_header_delegate.dart`

### TRANS-11 Card rounding lives inside the Hero child
- **Rule:** `IllustHeroCardFrame` clips inside the Hero child (`ClipRRect(FuncShape.card)`, no inner border per THEME-20); only card-ended flights round corners (detail <-> viewer stays square). Cropped cards pass `cropAspect` so the flight covers and clips cleanly like uncropped Heroes.
- **Why:** Outer clips snapped corners on pop and lerping radii rounded detail-to-viewer flights.
- **Check:** `test/hero_transition_test.dart` "a cropped image covers its flight rect; both sides keep pace"
- **Code:** `lib/app/widgets/feed/illust_card.dart`, `lib/features/settings/me_dashboard_page.dart`, `lib/app/motion/hero_transition.dart`

### TRANS-20 Artwork flights scale both sides together
- **Rule:** Every artwork Hero sets `createRectTween: illustHeroRectTween` so center arcs while width and height interpolate together.
- **Why:** Material's default corner-arc tween made dissimilar shapes finish width before height.
- **Check:** `test/hero_transition_test.dart` "a cropped image covers its flight rect; both sides keep pace"; `test/settings_test.dart` "a recent cover flies to its work and back, an unseen one not"
- **Code:** `lib/app/motion/hero_transition.dart`

### TRANS-22 A flight keeps the card's image until it lands
- **Rule:** Detail Hero endpoints keep `heroImageUrl` until the route animation from `RouteAnimationScope.of` completes (never reading `ModalRoute.animation`), then switch to the detail URL.
- **Why:** `ModalRoute.animation` read `completed` during offstage Hero measurement and swapped URLs mid-flight.
- **Check:** `test/hero_transition_test.dart` "a top-square card flies its square over the whole work; the page image "
- **Code:** `lib/app/navigation/func_page.dart`, `lib/app/navigation/route_animation.dart`, `lib/features/illust/detail/widgets/page_image.dart`

### TRANS-23 A tall card's square flies over the whole work; an author's cover does not fly
- **Rule:** Tall cards showing Pixiv's top square (`isTopSquareThumbnail`, `IllustCardCrop.topSquare`) keep Hero, preload the whole feed-tier preview underneath, fly the sharp square over the copy, reveal the detail image after landing (fading if not yet decoded), and fade the square back across 60–90% of return. Author `custom-thumb` covers (`IllustCardCrop.square`) and tall ugoira covers open without Hero.
- **Why:** User decision: keeps ultra-long works sharp during flight without leaving the lower half blank or flying unrelated custom covers.
- **Check:** `test/hero_transition_test.dart` "a top-square card flies its square over the whole work; the page image "; `test/recommended_feed_test.dart` "a tall card keeps its Hero only on pixiv's own top square, "; `test/illust_card_layout_test.dart` "pixiv's own square thumbnail is the work's top, an author's is not" "isTopSquareThumbnail knows pixiv's own square at any size"
- **Code:** `lib/app/widgets/feed/illust_card_layout.dart`, `lib/app/widgets/feed/illust_card.dart`, `lib/app/motion/hero_transition.dart`, `lib/features/illust/detail/widgets/page_image.dart`, `lib/app/pixiv_image.dart`

### TRANS-12 Only the viewer's entry page flies back
- **Rule:** Viewer carries Hero only on its opening page; after turning pages, drag-to-dismiss slides down and back fades out (TRANS-09).
- **Why:** Flying a different page back into the entry card looked wrong.
- **Check:** `test/hero_transition_test.dart` "only the entry page flies back; a drag from another page "
- **Code:** `lib/features/illust/viewer/image_viewer_page.dart`

### TRANS-13 The detail image list has one sliver type
- **Rule:** Detail pages always build image pages as one `SliverList` regardless of page count.
- **Why:** Switching sliver types when payload count differed rebuilt the landing Hero mid-flight.
- **Check:** `test/hero_transition_test.dart` "mid-flight the detail endpoint paints no image of its own"
- **Code:** `lib/features/illust/detail/widgets/detail_image_pager.dart`

### TRANS-14 Drag-to-dismiss yields to controls that own their drag
- **Rule:** Omnidirectional controls under `DragToDismiss` (e.g. scrubber) claim pointers via `allowPointer`; transient drag overlays mount after the slider in its `Stack`.
- **Why:** Prevented vertical thumb drift or inserted overlays from breaking scrubber drags.
- **Check:** `test/illust_detail_viewer_test.dart` "scrubbing jumps to the target page without building crossed pages"
- **Code:** `lib/app/motion/drag_to_dismiss.dart`, `lib/features/illust/viewer/image_viewer_chrome.dart`

## Image hand-off

### TRANS-15 PixivImage owns every quality hand-off
- **Rule:** Quality/URL upgrades go through `PixivImage` gaplessly (keeping previous decoded frames until ready; no caller-managed ready flags or blank loading swaps; TRANS-23 is the sole exception).
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
- **Check:** `test/illust_detail_page_test.dart` "a short first image sits a band low; Hero and badge keep to it", `test/illust_detail_pager_test.dart` "a rewritten feed list keeps the viewport on the same work" "a page built where a swipe settles fades in around"
- **Code:** `lib/features/illust/detail/illust_detail_pager_page.dart`

### TRANS-19 The viewer decodes a preview first, the whole file once zoomed
- **Rule:** Viewer pages decode at `ImageViewerPage.previewDecodeWidth` (2x screen width) until zoomed to `fullDecodeScale` (1.5x), keeping a stable transition key across the upgrade; return Hero and `openImageViewer` preload match preview width.
- **Why:** Full originals are tens of megabytes and stalled swipes; mismatched return widths triggered double decodes.
- **Check:** `test/illust_detail_viewer_test.dart` "a page decodes a preview until zoomed, then the whole file", `test/hero_transition_test.dart` "the viewer leaves whole and square; the detail page answers mid-flight"
- **Code:** `lib/features/illust/viewer/image_viewer_page.dart`, `lib/app/navigation/routes.dart`

### TRANS-21 Every artwork flight checks its card end
- **Rule:** `inspectHeroFlight` verifies card-ended flights are live, on-page, and match `noteHeroCardOpened` within 2 s (skipping detail-to-viewer), logging anomalies (last 20) to `HeroAnomalyLog` and surfacing a prompt when developer options are unlocked.
- **Why:** Captures rare real-device flight glitches with route and box diagnostics.
- **Check:** `test/hero_transition_test.dart` "a flight from a card out of sight is logged, others not" "a push is held to the tapped card only when it leaves a card"
- **Code:** `lib/app/motion/hero_anomaly.dart`, `lib/core/debug/hero_anomaly_log.dart`, `lib/features/settings/pages/frame_probe_page.dart`

### TRANS-24 iOS shared-element routes dim the backdrop on a shrunken opaque-free canvas
- **Rule:** iOS shared-element `FuncPage` routes start dismiss drags from a 48dp leading edge, 72dp top chrome strip, or top-rested downward scroll without stealing pager swipes (tracking the settled horizontal page on depth-0 `PageMetrics` so same-page snap-backs never falsely reset the vertical top-of-scroll flag). While dragging, the route flips `opaque` and its first overlay entry's `opaque` to `false` so the underlying route shows behind the damped, min-0.85-scaled, `FuncShape.dialog`-rounded canvas, restoring `opaque` on cancel and handing the shrunken rect to the return Hero on commit.
- **Why:** Keeping overlay entries opaque culled the underlying route and flashed solid backgrounds until `pop()`.
- **Check:** `test/func_page_test.dart` "iOS sharedElement route uses damped canvas scale, backdrop fade, widened edge, and gesture cleanup" "iOS sharedElement vertical pull dismisses cleanly without conflicting with scrollables or horizontal pager"
- **Code:** `lib/app/navigation/func_page.dart`, `lib/app/motion/hero_transition.dart`, `lib/app/theme/func_tokens.dart`
