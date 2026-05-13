# Thread change_author through features_controller#update

## Severity
Low — completeness gap, not a regression.

## Location
- `app/controllers/features_controller.sl` — `update` action (around lines 249–279).

## Issue
`Feature#_log_if_status_changed` (in `app/models/feature.sl`) writes an `ActivityLog`
row whenever a Feature's status flips on save, stamping `changed_by` from
`self.change_author`. Every flip-driving site already wires this through
(Task actions set `task.change_author` before save), but `features_controller#update`
calls `feature.save()` without first setting `feature.change_author`. The
result: when a user edits a feature's status via `/features/:id/edit`, the
audit row appears with an empty `changed_by` string instead of the editor's
email.

The original "all-tasks-but-belongs-to-a-user" spec called out only Task
actions in its acceptance criteria, so this was non-blocking on that task.
Worth fixing as a small follow-up to make Feature audit logs complete.

## Proposed Fix
Mirror the Task-side pattern from `tasks_controller#mark_done` / `archive`:

```soli
fn update(req)
  let feature = _find_feature(req)
  if feature == nil
    return {"status": 404, "body": "Feature not found"}
  end
  let form = req["all"] ?? {}
  ...
  feature.title = title
  feature.description = description
  feature.status = status
  feature.plan_model = _persisted_plan_model(form)
  if req["current_user"] != nil
    feature.change_author = req["current_user"].email ?? ""
  end
  feature.save()
  ...
end
```

Feature routes are auth-gated (see `config/routes.sl`), so `req["current_user"]`
is normally set; the nil-guard is defensive.

Add a spec to `tests/features_controller_spec.sl` (or a new
`tests/feature_activity_log_spec.sl`) that flips a feature's status via
`Feature#change_author = "..."; feature.status = "ready"; feature.save()`
and asserts the resulting `ActivityLog` row carries the expected
`changed_by`. The integration-level coverage already lives in
`tests/activity_log_spec.sl#"Feature → ActivityLog integration"`; this
controller-level spec just nails down the wiring.
