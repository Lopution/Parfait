# Backend Development Guidelines

> Best practices for backend development in this project.

---

## Overview

This directory contains guidelines for backend development. Fill in each file with your project's specific conventions.

---

## Guidelines Index

| Guide | Description | Status |
|-------|-------------|--------|
| [Directory Structure](./directory-structure.md) | Module organization and file layout | ✅ Active |
| [Database Guidelines](./database-guidelines.md) | SQLite schema, queries, migrations | ✅ Active |
| [Error Handling](./error-handling.md) | Error types, propagation, UI mapping | ✅ Active |
| [Quality Guidelines](./quality-guidelines.md) | Code standards, forbidden patterns, secrets handling | ✅ Active |
| [Logging Guidelines](./logging-guidelines.md) | Application logging outlet and message policy | ✅ Active |
| [In-App Web Profile](./in-app-web-profile.md) | Native profile save via Pixiv SPA AJAX | Filled |
| [Release Artifacts](./release-artifacts.md) | Per-ABI APKs, size gate, updater schema 2, rhttp feature rules | Filled |
| [Android Channels](./android-channels.md) | 10 Method/Event channels: methods, args, returns, error codes, threads, snapshot file, updater Map errors | Filled |
| [rhttp Rust Plugin](./rust-plugin.md) | Fork policy, FRB version contract, Cargokit ABI outputs, Android version boundaries | Filled |

---

## Documentation Conventions

Active guides describe the shipped owner, boundary, and verification command
for the code they cover. Keep cross-layer contracts linked to their executable
spec or test, and update the guide when a verified implementation changes.

---

**Language**: All documentation should be written in **English**.
