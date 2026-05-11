# Surface feature_slug and author in task show page and board

## Severity
medium — acceptance criteria gap for the feature-briefs feature

## Location
- `app/views/tasks/show.html.slv` — add author and feature link metadata row
- `app/views/projects/_board.html.slv` — add author badge next to agent badge

## Issue
The `add-feature-briefs-comments-multi-task-generation-and-user-authentication` feature added `feature_slug` and `author` fields to the `tasks` collection (migration `20260511000004_add_user_and_feature_to_tasks.sl`). The Feature model can query linked tasks via `feature.tasks()`, and `features_controller.sl` generates tasks with `feature_slug` and `author` populated. However, the task show page and the project board view were never updated to render these fields — the acceptance criteria explicitly says "both are surfaced in the task show page and board."

## Proposed Fix

1. In `app/views/tasks/show.html.slv`, add a metadata row beneath status that shows:
   - "Author: `<task.author ?? "—">`" (inline, near the status chip).
   - If `task.feature_slug` is present, render a link to the parent feature: `/features/<task.feature_slug>` with the feature slug or title as link text. Optionally resolve the feature title from `Feature.find_by("_key", task.feature_slug)` and fall back to the slug.

2. In `app/views/projects/_board.html.slv`, add a small author indication next to the agent badge (or below the slug). Keep it compact — a monospace grey label is fine.

3. Verify both views render correctly with tasks that have and don't have these fields set (schema-less docs in existing DB may have neither).
