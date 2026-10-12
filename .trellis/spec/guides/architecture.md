---
prefix: ARCH
applies_to:
  - lib/**
  - tool/gen_app_icon.py
  - tool/build_readme_assets.py
  - tool/gen_l10n_lookup.py
reviewed: 2026-10-12
---

# Architecture and ownership

### ARCH-01 Imports follow the three layers
- **Rule:** `lib/core` imports only `lib/core`; `lib/app` imports `core`
  and `app`; `lib/features` imports `core`, `app` and, for other features,
  only the `lib/app/navigation/routes.dart` facade. That facade is the one
  approved cycle. The test's allow-list only shrinks.
- **Why:** Features importing each other's pages grew cycles and gave one
  feature ownership of another's widgets.
- **Check:** `test/architecture/layering_test.dart` "lib import graph respects layering rules (allow-list must shrink to empty)"
- **Code:** `lib/app/navigation/routes.dart`

### ARCH-02 Data code lives in core; shared widgets live in app
- **Rule:** Entities, repositories, controllers and stores go in
  `lib/core/<domain>/`; `lib/features` holds no `*_repository.dart`,
  `*_controller.dart` or `*_models.dart`. A widget used by two features
  moves to `lib/app/widgets/` while its state stays with its core owner.
  Features do not define private `_*Tail`, `_*Error`, `_*Empty`, `_*Card`,
  `_*Status` or `_*Placeholder` widgets that duplicate the component layer.
- **Why:** Feature-local copies of feed states and follow buttons drifted
  apart and kept their own follow booleans.
- **Check:** `test/architecture/layering_test.dart`
- **Code:** `lib/app/widgets`, `lib/core`

### ARCH-03 Every cross-layer contract has one owner
- **Rule:** Pixiv hosts, headers and user agent come from
  `pixiv_client_identity.dart`; preference keys from `preference_keys.dart`;
  JSON reads from `json_read.dart`; prompts from `showAppSnackBar`; logs
  from `log()`. A change derives from the owner; never declare a second
  copy.
- **Why:** Duplicated host and key constants were updated in one place and
  not the other.
- **Check:** manual
- **Code:** `lib/core/network/pixiv_client_identity.dart`, `lib/core/settings/preference_keys.dart`, `lib/core/entity/json_read.dart`

### ARCH-04 Generated files are changed through their generator
- **Rule:** App icons come from `tool/gen_app_icon.py` (verify with
  `--check`), README images from `tool/build_readme_assets.py`, the
  localization lookup from `tool/gen_l10n_lookup.py` after
  `flutter gen-l10n`, FRB bindings from the matching codegen. Change the
  generator or its inputs and rerun; never edit the output.
- **Why:** Hand edits were overwritten by the next regeneration.
- **Check:** manual
- **Code:** `tool/gen_app_icon.py`, `tool/build_readme_assets.py`, `tool/gen_l10n_lookup.py`, `lib/l10n/lookup.dart`
