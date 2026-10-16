---
prefix: FB
applies_to:
  - lib/app/widgets/app_menu_button.dart
  - lib/app/widgets/prompt_*.dart
  - lib/app/widgets/app_snack_bar.dart
  - lib/app/widgets/undo_snack_bar.dart
  - lib/app/widgets/unmute_undo.dart
  - lib/app/widgets/card_actions/**
  - lib/app/motion/app_overlays.dart
  - lib/app/haptics/**
  - lib/app/clipboard.dart
  - lib/app/widgets/bookmark_switch_button.dart
  - lib/app/widgets/follow_switch_button.dart
  - lib/app/widgets/watchlist_toggle.dart
reviewed: 2026-10-16
---

# Menus, overlays, prompts, undo and haptics

## Contents

- [Menus and overlays](#menus-and-overlays)
- [Prompts](#prompts)
- [Undo](#undo)
- [Haptics](#haptics)

## Menus and overlays

### FB-01 Menus are AppMenuButton
- **Rule:** Overflow and choice menus use `AppMenuButton` / `AppMenuEntry`,
  never `PopupMenuButton`. A touch outside closes the menu and is consumed;
  back closes the menu before the page. The panel keeps
  `crossAxisUnconstrained: false` so long labels truncate inside the width
  cap.
- **Why:** The closing touch scrolled or tapped the page below; labels
  overflowed the cap and were clipped.
- **Check:** `test/app_menu_button_test.dart` "the closing touch never scrolls the page below" "back closes the menu before the page"
- **Code:** `lib/app/widgets/app_menu_button.dart`

### FB-02 Dialogs and sheets go through app_overlays.dart
- **Rule:** Dialogs and bottom sheets open through `showAppDialog` /
  `showAppBottomSheet`. Their barrier replaces the stock one and closes the
  route when a touch that started on the scrim is released on the scrim,
  tap or drag.
- **Why:** Wrapping the stock barrier popped twice and closed the page
  below; native Android dialogs close on a drag released outside.
- **Check:** `test/architecture/feedback_channels_test.dart` "app modal overlays funnel through app_overlays.dart", `test/app_overlays_test.dart` "a drag outside closes it on release, one layer only"
- **Code:** `lib/app/motion/app_overlays.dart`

### FB-03 Each action appears once at a time
- **Rule:** A menu or sheet lists only actions not already on screen. A
  row's secondary actions open from a ⋮ `AppMenuButton` on the row, not a
  one-entry sheet. The card long-press sheet names its subject (thumbnail,
  title, author) and has no bookmark entry, since every card has a heart.
- **Why:** Duplicate entries made users unsure which control acted.
- **Check:** manual
- **Code:** `lib/app/widgets/card_actions`

## Prompts

### FB-04 Every prompt goes through PromptHost
- **Rule:** Transient messages use `showAppSnackBar` (errors:
  `showErrorSnackBar`). `SnackBar`, `SnackBarAction`, `showSnackBar` and
  `ScaffoldMessenger` do not appear in `lib/`; direct `PromptHost` access is
  pinned to a few files.
- **Why:** The Scaffold path anchored to geometry the floating shell bar
  does not have and read the polluted accessibility flag.
- **Check:** `test/architecture/feedback_channels_test.dart` "prompts have exactly one host"
- **Code:** `lib/app/widgets/prompt_host.dart`, `lib/app/widgets/app_snack_bar.dart`

### FB-05 Prompt lifetime, dwell and placement
- **Rule:** A prompt belongs to the host and survives push, pop and branch
  switches. A new prompt replaces the current one unless it passes
  `replaceCurrent: false` (ordered steps). The dwell starts after the
  entrance and goes through the platform's recommended timeout; an action
  pins the prompt only under touch exploration. Chrome registers a
  `PromptAnchor` so prompts rest above it.
- **Why:** Prompts died with their page; action prompts stayed forever for
  users of always-on accessibility services.
- **Check:** `test/prompt_host_test.dart` "touch exploration pins only the action prompt" "ordered prompts show one after another"
- **Code:** `lib/app/widgets/prompt_host.dart`, `lib/app/widgets/prompt_anchor.dart`

## Undo

### FB-06 Reversible actions act at once and offer Undo
- **Rule:** Reversible actions (unfollow, unmute, watch-later removal,
  batch removals) run immediately and offer Undo through
  `showUndoSnackBar`; only irreversible ones (deleting a file, clearing
  history, cancelling downloads) confirm first. Unbookmark offers no Undo:
  tapping the heart again is the undo.
- **Why:** User decision, following Shaft.
- **Check:** `test/undo_flows_test.dart` "a removed bookmark offers no Undo; the heart brings it back"
- **Code:** `lib/app/widgets/undo_snack_bar.dart`

### FB-07 Undo restores exactly or not at all
- **Rule:** Undo re-adds with the original visibility and tags. When those
  are unknown (lookup failed, offline queue, failed delete), the removal
  still happens but no Undo is offered. Never guess "public".
- **Why:** Restoring a private bookmark or follow as public would expose it.
- **Check:** `test/undo_flows_test.dart` "a private follow comes back private" "without the original visibility there is no Undo"
- **Code:** `lib/core/bookmark`, `lib/core/user`

### FB-08 Undo outlives its page
- **Rule:** `showUndoSnackBar` captures the `ProviderContainer`, prompt host
  and localizations when it shows; `onUndo` receives the container. Read
  stores and actions before awaiting anything.
- **Why:** Undo pressed after the page closed used a disposed context.
- **Check:** `test/undo_flows_test.dart`
- **Code:** `lib/app/widgets/undo_snack_bar.dart`

### FB-09 Bookmark and follow have one UI entry each
- **Rule:** UI code toggles bookmarks through `toggleBookmark` and follows
  through `toggleFollowWithUndo`, never through the action providers
  directly. Both play their haptic on the tap, as the state flips:
  adding plays `success`, removing `select`, a failure adds `error`.
- **Why:** Those entries own the undo snapshot, the haptic and the error
  prompt; direct calls skipped them. A follow played `select` while a
  bookmark played `success` for the same kind of moment.
- **Check:** `test/follow_switch_button_test.dart` "a follow pops the button with success"
- **Code:** `lib/app/widgets/bookmark_switch_button.dart`, `lib/app/widgets/follow_switch_button.dart`

## Haptics

### FB-10 Vibrate only for a state change the user caused
- **Rule:** Haptics confirm a user-caused state change. Navigation (tabs,
  bottom bar, swipes, opening pages, back), high-frequency events (edges,
  zoom limits, drag frames) and background events (a download finishing,
  a queued action replaying) are silent. Every visual feedback is complete
  without haptics.
- **Why:** User decision; vibration for navigation and background events
  read as feedback for something else.
- **Check:** `test/architecture/feedback_channels_test.dart` "navigation chrome stays silent" "haptics have exactly one owner"
- **Code:** `lib/app/haptics/app_haptics.dart`

### FB-11 Callers name a role, not an effect
- **Rule:** Callers play an `AppHaptics` role (`select`, `toggleOn/Off`,
  `tick`, `thresholdOn/Off`, `longPress`, `confirm`, `success`, `error`).
  The role-to-effect table lives only in the Android `HapticPlanner.kt`. A
  new role needs a real caller and a planner row.
- **Why:** Effects chosen per call site felt different on every ROM.
- **Check:** `android/app/src/test/kotlin/io/github/lopution/parfait/HapticPlannerTest.kt`
- **Code:** `lib/app/haptics/app_haptics.dart`, `android/app/src/main/kotlin/io/github/lopution/parfait/HapticPlanner.kt`

### FB-12 Controls own their haptic
- **Rule:** Selection controls are used through their wrappers
  (`SettingsControl`, `ReplicaSwitchTile`, `SettingsChoiceTile`,
  `SettingsMenuTile`, `FilterMenuButton`, `AppChoiceChip`, `AppSlider`),
  which play the haptic for a user change only. A carrier with an app long
  press sets `enableFeedback: false` and plays `longPress` itself.
- **Why:** Raw controls were silent; Material's own long-press feedback
  doubled the app's.
- **Check:** `test/architecture/feedback_channels_test.dart` "selection controls live only in their haptic wrappers", `test/selection_controls_haptics_test.dart`
- **Code:** `lib/app/widgets/settings`, `lib/app/widgets/app_choice_chip.dart`

### FB-13 Store mutations vibrate on the settled outcome
- **Rule:** Bookmark, follow and watchlist call sites read the entry,
  await the action, read again, and play the role of what landed: silent
  for queued or cancelled, `error` for failure. Never `ref.listen` a store
  to vibrate.
- **Why:** A listener vibrated for replays landing later and once per
  button showing the same key.
- **Check:** manual
- **Code:** `lib/app/widgets/bookmark_switch_button.dart`, `lib/app/widgets/watchlist_toggle.dart`

### FB-14 Clipboard writes go through copyToClipboard
- **Rule:** UI code copies with `copyToClipboard(context, text, message:)`:
  write, `success` haptic, then the prompt.
- **Why:** Copies without confirmation looked like nothing happened.
- **Check:** `test/architecture/feedback_channels_test.dart` "UI clipboard writes go through copyToClipboard"
- **Code:** `lib/app/clipboard.dart`
