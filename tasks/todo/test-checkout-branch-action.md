# Test checkout_branch action

## Severity
medium — missing test coverage for a new action

## Location
tests/tasks_controller_spec.sl

## Issue
The `checkout_branch` action was added in `app/controllers/tasks_controller.sl` but no tests were written. CLAUDE.md requires >90% coverage for new features and the spec says nothing about deferring tests.

## Proposed Fix
Add a `describe("POST /projects/:name/tasks/:slug/checkout")` block with:
- `test("returns 404 for unknown project")`
- `test("returns 404 for unknown task")`
- `test("returns 422 when task is not done or not local-branch outcome")`
- `test("returns 422 when branch does not exist locally")`
- `test("redirects when user is already on the target branch")`
- `test("returns 200 and redirects on successful git checkout")`