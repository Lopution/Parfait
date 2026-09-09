# Frontend Development Guidelines

> Best practices for frontend development in this project.

---

## Overview

This directory contains guidelines for frontend development. Fill in each file with your project's specific conventions.

---

## Guidelines Index

| Guide | Description | Status |
|-------|-------------|--------|
| [Directory Structure](./directory-structure.md) | Module organization and file layout | ✅ Active (layering rules, 2026-09) |
| [Component Guidelines](./component-guidelines.md) | Component patterns, props, composition | ✅ Active (Hero/Tab/Pull-to-Refresh contracts) |
| [Hook Guidelines](./hook-guidelines.md) | Custom hooks, data fetching patterns | To fill |
| [State Management](./state-management.md) | Local state, global state, server state | ✅ Active (PagedFeedController, Profile Edit, History contracts) |
| [Quality Guidelines](./quality-guidelines.md) | Code standards, forbidden patterns | ✅ Active |
| [Type Safety](./type-safety.md) | Type patterns, validation | ✅ Active |

---

## Documentation Conventions

Active guides describe shipped owners, observable behavior, and the tests that
enforce them. New entries should link to the code and its owning test instead
of introducing a parallel contract. `hook-guidelines.md` remains `To fill`
because this project has no Flutter Hooks usage to document.

---

**Language**: All documentation should be written in **English**.
