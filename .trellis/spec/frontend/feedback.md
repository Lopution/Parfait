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
  - lib/app/widgets/comment_composer.dart
reviewed: 2026-10-17
---

# Menus, overlays, prompts, undo and haptics

## Contents

- [Menus and overlays](#menus-and-overlays)
- [Prompts](#prompts)
- [Undo](#undo)
- [Haptics](#haptics)
- [Late callbacks](#late-callbacks)

## Menus and overlays

### FB-01 Menus are AppMenuButton
- **Rule:** Overflow and choice menus use `AppMenuButton` / `AppMenuEntry`,
  never `PopupMenuButton`. A touch outside closes the menu and is consumed;
  back closes the menu before the page. The panel keeps
  `crossAxisUnconstrained: false` so long labels truncate inside the width
  cap. A menu keeps `FuncSpacing.sm` off the side of the screen it lines
  up at (a ⋮ at the screen edge); an anchor further in (a settings row)
  keeps the menu lined up with it.
- **Why:** The closing touch scrolled or tapped the page below; labels
  overflowed the cap and were clipped; an end-edge menu touched the screen
  edge.
- **Check:** `test/app_menu_button_test.dart` "the closing touch never scrolls the page below" "back closes the menu before the page" "an end-edge menu keeps off the screen edge it opens at"
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
  A long press is a shortcut, never the only way: the detail page's ⋮
  carries the card sheet's actions and the heart's bookmark sheet, and a
  profile's ⋮ mutes or unmutes its user.
- **Why:** Duplicate entries made users unsure which control acted. Watch
  later, the mutes and tagged bookmarks were reachable only by a long
  press nothing on screen hinted at.
- **Check:** `test/illust_detail_actions_test.dart` "the ⋮ menu carries the long-press actions too", `test/user_profile_test.dart` "someone else's overflow mutes them, then offers the unmute"
- **Code:** `lib/app/widgets/card_actions`

## Prompts

### FB-04 Every prompt goes through PromptHost
- **Rule:** Transient messages use `showAppSnackBar` (errors:
  `showErrorSnackBar`). `SnackBar`, `SnackBarAction`, `showSnackBar` and
  `ScaffoldMessenger` do not appear in `lib/`; direct `PromptHost` access is
  pinned to a few files. Feedback that lands after an await takes its
  host first through `deferAppSnackBar` (errors: `deferErrorSnackBar`).
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
  `PromptAnchor` so prompts rest above it. A prompt whose message stops
  being true before its dwell ends takes itself down through the callback
  `showAppSnackBar` returns (the exit hint, NAV-03).
- **Why:** Prompts died with their page; action prompts stayed forever for
  users of always-on accessibility services. The dwell runs past the
  entrance and the platform timeout, so it cannot time a window.
- **Check:** `test/prompt_host_test.dart` "touch exploration pins only the action prompt" "ordered prompts show one after another", `test/navigation_router_test.dart` "a second back at the start exits"
- **Code:** `lib/app/widgets/prompt_host.dart`, `lib/app/widgets/prompt_anchor.dart`

## Undo

### FB-06 Reversible actions act at once and offer Undo
- **Rule:** Reversible actions (unfollow, unmute, watch-later removal,
  batch removals) run immediately and offer Undo through
  `showUndoSnackBar`; only irreversible ones (deleting a file, clearing
  history, cancelling downloads) confirm first. Unbookmark offers no Undo:
  tapping the heart again is the undo. A mute offers no Undo either, the
  same entry now unmutes; it confirms with a plain prompt, since the
  detail page and a profile do not change otherwise.
- **Why:** User decision, following Shaft. A mute from the detail page
  or a profile gave no sign it had landed.
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
  The failure's prompt comes from whoever sent the request (the entries,
  the sheets, Undo), read before it (FB-15); the buttons do not listen
  for the entry's error.
- **Why:** Those entries own the undo snapshot, the haptic and the error
  prompt; direct calls skipped them. A follow played `select` while a
  bookmark played `success` for the same kind of moment. The buttons'
  error listeners said nothing once a scroll or a refresh had taken the
  button, and the bookmark sheet's failure showed twice (10-31).
- **Check:** `test/follow_switch_button_test.dart` "a follow pops the button with success" "the sheet offers direct actions for each follow state", `test/bookmark_switch_button_test.dart` "a failed add says why, also once its heart is gone" "failed confirm keeps the sheet open and preserves the draft"
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

## Late callbacks

### FB-15 A callback that outlives its widget stays inside its owner
- **Rule:** An async callback reads the stores, actions, prompt host and
  texts it needs before its first await (`deferAppSnackBar`,
  `deferErrorSnackBar`, `deferCommentSendError`). After the await it touches the widget only
  if `mounted`, pops a sheet only while its route `isCurrent`, and acts
  only while the account boundary it read (`BookmarkStore.boundaryToken`,
  `CommentDrafts.owner`) is still the same object. A save queued behind
  other account writes asks once more before writing
  (`upsertAccount(stillWanted:)`). Independent cleanups each get their
  own `try` and their own error. A sheet whose opener can go while it is
  open (a card under a refresh) runs its actions on the opener's
  Navigator once the opener is gone (`showCardActionSheet`,
  `showFollowActionsSheet`).
- **Why:** A login left during the token exchange or its queued save
  signed in anyway or touched the gone page; a batch cancel and a
  Doubao sign-out ending after their page closed used a disposed context;
  a bookmark sheet closed mid-submit popped the page under it, since a
  closed sheet stays mounted while it animates out; a comment error was
  lost with the composer, and its draft landed in the next account; a
  failed account removal was lost with its page, and a failed watch-later
  save with its card. One failed cleanup skipped the next. A card action
  picked after a refresh had taken the card threw on the card's context
  and did nothing; a follow pick was dropped with its button (10-31).
- **Check:** `test/login_navigation_test.dart` "leaving during the token exchange drops its outcome", `test/download_tasks_page_test.dart` "a batch cancel ending after the page left is quiet", `test/bookmark_switch_button_test.dart` "a submit outlives its sheet but not its account", `test/comments_replies_test.dart` "a send ending after the detail composer left still lands", `test/settings_test.dart` "signing out of Doubao clears the session and its cookies", `test/account_settings_page_test.dart` "a removal that fails after its page closed is reported", `test/error_details_test.dart` "a settings write that fails after its page closed is reported", `test/card_action_test.dart` "a watch-later save that fails after its card is gone says so", `test/follow_switch_button_test.dart` "the sheet offers direct actions for each follow state", `test/watchlater_page_test.dart` "a removal that fails brings the works back and says so"
- **Code:** `lib/app/widgets/bookmark_switch_button.dart`, `lib/app/widgets/comment_composer.dart`, `lib/features/settings/pages/account_settings_page.dart`, `lib/app/widgets/settings/persist_settings.dart`, `lib/app/widgets/card_actions/illust_card_actions.dart`, `lib/app/widgets/card_actions/card_action_sheet.dart`, `lib/app/widgets/follow_switch_button.dart`, `lib/features/watchlater/watchlater_page.dart`
