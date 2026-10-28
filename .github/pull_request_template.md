<!--
Title: Conventional Commits, matching the commit messages, e.g.
`fix(network): keep the bootstrap tier to image hosts`.
-->

## Linked issue

<!-- `Closes #N`, or "none". -->

## User-facing change

<!--
One sentence each in Chinese and English, written for users; the
CHANGELOG and release notes are collected from here. "none" for changes
users cannot notice.
-->

- zh:
- en:

## Risk

<!--
low / high. High: network and TLS, credentials and accounts, persistence
and migrations, downloads, release and signing, CI workflows.
-->

## Verification

<!-- The checks you ran. UI changes: before/after screenshots. -->

## Independent review

<!--
Suggested for high-risk changes, not required: one read-only Codex run,
`codex exec -s read-only "<prompt>"`, whose adversarial prompt has it
read and attack `git diff main...HEAD` itself. List each finding and how it was handled (fixed, or why not), or say why
the review was skipped. CodeRabbit comments on every non-draft pull
request: answer its findings here or in its threads.
-->
