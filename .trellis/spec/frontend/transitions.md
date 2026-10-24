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
reviewed: 2026-10-21
---

# Page transitions, back gesture and Hero flights

## Contents

- [Page transitions and back](#page-transitions-and-back)
- [Hero flights](#hero-flights)
- [Image hand-off](#image-hand-off)

## Page transitions and back

### TRANS-01 One page transition: the Cupertino slide
- **Rule:** Every pushed page slides in from the trailing edge with
  `CupertinoPageTransition` (the page below darkens and moves aside) on
  every platform, over `MotionTokens.pageTransition` (500ms). There is no
  transition setting and no hand-written transition. A stored
  `pageTransitionStyle` is ignored and not written back. Shared-element
  pages have their own transition (TRANS-09).
- **Why:** User decision (10-20): FadeForwards read as odd; the slide is
  one motion the user can follow. Earlier, shared axis and zoom were
  dropped, and fade-through is for unrelated destinations, not pushes.
- **Check:** `test/func_page_test.dart` "a page slides in from the trailing edge over the page below"; `test/app_settings_test.dart` "a retired pageTransitionStyle key reads and is not written"
- **Code:** `lib/app/navigation/func_page.dart`, `lib/core/settings/app_settings.dart`

### TRANS-02 The slide uses the Cupertino widget, not its builder
- **Rule:** The slide is the `CupertinoPageTransition` widget, never
  `CupertinoPageTransitionsBuilder` or `CupertinoPageRoute`.
- **Why:** The builder adds an iOS edge-swipe detector that steals
  horizontal drags from the detail pager.
- **Check:** manual
- **Code:** `lib/app/navigation/func_page.dart`

### TRANS-03 Back uses PopScope.onPopInvokedWithResult
- **Rule:** Pages handle back with `PopScope.onPopInvokedWithResult`;
  `WillPopScope` is not used and `enableOnBackInvokedCallback` stays on. A
  page with unsaved edits reports a non-pop disposition, so back, the
  button or the gesture, shows its discard confirmation.
- **Why:** The system's back-to-home animation needs the callback model;
  a dirty page must not be swiped away.
- **Check:** `test/func_page_test.dart` "a dirty profile editor confirms on the back gesture instead of popping"
- **Code:** `lib/features/profile/profile_edit_page.dart`

### TRANS-04 The back gesture is the back button
- **Rule:** No route or binding observer takes the system back gesture
  (`handleStartBackGesture` returns false everywhere): nothing follows the
  finger, a cancel does nothing, and the commit reaches
  `handlePopRoute`, the back button's path. That path pops only the
  visible branch's page, or the root-level page covering the shell. Do
  not add `PredictiveBackPageTransitionsBuilder` or a gesture driver.
- **Why:** User decision (10-20): no in-app gesture-following back. A
  route following the gesture had to gate itself on branch visibility
  (parked branches keep an `isCurrent` route offstage and popped a page
  the user could not see) and release the Navigator when a commit threw;
  the back button's path already does both.
- **Check:** `test/func_page_test.dart` "only the visible branch answers the back gesture" "a root-level page owns the gesture over the whole shell"
- **Code:** `lib/app/navigation/func_page.dart`

### TRANS-06 Transitions snapshot only what does not move live
- **Rule:** Every transition runs inside `FuncTransitionGuard`: entering
  and covered pages paint live with running tickers; a popping page and a
  settled reveal paint one snapshot each. A page under a shared-element
  page (`underSharedElement`), the home shell under the viewer included,
  is never frozen: it stays live while the image flies.
- **Why:** Re-rendering the leaving page every frame dropped frames;
  freezing the entering page froze its entrances. A detail page frozen
  under the viewer's return flight could not be scrolled or tapped to any
  visible effect until the image had landed.
- **Check:** `test/func_page_test.dart` "the entering page stays live while a transition runs"; `test/hero_transition_test.dart` "the viewer leaves whole and square; the detail page answers mid-flight"
- **Code:** `lib/app/motion/page_transitions.dart`

## Hero flights

### TRANS-07 Hero tags are scoped per surface; only the branch on screen pairs
- **Rule:** The only Hero tags are `illustHeroTag(scope, id)`. Each mounted
  surface uses its own stable scope (the history page `'history'`, the Me
  row `'me-history'`), and the card and the detail route it opens share
  scope and id. A route without a matching source uses the normal
  transition; it never fakes a source. `HomeBranchStack` wraps every
  branch but the current one in `HeroMode(enabled: false)`.
- **Why:** The same work in two mounted feeds flew from the wrong card. A
  route on the root navigator (the viewer) collects the Heroes of every
  branch's top page; the same work open in a branch out of sight shared
  the tag, and in release the last one collected won: the image flew to
  where the hidden branch had it, read by the user as "the history's
  place" (10-21).
- **Check:** `test/architecture/feedback_channels_test.dart` "Hero uses only the shared illustHeroTag family", `test/hero_transition_test.dart` "the viewer pairs only with the branch on screen"
- **Code:** `lib/app/motion/hero_transition.dart`, `lib/app/widgets/home_branch_stack.dart`

### TRANS-08 Opening a work never waits for the image
- **Rule:** A card may start `PixivImage.preload` on pointer down but pushes
  the detail route without awaiting it. The detail page's first frame
  renders from `initialEntity` and the card's preview URL, loaded through
  the same worker entry as the card.
- **Why:** Awaiting preload delayed every tap; a different first URL made
  the Hero start from a placeholder.
- **Check:** `test/hero_transition_test.dart` "feed → detail → viewer keeps one hero tag family"
- **Code:** `lib/app/widgets/feed/illust_card.dart`

### TRANS-09 Shared-element pages cover a still page, then show
- **Rule:** A page opened with a Hero is `FuncPage(sharedElement: true)`
  and does not move: `MotionTokens.sharedElement` (450ms), no slide, no
  barrier, the page below still and live. With its background
  (`sharedElementBackdrop`, the detail) two layers run off the
  controller: opening, the background (`scaffoldBackgroundColor`) covers
  the page below over `sharedElementBackdropIn`, then the content fades in
  over `sharedElementContentIn`, painted at the faintest alpha (1/255)
  from the opening's second frame until then; leaving, the content fades out over
  `sharedElementContentOut`, then the background over
  `sharedElementBackdropOut`. The viewer has no background: its stage
  fades whole (`sharedElementFadeIn`/`Out`). A leave that cuts an opening
  short takes each layer down from the opacity it reached. The Hero flies
  on `MotionTokens.spatialCurve`, set on every artwork Hero end (a flight
  reads the curve of the page that opens or leaves). A leaving page takes
  no touch, so the page below answers while the image flies. While a
  landed page leaves, `HeroLiftHole` cuts the flying image's spot out of
  its content, so what is under the content shows there; an opening page
  has none. The viewer's endpoint (`IllustHeroFlightChild.containsImage`)
  cuts nothing. Under a page pushed on top it slides like any page. The
  transition's widget structure never changes over the route's life. A
  detail pager aims each settled work's back flight
  (`IllustPagerSource.aimHomeFlight`): a card with nothing on screen takes
  no flight. Do not refuse the transition (`canTransitionTo` false).
- **Why:** User decision (10-20): the detail's content laid half
  transparent over the feed read as odd; the Hero stays. A slide moves
  both ends of the flight while the image crosses between them.
  Shared-element transitions on Android, iOS (zoom) and in Flutter's
  Wonderous keep the page below still. One curve played backwards held
  the leaving page until the image had nearly landed; switching curves
  mid-opening dropped a half-shown page in one frame. The viewer's dark
  stage covers the page below by itself, and a drag to dismiss it reveals
  that page. A changed transition widget type reparents the page's
  GlobalKey subtree and rebuilds the whole page in that frame. Hero pairs
  by tag alone, so a card built in the cache extent pulled the image in
  from off the screen. Refusing the transition stopped the secondary
  animation, so the bottom bar appeared over the leaving page. A hole in
  the viewer read as a sharp-edged window that did not fade with the
  stage. Content at alpha 0 is not painted, so its whole page of text was
  first drawn when its fade began, mid-flight: a raster frame of 12–20ms
  stalled the image on every opening (10-24).
- **Check:** `test/func_page_test.dart` "a shared-element page covers a still page" "the viewer stage fades whole, with no background"; `test/hero_transition_test.dart` "the viewer leaves whole and square; the detail page answers mid-flight"; `test/architecture/feedback_channels_test.dart` "Hero uses only the shared illustHeroTag family"; `test/illust_card_badges_test.dart` "the pager image flies back only to a card on screen"
- **Code:** `lib/app/navigation/func_page.dart`, `lib/app/navigation/routes.dart`, `lib/app/motion/hero_transition.dart`, `lib/app/widgets/feed/feed_grid.dart`

### TRANS-10 The card page's bars ride over a card flight; other flights clip
- **Rule:** A card's flight to and from its page (an `IllustHeroCardFrame`
  end) lifts the card page's bars over the image: the bands of the page
  above and below the card's viewport, across the page, captured as the
  flight takes off (the screen before a push, the card's page on a pop).
  They slide off the screen as the image opens, the top one up and the
  bottom one down, each by its own height, and back as it returns, by the
  image's progress; each keeps its background (the page colour) solid and
  fades its content with the slide. The image is clipped at the far end
  alone. Meanwhile the shared-element page's `HeroBarsCover`, over its
  background and under its content, paints the real bars over in the
  page colour; they show again as the flight ends, where the lifted ones
  rest. Other flights use a global clip between the source and
  destination chrome boundaries, interpolated by how much the
  shared-element page over the card's route covers it (its background,
  or the whole page without one), or over the route holding
  the card's navigator (the viewer on the root navigator over a branch's
  detail page; `HeroPageCover`, the more opaque of a leaving page and its
  reopened successor), by flight
  progress where no page registered one. Flight progress (radius, the
  cropped part's reveal) is read off the shuttle's size between the two
  ends, not the route animation. Ignore horizontal route transforms, and
  use a conservative chrome fallback when an endpoint is offstage. Chrome
  drawn over a Hero image (card badges, the detail top bar, page counter
  and action bar) is `HeroChrome`: while a flight runs, the chrome its
  ends overlap is hidden, including that of a page opened while the
  image flew home, and fades in (`stateFade`) once the image has landed.
  Tests inspect the render-time clip.
- **Why:** Artwork covered app bars and the bottom bar, or was cut hard on
  landing; slide transforms made the boundary empty. The page covers the
  page below over the first part of the flight while the image flies on, so a clip that
  followed the image left it over the tab row and the bottom bar of a
  feed already shown. On a card flight no clip read right (user, 10-24,
  after three prototypes): a bar that only fades either cut the image
  along a line nobody could see or let it fly over the bar before the bar
  showed. Google's Jetsnack keeps its bars over the shared element and
  slides them away (`renderInSharedTransitionScopeOverlay` with
  `animateEnterExit`). A whole bar fading over the image showed the image
  through it, split in two; its solid background does not. Only the bands
  are captured, so the takeoff frame rasterizes two strips, not a page. A card opened again while its image flew home
  sends the flight to the new page but keeps the shuttle, built with the
  old route's animation, which stops: the clip and the corners froze at
  the card end and the tab row cut the image on the detail page. The
  shuttle is painted over every page, so chrome on the image was covered
  as a flight set off and popped back whole at the landing, and badges
  floated over the card's empty slot.
- **Check:** `test/hero_transition_test.dart` "a card flight lifts the card page's bars over the image" "Hero pop flight is occluded by the chrome" "Hero push from a nested feed stays intact" "chrome over a flight steps aside until the landing"
- **Code:** `lib/app/motion/hero_rect_clip.dart`, `lib/app/motion/hero_transition.dart`, `lib/app/motion/hero_lifted_bars.dart`, `lib/app/navigation/func_page.dart`

### TRANS-11 Card rounding lives inside the Hero child
- **Rule:** The card's corner clip (`IllustHeroCardFrame`) wraps the Hero
  child, and feed cards draw no outline. Only a flight with a card end
  rounds its corners; detail ↔ viewer flies square. A card that shows
  only part of the image (the top of a taller one, the middle of a wider
  one) hands its `cropAspect` to the flight, which lays the image out
  covering the rect, top-aligned and centered across, and cuts it to the
  rect for the whole flight, the way an uncropped card's image fills it
  (user decision: like any other Hero).
- **Why:** A clip outside the Hero snapped from square to rounded on pop;
  fitting the image inside the rect mid-flight read as a second shrink.
  A radius lerped by flight progress rounded the square detail ↔ viewer
  flight on its way. Fading in the part the card hid made the history
  row's flights look unlike every other one.
- **Check:** `test/hero_transition_test.dart` "a cropped image covers its flight rect; both sides keep pace"
- **Code:** `lib/app/widgets/feed/illust_card.dart`, `lib/features/settings/me_dashboard_page.dart`, `lib/app/motion/hero_transition.dart`

### TRANS-20 Artwork flights scale both sides together
- **Rule:** Every artwork Hero (feed card, history cover, detail page,
  ugoira, viewer) sets `createRectTween: illustHeroRectTween`: the center
  rides Material's arc, width and height follow one progress. The Hero
  that receives the flight picks the tween, so all of them carry it.
- **Why:** Material's default arcs two opposite corners. Between rects of
  different size and shape one side lands long before the other: an 88dp
  history cover reached its width, then shrank a step more in height.
- **Check:** `test/hero_transition_test.dart` "a cropped image covers its flight rect; both sides keep pace"; `test/settings_test.dart` "a recent cover flies to its work and back, an unseen one not"
- **Code:** `lib/app/motion/hero_transition.dart`

### TRANS-12 Only the viewer's entry page flies back
- **Rule:** The viewer carries a Hero only on the page it opened on. After a
  page turn a drag-to-dismiss slides the stage down; back and the back
  gesture fade the viewer out (TRANS-09).
- **Why:** Shrinking into the card showed a different page landing on it.
- **Check:** `test/hero_transition_test.dart` "only the entry page flies back; a drag from another page "
- **Code:** `lib/features/illust/viewer/image_viewer_page.dart`

### TRANS-13 The detail image list has one sliver type
- **Rule:** The detail page builds its image pages as one `SliverList`
  whatever the page count.
- **Why:** A sliver type chosen by page count rebuilt the landing Hero when
  the payload disagreed with the snapshot, and the orphaned endpoint
  painted under the flight.
- **Check:** `test/hero_transition_test.dart` "mid-flight the detail endpoint paints no image of its own"
- **Code:** `lib/features/illust/detail/widgets/detail_image_pager.dart`

### TRANS-14 Drag-to-dismiss yields to controls that own their drag
- **Rule:** A control under `DragToDismiss` that owns every drag direction
  (the page scrubber) claims its pointers through `allowPointer`. Overlays
  that appear mid-drag go after the slider in its `Stack`.
- **Why:** A thumb drifting vertically lost the arena to the dismiss drag;
  an overlay inserted before the slider rebuilt it and killed the drag.
- **Check:** `test/hero_transition_test.dart` "drag-to-dismiss returns to origin when canceled"
- **Code:** `lib/app/motion/drag_to_dismiss.dart`

## Image hand-off

### TRANS-15 PixivImage owns every quality hand-off
- **Rule:** Artwork URL and quality changes go through `PixivImage`, which
  keeps the previous decoded frame until the new one is ready (gapless).
  Callers add no "ready" flag and never swap in a blank loading state.
- **Why:** Per-page ready flags flashed blank frames between qualities.
- **Check:** `test/pixiv_image_variants_test.dart` "quality handoff keeps an old decoded frame placeholder"
- **Code:** `lib/app/pixiv_image.dart`

### TRANS-16 Fade cold loads only
- **Rule:** A cold load fades the placeholder off an image painted at once
  (300 ms linear). An already-decoded target appears without a fade, and a
  reused feed slot showing another work swaps without a fade. Feed cards
  are keyed by scope and work id.
- **Why:** Fading both layers dipped to grey; fading a cached Hero target
  flashed white; a recycled slot dissolved one work into another across
  the grid.
- **Check:** `test/pixiv_image_variants_test.dart` "the same URL on a reused slot keeps the cold-load fade"
- **Code:** `lib/app/pixiv_image.dart`, `lib/app/widgets/feed/feed_grid.dart`

### TRANS-17 Decoded images survive backgrounding
- **Rule:** The app's binding keeps decoded frames on Android's
  `TRIM_MEMORY_UI_HIDDEN` and clears only live streams and `rootBundle`.
- **Why:** The stock binding cleared the image cache on every hide, and
  every artwork faded in again on resume.
- **Check:** manual
- **Code:** `lib/main.dart`

### TRANS-18 Pager neighbours paint a decode, never a load
- **Rule:** A pager page outside the build window paints the feed's
  existing decode (`PixivImage.decodedStandIn`) where the built page will
  draw it, or a bare surface. `findChildIndexCallback` maps pages by work
  id.
- **Why:** A stand-in at another position jumped on landing; index mapping
  rebuilt pages as other works when the list shifted.
- **Check:** `test/illust_detail_pager_test.dart` "a page landing mid-paging keeps the built detail pages"
- **Code:** `lib/features/illust/detail/illust_detail_pager_page.dart`

### TRANS-19 The viewer decodes a preview first, the whole file once zoomed
- **Rule:** A viewer page decodes at `ImageViewerPage.previewDecodeWidth`
  (twice the screen width) until it is zoomed to `fullDecodeScale` (1.5),
  then decodes the whole file and keeps it. Every page has a transition
  key, so the preview paints while the whole file decodes. The return
  Hero and `openImageViewer`'s preload use the page's decode width.
- **Why:** An original decoded whole is tens of megabytes and slow on a
  swipe; a return shuttle at another width decoded a second time.
- **Check:** `test/illust_detail_viewer_test.dart` "a page decodes a preview until zoomed, then the whole file", `test/hero_transition_test.dart` "the viewer leaves whole and square; the detail page answers mid-flight"
- **Code:** `lib/features/illust/viewer/image_viewer_page.dart`, `lib/app/navigation/routes.dart`

### TRANS-21 Every artwork flight checks its card end
- **Rule:** At its start the shared shuttle (`inspectHeroFlight`) checks
  the card end (the source of a push, the landing of a pop): live
  (TickerMode on), on its route's page (measured in the page, which may
  still be moving), and, pushed within 2 s of a card tap, overlapping
  the box `noteHeroCardOpened` took at the tap. A failure logs one entry
  (tag, direction, reasons, each end's route, navigator restoration id
  and box) to `HeroAnomalyLog`, newest first, the last 20 kept in
  preferences; with developer options unlocked a prompt says so. The
  frame probe page shows, copies and clears the log. A normal flight
  does only the comparisons.
- **Why:** A wrong flight showed on devices a few times a day and never
  on demand, so the user could not record one. Widget type names are
  obfuscated in release builds; route names and restoration ids are not.
- **Check:** `test/hero_transition_test.dart` "a flight from a card out of sight is logged, others not"
- **Code:** `lib/app/motion/hero_anomaly.dart`, `lib/core/debug/hero_anomaly_log.dart`, `lib/features/settings/pages/frame_probe_page.dart`
