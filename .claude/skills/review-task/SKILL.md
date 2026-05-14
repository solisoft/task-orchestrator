---
name: review-task
description: Review the uncommitted fix in this worktree against tasks/todo/<slug>.md, then convert draft PR to regular PR (or stop on Rejected). Use after /do-task — the orchestrator runs us in the same worktree to verify and update the PR.
---

# review-task

You are running inside the same worktree where `/do-task` just implemented a fix and created a draft PR. The orchestrator's DB row tracks the task's lifecycle; your job is the **code review** of the diff and, if approved, converting the draft PR to regular.

## Inputs

- **Argument**: the task slug. The spec lives at `tasks/todo/<slug>.md`. If no argument is passed, infer the slug from the single spec md present.
- **`CLAUDE.md`** describes the project's conventions, verification loop, and (often) commit-message style.

Do **not** move, rename, or delete the spec md. The orchestrator owns it; leave it where it is.

## Step 1 — Read the spec

Read `tasks/todo/<slug>.md` in full: Severity, Location, Issue, proposed Fix.

## Step 2 — Inspect repo state

In parallel:
- `git status`
- `git log --oneline -10` (to match the project's commit-message style)
- `git diff` and `git diff --cached`

The fix is **committed** in the working tree (that's how `/do-task` leaves it). If `git status` shows nothing changed, the verdict will likely be **Approved-no-fix-needed** — continue and let Step 4 decide.

## Step 3 — Review

Read the current state of the files referenced in the spec's Location section. For each:

1. **Verify the change addresses the described issue.** The proposed Fix in the spec is a *suggestion* — accept any equivalent implementation, but reject changes that paper over the issue (e.g. catching and ignoring an exception instead of fixing the root cause).
2. **Check completeness.** If the spec lists multiple call sites, verify every one was patched. Do **not** broaden scope — only verify what the spec explicitly described.
3. **Look for regressions.** Read the diff for the touched files in full. Flag: new unsafe paths, swallowed errors, broadened privileges, removed validation, weakened types.
4. **Check docs (user-facing changes).** If the project's `CLAUDE.md` describes a documentation policy, verify every surface it names was updated.
5. **Static checks** were already run in do-task. Do not re-run them in review-task — trust the do-task verification results unless you have specific reason to doubt them.

Report findings as a short markdown bullet list:
- **Verdict:** Approved / Approved-with-notes / Approved-no-fix-needed / Approved-with-followups / Rejected
- **Coverage:** what was checked
- **Findings:** issues (each: severity, file:line, what's wrong, suggested follow-up)

## Step 4 — Decision

- **Rejected** — Do **not** edit the PR. Report what's wrong and stop. The orchestrator will mark the row failed.
- **Approved-with-notes** — Notes are non-blocking. Continue to Step 4½.
- **Approved-no-fix-needed** — Review concluded the spec is invalid, describes intended behavior, or is won't-fix. Stop without editing the PR — the orchestrator detects "no action needed" and handles it.
- **Approved-with-followups** — Work is deferred. Before Step 4½, POST each follow-up as a Task document directly to the solidb `tasks` collection with `"tags": ["follow_up"]`. Do **not** write `.md` files on disk. The orchestrator seeds `.env` into the worktree; read solidb credentials from it:

    ```bash
    script_dir=$(dirname "$0")  # or equivalent
    project_root=$(dirname "$(dirname "$script_dir")")
    if [[ -f "$project_root/.env" ]]; then
        set -a; source "$project_root/.env"; set +a
    fi
    HOST="${SOLIDB_HOST:-http://localhost:6745}"
    DB="${SOLIDB_DATABASE:-tasks}"
    USER="${SOLIDB_USERNAME:-admin}"
    PASS="${SOLIDB_PASSWORD:-admin}"
    ```

    Construct one JSON payload per follow-up with the same shape as `bin/ingest-todos` (project, slug, title, body_md, status: "todo", timestamps) plus `"tags": ["follow_up"]`. Use `jq` or `printf` to build the payload, then `curl`:

    ```bash
    resp=$(curl -s -u "$USER:$PASS" \
        -X POST "$HOST/_api/database/$DB/document/tasks" \
        -H 'content-type: application/json' \
        -w '\n%{http_code}' \
        -d "$payload")
    code="${resp##*$'\n'}"
    ```

    The slug must be unique within the project — derive it from the follow-up title (lowercased + dashed, same as `unique_slug_for` in the controller). Continue to Step 4½.

    **Reality check before creating any follow-up.** For every symbol you name in a follow-up's title or Issue (function, method, file path, doc id), `grep` the worktree to confirm it exists OR explicitly frame the follow-up as a feature task ("Add `<X>`...", with rationale). Don't materialize a follow-up referencing a name you can't find. If unsure, drop the follow-up and note the uncertainty in the verdict.
- **Approved** — Continue to Step 4½.

## Step 4½ — Update PR

Find the draft PR created by `do-task` and convert it to a regular PR:

```bash
pr_url=$(gh pr list --head "$(git rev-parse --abbrev-ref HEAD)" --json url --jq '.[0].url' 2>/dev/null)
if [[ -n "$pr_url" ]]; then
    gh pr edit "$pr_url" --remove-draft
fi
```

If no draft PR is found, note it in your summary and continue.

## Step 5 — Report

Report findings as a short markdown bullet list:
- **Verdict:** Approved / Approved-with-notes / Approved-no-fix-needed / Approved-with-followups / Rejected
- **Coverage:** what was checked
- **Findings:** issues (each: severity, file:line, what's wrong, suggested follow-up)
- **PR:** link to the PR (updated or noted as not found)

End with the verdict summary.

## Constraints

- **Never** use `pkill`, `kill`, `killall`, or any process-killing command.
- **Never** edit the PR if the verdict is Rejected.
- **Never** skip hooks (`--no-verify`) or bypass signing. If a pre-commit hook fails, report and stop.
- **Never** push. The orchestrator handles push + PR merge after review approves the change.
- **Never** `git mv` the spec between `tasks/{todo,inprogress,review,done}/`. The DB tracks status; folder-shuffling is the old file-based queue.
- **Do not** edit the spec md content. If review surfaces follow-ups, write new `tasks/todo/<slug>.md` files instead.
- Process exactly **one** task per invocation.
- If `--allow-empty` feels tempting, stop and re-read Step 4 — an Approved-no-fix-needed with no diff means **no PR update**, not an empty commit.
- Do not run static checks in review-task if they were already run in do-task (trust the do-task verification results).
