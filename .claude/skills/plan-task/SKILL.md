---
name: plan-task
description: Take rough free-text notes for a task and produce a structured task spec markdown ready for `/do-task`. Args: <notes_path> [<project_root>]. Reads the notes from the first path; if a project_root is given, ground the plan against THAT tree (read its CLAUDE.md, glob its files) — not the cwd. Prints the structured spec to stdout. Used by the task-orchestrator's "Plan it" form button. Can call AskUserQuestion when an ambiguity would otherwise force a wrong plan.
---

# plan-task

Take the user's rough notes (path passed as the first argument), inspect the **target project** enough to ground the plan in real files, and emit a structured task spec ready for `/do-task` to consume. Print the result to stdout. Do not edit files. The orchestrator captures stdout verbatim and shoves it into the form's body field — any wrapper characters end up visible in the textarea.

## Arguments

- **First arg (`notes_path`)** — required. Path to the user's rough notes (e.g. `/tmp/plan-task-XXXX.md`).
- **Second arg (`project_root`)** — optional. Absolute path to the project the plan is *about* (e.g. `/home/user/workspace/soli/crm`). When present, you MUST ground all exploration there — your cwd is the orchestrator, not the target project, so any unqualified Glob/Read/Grep would scan the wrong tree. When absent, fall back to your cwd.

## Step 1 — Read the input

Read the file at `notes_path`. Treat its contents as the user's rough idea — could be one line, could be a paragraph, could be a half-formed bullet list.

## Step 2 — Ground the plan in the target project

Before drafting the spec, do a *quick* read of the **target project** (the second arg, if given; otherwise cwd) so the plan names real files:

- Read `<project_root>/CLAUDE.md` (and any relevant per-directory `<project_root>/app/<x>/CLAUDE.md`) — these encode naming conventions, file layout, generators, and lint rules.
- Use `Glob` with explicit `path: <project_root>` (or absolute patterns), `Read` with absolute paths, and `Grep` with `path: <project_root>` to confirm where similar features live. For a "coupons" feature in a Soli app, the canonical answers are `<project_root>/app/models/coupon.sl`, `<project_root>/app/controllers/coupons_controller.sl`, `<project_root>/db/migrations/<TS>_create_coupons.sl`, `<project_root>/tests/coupons_controller_spec.sl`, and a `resources("coupons")` line in `<project_root>/config/routes.sl` — confirm by listing siblings, don't assume.
- In the spec output, write paths *relative to the project root* (e.g. `app/models/coupon.sl` — not the absolute version). The reader will be working inside the project, not the orchestrator.
- Don't read more than ~5 files. The goal is grounding, not implementation.

If a critical detail is genuinely ambiguous and would change the structure of the plan — *not* a stylistic preference, *not* something /do-task can decide later — call `AskUserQuestion` with 2–4 concrete options. The orchestrator routes the question to the form. Examples worth asking:
- "Is this a brand-new resource or an extension of an existing model?" (changes whether we generate or extend)
- "Should this go in the main app or in an existing engine under `engines/`?"
Examples *not* worth asking (just pick the obvious one):
- "What field types should the model have?" — the user usually doesn't know yet; let /do-task surface specifics.
- "Should we write tests?" — yes, always, per CLAUDE.md.

Do not call write tools (`Edit`, `Write`, `NotebookEdit`). Do not run the test suite or the dev server. Do not push, commit, or branch.

## Step 3 — Synthesize a structured spec

Output the markdown spec **directly** as your response — no code-fence wrappers (no ` ```md ` or ` ``` ` around the whole thing), no preamble (no "Here's the plan:"), no postscript (no closing remarks).

The spec must follow this shape, in this order:

- A first-line title heading: `# <SLUG-IF-OBVIOUS>: <one-line summary>`
- `## Severity` — one of `critical | high | medium | low | n/a` followed by an em-dash and a one-line why
- `## Location` — concrete file paths grounded in Step 2. List the files /do-task will create or change. Use `(new)` for files that don't exist yet. Only fall back to `TBD — surface during /do-task` when the change is genuinely placeless (e.g. a one-line config tweak whose location depends on /do-task's discovery).
- `## Issue` — 2–5 sentences describing the problem in the user's voice
- `## Proposed Fix` — 2–5 sentences describing the approach (concrete enough that /do-task can act on it; vague enough to leave room for the implementer to deviate). Mention the generator commands when applicable (`soli generate model coupon`, `soli generate controller coupons`, etc.) — they encode the framework's expected boilerplate.
- `## Acceptance Criteria` — 3–5 bullets, each testable

## Constraints

- **Never** use `pkill`, `kill`, `killall`, or any process-killing command.
- Output **only** the markdown spec. No "Here's the plan:", no trailing summary. The orchestrator captures stdout verbatim and shoves it into the form's body field.
- Only use a `SLUG-` prefix in the title if the notes name one (e.g. `SEC-123`, `COV-014`, `BUG-007`). Otherwise omit and write just `# <one-line summary>`.
- Preserve any file paths, function names, or line numbers the user wrote — copy them into the Location section verbatim. Augment with the paths you discovered in Step 2.
- 3–5 acceptance-criterion bullets is the sweet spot. Each should be testable.
- No timestamps in migration filenames — use `<TS>` as a placeholder (the generator fills in the real timestamp).

## Examples

**Input** (notes file):
```
add coupons
```

**Output** (everything between the dashed lines, no fences, that's the literal output):

----------
# Add coupons resource

## Severity
medium — new feature; isolated to its own files

## Location
- app/models/coupon.sl (new)
- app/controllers/coupons_controller.sl (new)
- app/views/coupons/index.html.slv (new)
- app/views/coupons/show.html.slv (new)
- app/views/coupons/new.html.slv (new)
- app/views/coupons/edit.html.slv (new)
- app/views/coupons/_form.html.slv (new)
- db/migrations/<TS>_create_coupons.sl (new)
- config/routes.sl — add `resources("coupons")`
- tests/coupons_controller_spec.sl (new)

## Issue
The app needs a Coupons resource: somewhere to model promotional codes, a place to list/create/edit them, and persistence. The user has no existing scaffold for this.

## Proposed Fix
Run `/soli-resource coupons` (or step through `soli generate model coupon` / `soli generate controller coupons` / `soli generate migration create_coupons`) to scaffold the canonical RESTful resource. Fill in the model fields (at minimum: `code`, `discount_pct`, `expires_at`, `active`), validations (`code` presence + uniqueness), and the controller's `_permit_params` whitelist. Add `resources("coupons")` to `config/routes.sl`. Cover the controller end-to-end in the spec file (>90% coverage per CLAUDE.md).

## Acceptance Criteria
- `Coupon` model exists with `code`, `discount_pct`, `expires_at`, `active` fields and presence + uniqueness validation on `code`
- `CouponsController` provides index/show/new/create/edit/update/destroy, all whitelisting params via `_permit_params`
- `coupons` migration runs cleanly forward and backward (`soli db:migrate up` / `down`)
- Controller spec covers happy paths and validation failures, hitting >90% coverage on the new code
- `coupons_path()` / `coupon_path(c)` helpers resolve from `resources("coupons")` and replace any hand-built URLs in views
----------

**Input** (notes file):
```
csrf middleware doesn't strip x-forwarded-host before computing origin for double-submit token. attacker can pin a fake origin and bypass.
src/middleware/csrf.rs around line 80
```

**Output**:

----------
# SEC-?: CSRF middleware honours X-Forwarded-Host without trust check

## Severity
high — origin-based CSRF check can be spoofed via attacker-controlled header

## Location
- src/middleware/csrf.rs around line 80

## Issue
The CSRF double-submit token check derives the request origin from `X-Forwarded-Host`. When the app is reachable directly (no trusted proxy), an attacker can set that header on a forged request and pin a same-origin value, defeating the check.

## Proposed Fix
Gate `X-Forwarded-Host` consumption on the existing `enable_trust_proxy` flag — when that flag is off, fall back to the bare `Host` header, ignoring proxy hints. Add a regression test that calls the middleware twice (proxy on / off) with the same forged header and asserts the off-case rejects.

## Acceptance Criteria
- CSRF middleware ignores `X-Forwarded-*` when `enable_trust_proxy` is false
- Test asserts a forged `X-Forwarded-Host` does not satisfy origin check with proxy off
- Test asserts the trusted-proxy path still works as before
- No new public API surface; the change is internal to `csrf.rs`
----------
