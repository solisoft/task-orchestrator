# Fix: Agent stream cuts off mid-delivery

## Problems

### Problem A — `initial_offset` wrong for logs > 16 KB (HIGH)
**Files:** `app/views/runs/_log.html.slv:4`, `app/controllers/runs_controller.sl`

`run_log_tail(..., 16384)` returns the last 16 KB. The view computes `initial_offset = tail.length = 16384`. When the WS connects and sends `offset: 16384`, `run_log_delta` reads the full file and returns bytes 16384→EOF. For a 50 KB log this means:
- The SSR paints the last 16 KB (bytes 33616→50000)
- The WS appends the full chunk starting from byte 16384 — so 17 KB of *older* content appears first, followed by a duplicate of the SSR tail

User sees a visible "jump backward" glitch mid-stream → reload fixes it.

**Fix:** Pass `run_log_size(project["name"], slug)` from the controller → view uses it as `initial_offset` instead of `tail.length`. `run_log_size` already exists and returns the correct total byte count.

### Problem B — Tick timeout missing (MEDIUM)
**File:** `public/run-stream.js`

The tick timer only re-arms after a response arrives. If the final `terminal: true` frame is lost in transit, the timer never fires again, the socket stays open (no `onclose`), and the stream silently freezes. Reload recovers because SSR is clean.

**Fix:** Add a per-tick watchdog — if no response arrives within `2 × tickMs`, force a reconnect.

---

## Changes

### 1. `app/controllers/runs_controller.sl` — `show` + `log` actions

Both actions need to pass `log_size` to their views.

**`show` (line ~15-27):** add `"log_size": run_log_size(project["name"], slug)` to the render hash.

**`log` (line ~92-100):** add `"log_size": run_log_size(project["name"], slug)` to the render_partial hash.

### 2. `app/views/runs/_log.html.slv` — use `log_size`

**Line 4:**
```soli
# Before
let initial_offset = (tail ?? "").length

# After
let initial_offset = log_size
```

`log_size` is 0 for empty/new logs, matching existing fallback behavior.

### 3. `public/run-stream.js` — tick watchdog

In `Controller.prototype.sendTick`, after sending the tick, arm a watchdog timer. In `handleMessage`, clear it on any response. If it fires, reconnect.

- In `Controller` constructor: add `this.tickWatchdog = null`
- In `sendTick`: after `this.ws.send(...)`, arm `c.tickWatchdog = setTimeout(fn, c.tickMs * 2)` that calls `scheduleReconnect`
- In `handleMessage`: at top, clear `tickWatchdog` if set
- In `clearTickTimer`: also clear `tickWatchdog`

### 4. `tests/run_spec.sl` — regression test

Seed a run with a log > 16384 bytes, GET the run page, assert `data-stream-offset` > 16384 and equals actual file size.

---

## Acceptance Criteria

- [ ] A run with a >16 KB `.log` file shows `data-stream-offset` equal to the full file size (not 16384)
- [ ] First WS frame after connect carries `log_chunk == ""` when at EOF
- [ ] If a tick response is lost in transit and no response arrives within `2 × tickMs`, client reconnects automatically
- [ ] `soli test` passes with >90% coverage