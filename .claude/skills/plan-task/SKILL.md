---
name: plan-task
description: Take rough free-text notes for a task and produce a structured task spec markdown ready for `/do-task`. Reads the notes from a file path passed as the only argument, prints the structured spec to stdout. Used by the task-orchestrator's "Plan with agent" form button. Fast, no codebase exploration.
---

# plan-task

Take the user's rough notes (path passed as the only argument) and emit a structured task spec ready for `/do-task` to consume. Print the result to stdout. Do not write files. Do not explore the target codebase — keep the run under ~30 seconds.

## Step 1 — Read the input

Read the file at the path argument (e.g. `/tmp/plan-task-XXXX.md`). Treat its contents as the user's rough idea — could be one line, could be a paragraph, could be a half-formed bullet list.

## Step 2 — Synthesize a structured spec

Output the markdown spec **directly** as your response — no code-fence wrappers (no ` ```md ` or ` ``` ` around the whole thing), no preamble (no "Here's the plan:"), no postscript (no closing remarks). The orchestrator captures stdout verbatim and shoves it into the form's body field; any wrapper characters end up visible in the textarea.

The spec must follow this shape, in this order:

- A first-line title heading: `# <SLUG-IF-OBVIOUS>: <one-line summary>`
- `## Severity` — one of `critical | high | medium | low | n/a` followed by an em-dash and a one-line why
- `## Location` — file paths or file:line refs from the notes, or `TBD — surface during /do-task`
- `## Issue` — 2–5 sentences describing the problem in the user's voice
- `## Proposed Fix` — 2–5 sentences describing the approach (concrete enough that /do-task can act on it; vague enough to leave room for the implementer to deviate)
- `## Acceptance Criteria` — 3–5 bullets, each testable

## Constraints

- Output **only** the markdown spec. No "Here's the plan:", no trailing summary, no questions back to the user. The orchestrator captures stdout verbatim and shoves it into the form's body field.
- Only use a `SLUG-` prefix in the title if the notes name one (e.g. `SEC-123`, `COV-014`, `BUG-007`). Otherwise omit and write just `# <one-line summary>`.
- If a section has no signal in the notes, write `<TBD>` for its body — better to leave honest gaps than fabricate severity, file paths, or acceptance criteria.
- Do **not** call any tools (no Bash, Read, Edit, Grep, WebFetch). Synthesize from the notes alone — the user fills in the gaps when they review.
- Preserve any file paths, function names, or line numbers the user wrote — copy them into the Location section verbatim.
- 3–5 acceptance-criterion bullets is the sweet spot. Each should be testable.

## Examples

**Input** (notes file):
```
crsf middleware doesn't strip x-forwarded-host before computing origin for double-submit token. attacker can pin a fake origin and bypass.
src/middleware/csrf.rs around line 80
```

**Output** (everything between the dashed lines, no fences, that's the literal output):

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

**Input** (notes file):
```
docs site dark mode toggle keeps flashing white on page load
```

**Output** (everything between the dashed lines):

----------
# Dark-mode toggle flashes white on page load

## Severity
low — UX polish, no functional impact

## Location
TBD — surface during /do-task

## Issue
On the docs site, navigating to a dark-mode page briefly renders the light-mode background before the user's preference is applied. The flash is short but visible enough to annoy.

## Proposed Fix
TBD — likely needs an inline `<script>` in the document head that reads the persisted preference (cookie or localStorage) before the first paint and sets the appropriate class on `<html>`. Investigate during /do-task.

## Acceptance Criteria
- No visible white flash when loading any docs page with dark mode preference set
- Preference still respects the existing toggle button
- Works with view-source / no-JS as a graceful fallback (or note explicitly that dark mode requires JS)
----------
