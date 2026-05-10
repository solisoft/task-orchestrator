# Fix unsubscribe route/verb mismatch between push.js and the controller

## Severity
high — the "Disable browser notifications" button on `/settings` is functionally broken; subscribed users cannot unsubscribe through the UI

## Location
- public/push.js (line ~63) — `unsubscribe()` sends `DELETE /push_subscriptions`
- config/routes.sl (line 48) — destroy is registered as `post("/push_subscriptions/delete", "push_subscriptions#destroy")`

## Issue
The frontend and backend disagree on how to unsubscribe:

```js
// public/push.js
const SUBSCRIBE_URL = '/push_subscriptions';
// …
await fetch(SUBSCRIBE_URL, {
  method: 'DELETE',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(json)
});
```

```soli
# config/routes.sl
post("/push_subscriptions/delete", "push_subscriptions#destroy")
```

`DELETE /push_subscriptions` matches no route, so the server returns 404 (or 405 depending on the dispatch layer) and the `push_subscriptions` row keeps living forever. The browser-side `pushManager.subscribe()` no-op-re-uses the same endpoint on next subscribe, so the database doesn't grow unbounded, but the "Disable" button silently fails — the user thinks they've unsubscribed, the server still has them.

The controller spec (`tests/push_subscriptions_controller_spec.sl`) exercises `post("/push_subscriptions/delete", ...)` directly and passes, which is why the issue didn't surface in `soli test`.

## Proposed Fix
Pick one of the two consistent shapes and align both sides. Lowest-risk option: keep the existing route (POST `/push_subscriptions/delete`) and update `public/push.js` to match:

```js
// public/push.js — inside unsubscribe()
await fetch(SUBSCRIBE_URL + '/delete', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(json)
});
```

(Single-line change to URL + verb; no model/controller edits needed since the controller spec already covers this path.)

Alternatively, if Soli's router supports a `delete()` helper (verify against the framework — `config/routes.sl` currently only uses `get`/`post`), change the route to `delete("/push_subscriptions", "push_subscriptions#destroy")` and leave `push.js` alone. Confirm with `soli serve . --dev`, then click "Enable" and "Disable" on `/settings` and verify the row disappears from `push_subscriptions` afterward.

## Acceptance Criteria
- Clicking "Disable" on `/settings` removes the row keyed by the browser's endpoint from `push_subscriptions`
- The full subscribe → unsubscribe → re-subscribe round-trip works through the UI without server errors
- `soli test tests/push_subscriptions_controller_spec.sl` still passes
- `soli lint` is clean on the changed file(s)
