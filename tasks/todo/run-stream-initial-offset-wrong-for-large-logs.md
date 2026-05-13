# Run-stream WS connect duplicates bytes for runs with >16 KB of log output

## Severity
high — every run whose `.log` exceeds the 16 KB tail cap (most non-trivial runs) gets bogus content on the first paint: the WS connect double-paints the tail and inserts older bytes out of order. The bug is in user-visible UX, not in data integrity, and only affects the *initial* connect — once the client's own cursor advances, subsequent ticks are correct.

## Location
- `app/views/runs/_log.html.slv:4` — `let initial_offset = (tail ?? "").length` reads the *truncated* tail (capped at 16384 bytes by `run_log_tail`), not the actual file offset where the SSR snapshot ends.
- `app/views/runs/_log.html.slv:14` — `data-stream-offset="<%= initial_offset %>"` then advertises that wrong number to the WS client.
- `app/controllers/runs_controller.sl:15-27` (the `show` action) — needs to thread `run_log_size(...)` into the view alongside `tail`.
- `app/controllers/runs_controller.sl:77-95` (the `log` action) — same fix, so HTMX-driven re-renders of the partial stay consistent if anything still hits this endpoint.
- `app/models/run.sl:183-190` — `run_log_size(repo, slug)` already exists and returns the right value; no model change needed.

## Issue
`run_log_tail(repo, slug, 16384)` returns the last 16 KB of the `.log` file. For a 50 KB log it returns bytes 33616…50000 (a 16384-byte string). The view computes `initial_offset = tail.length = 16384` and renders it into the panel.

When the WS client connects, it sends `offset: 16384`. The server's `run_log_delta(repo, slug, 16384)` reads the full body (50000 bytes), sees `start=16384 < size`, and returns `chunk = body.substring(16384, 50000)` — 33616 bytes starting from byte 16384 of the file.

The client appends that chunk *after* the SSR-rendered tail. The user sees:

```
[SSR: bytes 33616…50000]       ← last 16 KB rendered server-side
[WS:  bytes 16384…50000]       ← appended on connect
```

- The first 17232 bytes of the WS chunk (16384…33616) are content the user has never seen, pasted *after* the tail.
- The last 16384 bytes of the WS chunk (33616…50000) are an exact duplicate of the SSR tail.

The two other streams (`_plan_stream`, the features generate-tasks panel) don't have this bug — they SSR-render the full `log` field out of the DB, so `log.length` is the real cursor.

`run_log_size` is already defined in `app/models/run.sl` for this exact purpose; it's just never called.

## Proposed Fix
1. In `runs_controller.sl#show` and `#log`, compute `let log_size = run_log_size(project["name"], slug)` and add `"log_size": log_size` to the `render(...)` / `render_partial(...)` data hash.
2. In `app/views/runs/_log.html.slv`, change `let initial_offset = (tail ?? "").length` to `let initial_offset = log_size`.
3. Add a spec to `tests/run_spec.sl` (or a controller-level spec) that seeds a >16 KB log, opens the run page, asserts `data-stream-offset` equals `run_log_size`, and `data-stream-offset > 16384`. Without this regression test the same bug can sneak back in any future refactor.

## Acceptance Criteria
- Opening the run page for a task whose `.log` is bigger than 16384 bytes renders `data-stream-offset` equal to the full file size, not 16384.
- The first WS frame from `runs#stream` after a connect carries `log_chunk == ""` (cursor is at EOF), no duplicated tail.
- New spec covering the >16 KB case lands in `tests/run_spec.sl`.
- `soli test --coverage --coverage-min 90.0` still passes.
