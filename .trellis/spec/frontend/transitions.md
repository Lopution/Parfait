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
reviewed: 2026-10-12
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
- **Why:** User decision: shared axis and zoom were dropped; fade-through
  is for unrelated destinations, not pushes.
- **Check:** manual
- **Code:** `lib/app/navigation/func_page.dart`, `lib/app/motion/page_transitions.dart`

### TRANS-02 Slide uses the Cupertino widget, not its builder
- **Rule:** The slide style uses the `CupertinoPageTransition` widget with
  the app's own back-gesture driver, never
  `CupertinoPageTransitionsBuilder`.
- **Why:** The builder adds an iOS edge-swipe detector that steals
  horizontal drags from the detail pager.
- **Check:** `test/func_page_test.dart` "the back gesture drives the route and commits" "cancelling the gesture restores the route"
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
  settled reveal paint one snapshot each.
- **Why:** Re-rendering the leaving page every frame dropped frames;
  freezing the entering page froze its entrances.
- **Check:** `test/func_page_test.dart` "the entering page stays live while a transition runs"
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

### TRANS-09 Shared-element pages fade over a still page
- **Rule:** A page opened with a Hero is `FuncPage(sharedElement: true)`:
  it fades over a page below that holds still, and the image is the only
  thing that moves. Do not refuse the transition (`canTransitionTo`
  false). On the back gesture the page shrinks to 0.9 with the finger
  instead of scrubbing, and a commit is a normal pop.
- **Why:** Sliding pages under a flight read as two animations. Refusing
  the transition stopped the secondary animation, so the bottom bar
  appeared over the leaving page. Heroes cannot follow a scrubbed pop.
- **Check:** `test/func_page_test.dart` "a shared-element page answers the back gesture by shrinking"
- **Code:** `lib/app/navigation/func_page.dart`

### TRANS-10 The flight clip follows both pages' chrome
- **Rule:** Push and pop flights use a progress-aware global clip between
  the source and destination chrome boundaries. Ignore horizontal route
  transforms when computing it, and use a conservative chrome fallback
  when an endpoint is offstage. Tests inspect the render-time clip.
- **Why:** Artwork covered app bars and the bottom bar, or was cut hard on
  landing; slide transforms made the boundary empty.
- **Check:** `test/hero_transition_test.dart` "Hero pop flight is occluded by the chrome" "Hero push from a nested feed stays intact"
- **Code:** `lib/app/motion/hero_rect_clip.dart`

### TRANS-11 Card rounding lives inside the Hero child
- **Rule:** The card's corner clip (`IllustHeroCardFrame`) wraps the Hero
  child, and feed cards draw no outline. A top-cropped card hands its
  `cropAspect` to the flight, which lays the image out full width and
  top-aligned for the whole flight.
- **Why:** A clip outside the Hero snapped from square to rounded on pop;
  fitting the image inside the rect mid-flight read as a second shrink.
- **Check:** `test/hero_transition_test.dart` "a cropped long image fills the flight rect width throughout"
- **Code:** `lib/app/widgets/feed/illust_card.dart`, `lib/app/motion/hero_transition.dart`

### TRANS-12 Only the viewer's entry page flies back
- **Rule:** The viewer carries a Hero only on the page it opened on. After a
  page turn every pop slides the stage away instead.
- **Why:** Shrinking into the card showed a different page landing on it.
- **Check:** `test/hero_transition_test.dart` "only the entry page flies back; other pages slide away"
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
