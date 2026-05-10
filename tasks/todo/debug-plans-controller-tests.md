# Debug plans controller tests

## Severity
medium — tests are failing in CI; 3/5 assertions broken

## Location
tests/plans_controller_spec.sl — `lists a done plan with rendered body`, `lists a failed plan`, `handles empty DB gracefully`

## Issue
When `soli test tests/plans_controller_spec.sl` runs (or via the full suite), the 3 tests that assert on `get("/plans")` response body fail with `assert values not equal at <line>:13`. The route returns 200 but `res_body(response)` does not contain the expected plan IDs (`plan-99990001`, `plan-99990002`).

This suggests:
- `Plan.create({...})` rows are not being persisted to the DB in the test context, OR
- `Plan.all()` / `Plan.where(...)` in the controller is not reading them back, OR
- `Plan.delete_all()` in `before_each` is wiping rows across test workers

## Proposed Fix
1. Add debug output (`puts` / log) inside the test and controller action to trace what `Plan.all()` returns.
2. Verify `assert_test_db()` in `before_each` is connecting to the same DB instance the controller uses.
3. Check whether `Plan.delete_all()` actually removes rows (it may be a no-op if the model doesn't have a `delete_all` static method implemented).
4. Consider whether the plan fixture rows need a `_key` that matches what `find_by_plan_id` / `find_by("_key", plan_id)` actually looks up.