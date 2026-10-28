---
prefix: PAGE
applies_to:
  - lib/features/profile/**
  - lib/features/search/**
  - lib/features/ranking/**
  - lib/features/comments/**
  - lib/features/settings/pages/download_tasks_page.dart
  - lib/features/settings/pages/muted_items_page.dart
  - lib/features/history/**
  - lib/features/watchlater/**
  - lib/features/spotlight/**
  - lib/app/widgets/author_row.dart
  - lib/app/widgets/expandable_text.dart
  - lib/app/widgets/inline_translation.dart
  - lib/app/widgets/selectable_tile.dart
  - lib/app/widgets/sliver_surface_list.dart
  - lib/app/layout/card_columns.dart
  - lib/app/layout/content_widths.dart
  - lib/app/widgets/scrollable_form_shell.dart
  - lib/app/scroll_behavior.dart
reviewed: 2026-10-17
---

# Page-specific rules

## Contents

- [Profile](#profile)
- [Discovery](#discovery)
- [Shared page pieces](#shared-page-pieces)
- [Library and management lists](#library-and-management-lists)
- [Wide and short windows](#wide-and-short-windows)

## Profile

### PAGE-01 Profile tabs list only the work types a user has
- **Rule:** The profile has one tab per work type with a count above zero
  (illust, manga, novel, illust series), labelled with the name alone.
  Each work list starts with its total. A preview snapshot without counters
  keeps all four tabs; a tab that disappears on refresh falls back to the
  first.
- **Why:** Counts in labels widened the row past an equal share and
  flipped it to scrolling once the detail loaded.
- **Check:** `test/user_profile_test.dart` "work tabs follow the types a user has; each list shows its" "a profile without works opens on its first other tab" "a tab that disappears on refresh falls back to the first"
- **Code:** `lib/features/profile/user_page.dart`

### PAGE-02 Header controls stay mounted through the collapse
- **Rule:** Back and overflow sit on the header's topmost layer and stay
  mounted and tappable through the whole collapse, including the hand-off
  between expanded and collapsed chrome.
- **Why:** The back button vanished during the hand-off and the pop
  animation.
- **Check:** `test/user_profile_test.dart` "header back button stays mounted through the pop animation"
- **Code:** `lib/features/profile/profile_header_delegate.dart`

## Discovery

### PAGE-03 A ranking date is part of the feed identity
- **Rule:** A past ranking is the `date=yyyy-MM-dd` query parameter; a
  missing, malformed or out-of-range date opens the latest. The picker
  stops at yesterday in Japan. The family key is `(mode, date)` and a
  cursor from another day is rejected. Only the latest ranking writes the
  cold-start snapshot.
- **Why:** Rankings publish in Japan time; a past day overwriting the
  snapshot showed old rankings on the next launch.
- **Check:** `test/ranking_feed_test.dart` "a cursor from another day is rejected" "only the latest ranking writes the cold-start snapshot" "the picker stops at yesterday in Japan"
- **Code:** `lib/features/ranking`

### PAGE-04 Search result types keep their own filters
- **Rule:** A result type switch replaces the route with the new type's
  query. The page holds one filter draft per work type for the search,
  seeded from the saved defaults; a user query carries no filters.
- **Why:** Switching illustration → user → illustration lost the
  illustration filters.
- **Check:** `test/search_result_page_test.dart` "each type switches to its own session filter set" "a user result route ignores stray filter params"
- **Code:** `lib/features/search/search_result_page.dart`

### PAGE-21 Search input completes the keyword at the caret
- **Rule:** Half- and full-width spaces split a query into keywords.
  Autocomplete asks only for the keyword at the caret, without an
  exclusion `-`, and nothing right after a space; suggestions already in
  the query are hidden. A tap replaces that keyword and searches the
  whole query; ↖ or a long press replaces it and adds a space. The field
  stays plain text: keywords a space has closed are painted as pills
  behind it, and the result page's field button paints every keyword.
- **Why:** Completing the whole string made a second keyword impossible
  (user feedback). User decision: plain text with painted pills, not
  chip widgets, whose extra states and gestures were too complex. pixiv's
  web search completes the last word the same way.
- **Check:** `test/search_input_test.dart` "suggestions complete the keyword at the caret" "a suggestion replaces the keyword, keeping its minus"
- **Code:** `lib/core/search/search_keywords.dart`, `lib/features/search/search_keyword_pills.dart`

### PAGE-05 Work strips omit hidden works
- **Rule:** A recommended user's preview strip shows up to three works,
  and the detail page's author strip the author's other works. Works
  hidden by the local R-18/AI blocks or a mute are left out, never shown
  blurred; a user with no visible works shows no strip. A malformed
  preview payload fails the page.
- **Why:** Blurred previews still exposed hidden content in a strip the
  user did not open; silently dropped payloads hid parser bugs. The
  author strip drew muted works clear and opened them.
- **Check:** `test/recommended_home_test.dart` "shows previews, skipping blocked and muted works"; `test/illust_detail_actions_test.dart` "the author strip leaves this work and muted ones out and "
- **Code:** `lib/features/home`, `lib/features/illust/detail/author_works_section.dart`

### PAGE-06 The Spotlight cover comes from the list entry
- **Rule:** The article cover uses the list entry's pximg `thumbnailUrl`;
  only a deep-linked article without a list entry falls back to the
  page's own cover.
- **Why:** The page's cover is an embed.pixiv.net card generated behind
  Cloudflare outside the network policy; it failed intermittently on
  device.
- **Check:** `test/spotlight_article_test.dart` "the cover comes from the list entry on pximg"
- **Code:** `lib/features/spotlight/spotlight_article_page.dart`

### PAGE-15 Ranking tabs are the user's categories minus the local block
- **Rule:** Both ranking pages show the saved category arrangement minus
  the local R-18 (with R-18G) and AI blocks, through one `RankingTabs`. A
  route to a hidden category shows it first for that visit without saving
  it; an edit keeps the category on screen or lands on its neighbour, and
  the category sheet lists the page's live tabs. A page off screen writes
  the new category into its route only once it shows again. The last
  category viewed is saved when the app is hidden or the page closes,
  never on each switch.
- **Why:** User decision: 33 categories are too many to show at once, so
  the user picks and orders them. An edit from the settings branch made
  the background page replace the route and pulled the user back to the
  ranking. Every settings write rebuilds the app root and its theme, so a
  write per tab switch costs a frame on every switch.
- **Check:** `test/ranking_categories_test.dart` "a hidden route category goes first; a blocked one does not" `test/ranking_feed_test.dart` "an edit updates the tabs, keeps the category and saves" "an edit made from another branch waits to write the route" "a ranking opened without a mode lands on the last one" `test/tab_swipe_switcher_test.dart` "a new tab list drops the spring-back of the old one"
- **Code:** `lib/features/ranking/ranking_tabs.dart`, `lib/core/ranking`

## Shared page pieces

### PAGE-07 An author link is the whole row or the whole card
- **Rule:** A byline inside a header (a series, a pixivision work) is
  `AuthorRow`: the avatar, the name and a chevron right after the name
  are one target of at least 48dp announced as one button; the chevron
  is what shows it can be tapped. A person that stands as its own block
  (the detail page's author, the novel info sheet's author, the Me tab's
  account header) is a `PersonCard`: the whole card is that target, with
  a hint saying where it goes, and the card shows it can be tapped. A
  trailing button (follow, manage) is a separate target. Never make only
  the name tappable. Inside any other card the card is the target and
  the byline stays plain. On a sheet, already the card tier, the card
  takes the next tier. Under a name, an account always reads "@account".
- **Why:** Name-only links were too small to hit. A whole-row target with
  no edge looked like plain text (user report, 10-25).
- **Check:** `test/author_row_test.dart` "the whole row is one 48dp target that opens the profile" "a person card is one target; its trailing button is its own"
- **Code:** `lib/app/widgets/author_row.dart`, `lib/app/widgets/person_card.dart`

### PAGE-20 Pages carry no explanatory notes
- **Rule:** No page, group, sheet or empty state carries a note on how
  to use it, where its content comes from or how it works inside: no
  group footer of that kind, no line under an empty state's title, no
  paragraph by a button. Text under a title is a state (an error's
  category, a setting that is off, "nothing muted yet") or what an
  option does (a switch's or a choice's subtitle); a confirmation keeps
  the consequences it asks about, and an action that exposes a
  credential keeps its risk note. Developer pages and help the user
  opens are exempt.
- **Why:** User decision (10-25): the notes read as secondary headings
  written as annotations. The Doubao risk paragraph went with them.
- **Check:** `test/muted_items_page_test.dart` "an empty group says it is empty, off the cards"; `test/history_page_test.dart` "an empty history with recording off offers to turn it on"
- **Code:** `lib/features/settings/`, `lib/app/widgets/feed/feed_states.dart`

### PAGE-08 Long user text uses ExpandableText
- **Rule:** Captions and descriptions use `ExpandableText`; text that fits
  shows no toggle, and links stay tappable while collapsed. Collapsed,
  "Show more" ends the last line, which fades out before it, and a tap
  anywhere on the text expands it; the text is one node with an expanded
  state. Expanded, "Show less" sits under the text. The fade masks the
  text itself, never a painted ground, so it works on any surface.
- **Why:** Hand-rolled folds showed a toggle on short text and broke
  links. A toggle on its own line under the text cost a line and was the
  only target (user decision 10-25).
- **Check:** `test/expandable_text_test.dart` "long text collapses to maxLines and expands on demand" "a link stays tappable while collapsed"
- **Code:** `lib/app/widgets/expandable_text.dart`

### PAGE-09 Translations are transient and share one entry
- **Rule:** Every "translate this text" entry uses `InlineTranslation` and
  `TranslationPanel`. Entries: the caption heading (or title) on the
  detail page, the novel info sheet title, the user introduction, the
  comment translate pill, the tag actions sheet, and the novel reader's bilingual
  mode. A setup failure offers a button to translation settings;
  translation turned off or not configured reads as a notice, not in the
  error colour. After a failure the entry keeps its "translate" label and
  tapping it tries again.
  Translations are never persisted and never replace the original.
- **Why:** User decision, following Shaft. The tag sheet's entry read
  "hide translation" with nothing shown, and an unset service looked like
  a fault.
- **Check:** `test/illust_detail_actions_test.dart` "translate answers inside the menu, or points to settings", `test/comment_item_test.dart` "translate is disabled while a translation runs"
- **Code:** `lib/app/widgets/inline_translation.dart`

### PAGE-10 Comment actions are pills; only delete hides behind ⋮
- **Rule:** Reply, "view N replies" and translate are pill `TextButton`s
  (32dp tall, 48dp target) in a `Wrap` under the body. Only the viewer's
  own comment gets a ⋮ `AppMenuButton`, at the end of that row, holding
  delete in the danger colour. The header holds the name (`labelLarge`,
  as in the detail page's preview) and the date, which ends on the row's
  edge on every comment.
- **Why:** User decision. A ⋮ beside the date opened on a lone translate
  item for other people's comments and pushed their dates off the edge
  that comments without one used. An `OverflowBar` stacked all pills
  once one label did not fit.
- **Check:** `test/comment_item_test.dart` "own comment: the ⋮ only deletes, in danger color" "another user's comment has no ⋮"
- **Code:** `lib/features/comments/comment_item.dart`

### PAGE-19 Composer panels rise and fall like the keyboard
- **Rule:** The emoji and stamp panels share the composer's bottom slot
  with the keyboard, and the slot is the composer's one bottom budget: the
  keyboard's inset, else the navigation bar's under a resting row, else a
  panel as tall as the keyboard with the navigation bar, so the input row
  holds still as they swap. The keyboard's height is the tallest inset of
  a stretch of focus, kept per orientation and width across restarts
  (`KeyboardHeights`, 160dp up to 60% of the screen; an inset outside
  that sizes nothing); 280dp over the navigation bar stands in before
  any. A panel rises and folds on the
  sheet spring, top edge first, and stays built offstage once opened;
  one replacing the keyboard starts at the keyboard's height. A panel
  giving way to the keyboard holds its height until the keyboard has
  risen over it, or 600ms pass. Emoji ↔ stamp swaps through `StateFade`.
  Reduced motion jumps to the end. A composer given `onGone` has no
  resting row: it stands on the surface alone and goes with it
  (DETAIL-17).
- **Why:** The panel popped in and out, and the input row dropped to the
  bottom and climbed back with every switch to the keyboard. User report
  (10-21): a panel opened before the keyboard stood 280dp tall, and over
  the navigation bar it stood a bar higher than the keyboard.
- **Check:** `test/comments_replies_test.dart` "the panel rises on a spring and waits for the keyboard" "composer reserves the sampled keyboard height for panels" "panels stand exactly where the keyboard stood" "keyboard heights persist per screen shape"
- **Code:** `lib/app/widgets/comment_composer.dart`, `lib/core/settings/keyboard_heights.dart`

## Library and management lists

### PAGE-11 Batch selection starts from a "manage" text button
- **Rule:** A list with batch removal enters selection through a "manage"
  `TextButton`, shown only when the list has entries. Bulk removals with
  no selection (clear history, clear completed downloads) are named
  entries in the bar's ⋮, disabled while there is nothing to remove, so
  "manage" never shifts. Selection swaps the bar for `selectionAppBar`;
  back leaves selection before the page. Grid entries use
  `SelectableTile`.
- **Why:** An icon alone was unreadable in testing.
- **Check:** `test/history_page_test.dart` "system back exits selection mode instead of popping"
- **Code:** `lib/app/widgets/selectable_tile.dart`, `lib/app/widgets/selection_app_bar.dart`

### PAGE-12 Removals return what Undo needs to restore positions
- **Rule:** Removing never asks first: entries play their exit, the store
  removes them in one write, and Undo puts them back in their old places.
  `DownloadManager.dismissAll` removes finished task records (never files)
  and `restore` re-inserts each at its old index, rebuilding emptied
  groups. `WatchLaterStore.removeAll`/`restoreAll` restore nothing once
  another account is current. Batch cancel still confirms.
- **Why:** Undo that appended entries at the end, or restored into another
  account, lost the user's order or leaked data.
- **Check:** `test/download_tasks_page_test.dart` "clear completed leaves failures and is undone in place" "removing a finished group is undone with its header", `test/watch_later_store_test.dart` "removeAll is undone in the old order" "undo after an account switch restores nothing"
- **Code:** `lib/core/download`, `lib/core/watchlater`

### PAGE-13 Muted works are blurred and keep old backups readable
- **Rule:** The muted items page shows muted works with a blurred
  thumbnail. `MutedWork.fromJson` also reads the earlier bare ids, and a
  backup import fills missing titles and thumbnails without counting a
  mute change.
- **Why:** The user hid those works; older stores and backups held bare
  ids.
- **Check:** `test/mute_store_test.dart` "work mutes stored as bare ids still load"
- **Code:** `lib/features/settings/pages/muted_items_page.dart`, `lib/core/mute`

### PAGE-14 Management lists are lazy rows on one surface per group
- **Rule:** A management list is one flat lazy list keyed by task or
  group id, the newest submission first, groups among the single items
  (a group by its own submission, its rows in page order). A group's
  rows share one `SliverSurfaceList` surface, a single item sits on none;
  never split a group into its own slivers or reparent rows with
  `GlobalKey`s. Progress bars show only on
  unfinished rows. A group of one is a plain row. A row's action buttons
  stand on its title row while its text keeps 160dp; only a narrower row
  moves them to a line of their own. The actions end the row, so a
  group's line up with its rows', its expand icon just before them.
- **Why:** Eager lists built hundreds of rows; reparented rows dropped
  their ink and showed square corners mid-animation. On every phone a
  lone remove button took a line of its own under the row. A group's
  remove button stood one icon left of its rows'. Oldest first, with the
  groups all above the single items, put a new download at the bottom
  (user report).
- **Check:** `test/download_tasks_page_test.dart` "a five-hundred-item list only builds the visible rows" "a group of one is a plain task row" "the newest submission comes first, groups among tasks" "on a phone a finished row keeps remove on its title row" "a collapsed group expands on tap and folds its children in"
- **Code:** `lib/features/settings/pages/download_tasks_page.dart`, `lib/app/widgets/sliver_surface_list.dart`

## Wide and short windows

### PAGE-16 Card lists add columns; text lists stop growing
- **Rule:** Lists of novel, user and series-episode cards lay out through
  `SliverCardList` (or `CardRow` in a `ListView`): a column per 400dp of
  the list's own width, at most three. Text lists (comments and their
  composer, search suggestions, bookmark tags, a profile's About tab) sit
  in `ContentWidthCap` at `ContentWidths.management`; the search field
  stops at the same width; the reverse image search flow at
  `ContentWidths.form`, its engine pages full width.
- **Why:** On wide windows a single row ran the name at one edge and its
  button or date at the other; the comment field was 1300dp wide.
- **Check:** `test/responsive_layout_test.dart` "card lists take a column per 400dp, at most three" "a wide card list puts neighbouring cards side by side" "a capped column centres at its width on a wide window"
- **Code:** `lib/app/layout/card_columns.dart`, `lib/app/layout/content_widths.dart`

### PAGE-17 Short windows keep the primary action and the tab body
- **Rule:** Below 480dp tall and from 600dp wide, `ScrollableFormShell`
  (welcome, language, login) puts the header beside the form so the
  primary action is on the first screen. A profile tab is laid out at
  least 160dp tall and clipped to what the expanded header leaves, with
  the same tree at every height.
- **Why:** On a phone held sideways the start and login buttons sat below
  the fold, and the profile's works-total row overflowed a 16dp strip.
- **Check:** `test/onboarding_pages_test.dart` "a phone held sideways shows the welcome action at once"; `test/user_profile_test.dart` "a phone held sideways lays the tab out under the header"
- **Code:** `lib/app/widgets/scrollable_form_shell.dart`, `lib/features/profile/user_page.dart`

### PAGE-18 A mouse gets right-click, hover and scrollbars
- **Rule:** Wherever a long press acts (work cards, novel and user rows,
  tags, history and selection tiles, detail images, the bookmark heart,
  download tasks, search history and trending tags, ranking tabs), a
  right-click does the same through `onSecondaryTap`. A work card shows
  the M3 hover state layer and a click cursor (`InkWell` rows have their
  own). While a mouse is connected, vertical lists show a `Scrollbar`
  (`mouseScrollbar`, also in EasyRefresh feeds); NestedScrollView's
  coordinated views stay bare, and the list keeps its subtree when the
  scrollbar comes or goes.
- **Why:** On a tablet or Chromebook with a mouse a long press is
  awkward, cards gave no sign they open, and a wheel gives no sense of a
  list's length.
- **Check:** `test/card_action_test.dart` "a mouse lights the card on hover and opens it on right-click"; `test/scroll_behavior_test.dart` "a mouse brings a scrollbar and keeps the list as it was"
- **Code:** `lib/app/scroll_behavior.dart`, `lib/app/pull_to_refresh.dart`, `lib/app/widgets/feed/illust_card.dart`
