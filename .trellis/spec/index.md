---
reviewed: 2026-10-12
---

# Spec

Rules an agent cannot learn from the code, the configuration or the tests,
and would get wrong without. Everything else stays out.

## Contents

- [How to read](#how-to-read)
- [Admission](#admission)
- [Rule format](#rule-format)
- [File format](#file-format)
- [Machine checks](#machine-checks)
- [Writing back](#writing-back)
- [Glossary](#glossary)

## How to read

- Each layer has an index: [frontend](./frontend/index.md) (`lib/app`,
  `lib/features`, `lib/l10n`), [backend](./backend/index.md) (`lib/core`,
  Android, the Rust plugin, release) and [guides](./guides/index.md)
  (architecture, code quality, tests). An index gives one line per file
  saying when to read it.
- `python3 tool/check_spec.py --for <path>...` lists the spec files whose
  `applies_to` covers the paths you are about to change. Read those, not
  whole layers.
- A rule marked "User decision" was chosen by the user. Do not reverse or
  "improve" it without asking.

## Admission

Add a rule only when all three hold:

1. The code, configuration, lint and existing tests do not already show it.
2. Without it an agent would make a wrong decision, and it comes from a real
   bug, failure or user decision. Cite that source in the PR description,
   not in the spec.
3. It has one interpretation.

Decide in this order, for new rules and for existing ones under review:

1. Visible in code or configuration → delete it.
2. Machine-checkable → write a test (see [Machine checks](#machine-checks));
   the spec keeps the rule ID, the reason and the test.
3. An agent would get it wrong → keep it, rewritten to one interpretation.
4. Anything else → delete it.

## Rule format

```markdown
### NAV-03 Back at a branch root returns to Recommended
- **Rule:** One or two sentences, stated as an observable outcome.
- **Why:** The bug or decision behind it, in one or two sentences.
- **Check:** `test/home_page_test.dart` "test name", or `manual`.
- **Code:** `lib/features/home/home_page.dart`
```

- IDs are `<PREFIX>-<NN>`; the prefix is the file's `prefix`. An ID is
  never reused: a deleted rule leaves a gap.
- **Check** names test files, optionally followed by quoted test names that
  appear in that file, or `manual` with a short reason.
- **Code** names files or directories (globs allowed) that implement it.
- Extra lines may follow the four fields: a table, a short list. No copied
  code. A code example of at most 10 lines is allowed only when the code
  base has no instance of the pattern to point at.
- No process records: no task names, dates, PR numbers, commit hashes, "was
  changed from X". A rule that no longer holds is deleted; history is in
  git.

## File format

```yaml
---
prefix: NAV
applies_to:
  - lib/app/navigation/**
reviewed: 2026-10-12
---
```

- One module per file, in the layer that owns the code. Aim for 300 lines;
  500 is the hard limit. A file over 100 lines starts with a `## Contents`
  list of its `##` sections.
- Index files carry only `reviewed`. An index links every file of its layer
  with a one-line "read when" summary. Spec files do not link each other;
  links go from an index to a file, one hop.
- Rules are grouped under `##` sections; each rule is a `###` heading.

## Machine checks

- A rule that can be checked by scanning source is a test under
  `test/architecture/`. Its failure message starts with the rule ID and says
  how to fix the code.
- Machine checks count against the test budget; keep them small.
- `tool/check_spec.py` checks the spec itself: line limits, frontmatter,
  `applies_to` globs, rule IDs and fields, referenced paths and test names,
  forbidden process records, index coverage, contents lists. CI runs it in
  the `analyze` job.
- Local modes: `--for <path>...` (which files to read), `--diff [base]`
  (spec files for the current branch's changes), `--tasks` (task context
  files point at existing paths).

## Writing back

At the end of a task (workflow step 3.3), and whenever a bug teaches
something:

1. First ask whether a test can enforce it. If so, write the test.
2. Otherwise check [Admission](#admission). Prefer editing an existing rule
   over adding one.
3. A file at the hard limit takes a new rule only if another is deleted or
   merged.
4. Change a rule in the same PR as the code and tests it describes.
5. Set `reviewed` on every spec file you edit.

These rules replace the seven-section template of the `trellis-update-spec`
skill for this repository.

## Glossary

| Term | Meaning |
|---|---|
| top bar | A page's `AppTopBar`. Not "AppBar", which is the raw widget it wraps. |
| bottom bar, rail | The shell's `FuncBottomNav` (narrow) and `NavigationRail` (wide). |
| branch | One of the five home-shell destinations and its navigator stack. |
| prompt | A transient message shown by `PromptHost` through `showAppSnackBar`. |
| sheet, dialog, menu | Overlays opened through `showAppBottomSheet`, `showAppDialog`, `AppMenuButton`. |
| work | One Pixiv illustration, manga or novel. "Artwork" is its image. |
| feed | A paged list: a `PagedFeedController` and the grid or list showing it. |
| detail page, viewer | The work page (`IllustDetailPage`) and the full-screen image viewer. |
| reduced motion | The motion gate is closed (platform setting or in-app switch). |
| touch exploration | TalkBack-style exploration, read from the rewritten `accessibleNavigation`. |
| account boundary | The current account id; state from another account must not render. |
| route kind | A network path tier (`ech`, `noSni`, `dohRealSni`, `direct`, `bootstrapNoSni`). |
