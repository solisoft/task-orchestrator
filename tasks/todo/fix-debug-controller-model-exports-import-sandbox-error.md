# Fix `debug_controller.sl` import sandbox error blocking soli serve and soli test

## Severity
high — every test and the dev server fail to start on `main` (and every branch off it)

## Location
- `app/controllers/debug_controller.sl` line 1 — `import { run_state_root } from "../helpers/model_exports.sl"`
- `app/helpers/model_exports.sl` — exists but resolves *outside* the controllers sandbox root

## Issue
Running `soli serve .` or `soli test <any-spec>` fails with:

```
Error: Module resolution error in app/controllers/debug_controller.sl:
Import error: Import '/.../app/helpers/model_exports.sl' resolves outside its
allowed root '/.../app/controllers' at 0:0
```

The interpreter sandboxes controller imports to the controllers directory, so
the relative `../helpers/...` import is rejected even though the file exists
and is intended to be loaded.

This was introduced in PR #27 (commit 4c457f9 — "fix(lint): resolve all 64
soli lint errors"). The lint fix wired controllers to import re-exported model
helpers via `app/helpers/model_exports.sl`, but the sandbox layer doesn't
allow controllers to import from `../helpers/`. The result is that **no** test
in `tests/` can run (the test server can't boot) and `soli serve` immediately
crashes.

## Proposed Fix
Either:
1. Whitelist `app/helpers/` for controller imports in the sandbox config (if a
   project-level allowlist exists), or
2. Move `model_exports.sl` (or its re-exports) into the controllers directory
   or another sandbox-allowed location, or
3. Inline the imports per-controller (revert to direct `from "../models/..."`)
   and silence `style/redundant-model-import` with a per-line `# soli-lint:` disable.

Whatever path is chosen, the acceptance criterion is: `soli test` runs end-to-end
on a fresh checkout, and `soli serve . --dev` boots without error.

## Acceptance Criteria
- `soli serve . --dev` boots without a module-resolution error.
- `soli test --coverage --coverage-min 90.0` finishes (pass/fail) instead of
  aborting with "Test server failed to start on port ...".
- No new lint errors introduced by whichever path is taken.
