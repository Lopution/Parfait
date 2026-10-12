---
reviewed: 2026-10-12
---

# Guides

Rules for every layer. Read this index before any change; open a file when
its row applies. Format and admission rules are in the
[spec root](../index.md).

## Files

| File | Read when |
|---|---|
| [architecture.md](./architecture.md) | Adding a file, moving code between `app`, `core` and `features`, touching a generated file. |
| [code-quality.md](./code-quality.md) | Silencing a lint, adding a guard or threshold, deferring work until animations end. |
| [testing.md](./testing.md) | Writing or deleting any test. |

## Habits

- Before changing a value, search for every use of it.
- Verify each review finding against the code before acting on it; treat
  claims about trust boundaries, "missing validation" and "behaviour
  change" with suspicion until checked.
