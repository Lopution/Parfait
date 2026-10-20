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
reviewed: 2026-10-19
---

# Page transitions, back gesture and Hero flights

## Contents

- [Page transitions and back](#page-transitions-and-back)
- [Hero flights](#hero-flights)
- [Image hand-off](#image-hand-off)

## Page transitions and back

### TRANS-01 Two transition styles, both official
- **Rule:** The page transition setting offers `system` (Android:
  `PredictiveBackPageTransitionsBuilder`) and `slide`
  (`CupertinoPageTransition`). A stored `sharedAxis` or `zoom` reads as
  `system`. Fade-through is not offered. No hand-written transition.
  Shared-element pages keep their own fade whatever the style (TRANS-09).
- **Why:** User decision: shared axis and zoom were dropped; fade-through
  is for unrelated destinations, not pushes.
- **Check:** manual
- **Code:** `lib/app/navigation/func_page.dart`, `lib/app/motion/page_transitions.dart`

### TRANS-02 Slide uses the Cupertino widget, not its builder
- **Rule:** The slide style uses the `CupertinoPageTransition` widget with
  the app's own back-gesture driver, never
  `CupertinoPageTransitionsBuilder`. A committed gesture finishes from
  where the finger left the page.
- **Why:** The builder adds an iOS edge-swipe detector that steals
  horizontal drags from the detail pager. The framework's commit rewinds
  the route to 1 first, so the page jumped back on release.
- **Check:** `test/func_page_test.dart` "the back gesture drives the route and commits" "a shared-element page fades over a still page"
- **Code:** `lib/app/navigation/func_page.dart`

### TRANS-03 Back uses PopScope.onPopInvokedWithResult
- **Rule:** Pages handle back with `PopScope.onPopInvokedWithResult`;
  `WillPopScope` is not used and `enableOnBackInvokedCallback` stays on. A
  page with unsaved edits reports a non-pop disposition, so the gesture
  never starts and the back button shows its discard confirmation.
- **Why:** Predictive back needs the callback model; a dirty page must not
  be swiped away.
- **Check:** manual
- **Code:** `lib/app/navigation/func_page.dart`, `lib/features/profile/profile_edit_page.dart`

### TRANS-04 Only the visible route takes the back gesture
- **Rule:** `popGestureEnabled` also requires
  `BranchActivityScope.active`: the branch is the settled current index
  and no root-level page covers the shell. Routes outside the shell have
  no scope and pass.
- **Why:** Parked branches keep an `isCurrent` route offstage; without the
  gate a hidden branch popped a page the user could not see.
- **Check:** `test/func_page_test.dart` "only the visible branch answers the back gesture" "a root-level page owns the gesture over the whole shell"
- **Code:** `lib/app/navigation/func_page.dart`, `lib/app/widgets/home_branch_stack.dart`

### TRANS-05 A failed gesture commit releases the Navigator
- **Rule:** If a pop throws after the route reported `didPop`, the guard
  ends the user gesture before rethrowing.
- **Why:** A lingering gesture made the Navigator absorb every later
  pointer.
- **Check:** `test/func_page_test.dart` "a throwing back-gesture commit releases the Navigator"
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

### TRANS-07 Hero tags are scoped per surface
- **Rule:** The only Hero tags are `illustHeroTag(scope, id)`. Each mounted
  surface uses its own stable scope, and the card and the detail route it
  opens share scope and id. A route without a matching source uses the
  normal transition; it never fakes a source.
- **Why:** The same work in two mounted feeds flew from the wrong card.
- **Check:** `test/architecture/feedback_channels_test.dart` "Hero uses only the shared illustHeroTag family"
- **Code:** `lib/app/motion/hero_transition.dart`

### TRANS-08 Opening a work never waits for the image
- **Rule:** A card may start `PixivImage.preload` on pointer down but pushes
  the detail route without awaiting it. The detail page's first frame
  renders from `initialEntity` and the card's preview URL, loaded through
  the same worker entry as the card.
- **Why:** Awaiting preload delayed every tap; a different first URL made
  the Hero start from a placeholder.
- **Check:** `test/hero_transition_test.dart` "feed → detail → viewer keeps one hero tag family"
- **Code:** `lib/app/widgets/feed/illust_card.dart`

### TRANS-09 Shared-element pages fade over a still page, whatever the style
- **Rule:** A page opened with a Hero is `FuncPage(sharedElement: true)`
  and has its own transition in both directions, whatever the style:
  `MotionTokens.sharedElement` (450ms), the page fading over a still
  page below (no slide, no barrier) in the first part of either
  direction (`sharedElementFadeIn` opening, `sharedElementFadeOut`
  leaving, chosen by the controller's direction; a leave that cuts an
  opening short fades out from the opacity the opening reached), the
  Hero flying on
  `MotionTokens.spatialCurve`, set on every artwork Hero end (a flight
  reads the curve of the page that opens or leaves). The
  back gesture scrubs the fade with the app's own driver, so every artwork
  Hero sets `transitionOnUserGestures`, and a committed gesture finishes
  from where the finger left it and ends the navigator's gesture at once.
  A leaving page takes no touch, so the page below answers while the
  image flies. While a landed page leaves,
  `HeroLiftHole` cuts the flying image's spot out of it, so the page below
  shows there, not the page's background; an opening page has no hole
  (it fades in over the page below anyway, and the image's slow last
  stretch left a line of that page around it). The viewer's endpoint
  (`IllustHeroFlightChild.containsImage`) cuts nothing: its stage fades
  out whole. Under a page pushed on top it moves in the
  style like any page. The transition's widget structure never changes
  over the route's life. A detail pager aims each settled work's back
  flight (`IllustPagerSource.aimHomeFlight`): a card with nothing on
  screen takes no flight. Do not refuse the transition (`canTransitionTo`
  false).
- **Why:** User decision, after trying the style's
  transitions: a slide or FadeForwards moves both ends of the flight while
  the image crosses between them, so the image arrived before its page
  and the hole showed a half-moved feed and the gap beside it. One fade
  curve played backwards held the leaving page until the image had
  nearly landed, and an emphasized flight curve read as odd.
  Shared-element transitions on Android, iOS (zoom) and in Flutter's
  Wonderous all keep the page below still and only fade the rest. The
  framework's gesture commit rewinds the route to 1 before reversing, so
  the page and the Hero jumped back on release. A changed transition
  widget type reparents the page's GlobalKey subtree and rebuilds the
  whole page in that frame. Hero pairs by tag alone, so a card built in
  the cache extent pulled the image in from off the screen. Refusing the
  transition stopped the secondary animation, so the bottom bar appeared
  over the leaving page. The page below ignored touches for the whole
  flight: the gesture flag stayed up until the landing, and FadeForwards'
  backdrop on the leaving page took every hit. A hole in the viewer read
  as a sharp-edged window that did not fade with the dark stage.
  Switching to the leave curve mid-opening dropped a half-shown page in
  one frame.
- **Check:** `test/func_page_test.dart` "a shared-element page fades over a still page"; `test/hero_transition_test.dart` "the viewer leaves whole and square; the detail page answers mid-flight"; `test/architecture/feedback_channels_test.dart` "Hero uses only the shared illustHeroTag family"; `test/illust_card_badges_test.dart` "the pager image flies back only to a card on screen"
- **Code:** `lib/app/navigation/func_page.dart`, `lib/app/motion/hero_transition.dart`, `lib/app/widgets/feed/feed_grid.dart`

### TRANS-10 The flight clip and chrome follow the page over the card
- **Rule:** Push and pop flights use a global clip between the source and
  destination chrome boundaries, interpolated by the opacity of the
  shared-element page over the card's route, or over the route holding
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
  landing; slide transforms made the boundary empty. The page fades over
  the first part of the flight while the image flies on, so a clip that
  followed the image left it over the tab row and the bottom bar of a
  feed already shown. A card opened again while its image flew home
  sends the flight to the new page but keeps the shuttle, built with the
  old route's animation, which stops: the clip and the corners froze at
  the card end and the tab row cut the image on the detail page. The
  shuttle is painted over every page, so chrome on the image was covered
  as a flight set off and popped back whole at the landing, and badges
  floated over the card's empty slot.
- **Check:** `test/hero_transition_test.dart` "Hero pop flight is occluded by the chrome" "Hero push from a nested feed stays intact" "chrome over a flight steps aside until the landing"
- **Code:** `lib/app/motion/hero_rect_clip.dart`, `lib/app/motion/hero_transition.dart`, `lib/app/navigation/func_page.dart`

### TRANS-11 Card rounding lives inside the Hero child
- **Rule:** The card's corner clip (`IllustHeroCardFrame`) wraps the Hero
  child, and feed cards draw no outline. Only a flight with a card end
  rounds its corners; detail ↔ viewer flies square. A card that shows
  only part of the image (the top of a taller one, the middle of a wider
  one) hands its `cropAspect` to the flight, which lays the image out
  covering the rect, top-aligned and centered across, for the whole
  flight. The card's share of the image stays opaque; the part the card
  hid paints past the rect at flight progress opacity, so the image only
  scales (user decision).
- **Why:** A clip outside the Hero snapped from square to rounded on pop;
  fitting the image inside the rect mid-flight read as a second shrink.
  A radius lerped by flight progress rounded the square detail ↔ viewer
  flight on its way. Clipping the image to the growing rect read as the
  image unrolling.
- **Check:** `test/hero_transition_test.dart` "a cropped image scales whole and fades in what the card hid"
- **Code:** `lib/app/widgets/feed/illust_card.dart`, `lib/features/settings/me_dashboard_page.dart`, `lib/app/motion/hero_transition.dart`

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
