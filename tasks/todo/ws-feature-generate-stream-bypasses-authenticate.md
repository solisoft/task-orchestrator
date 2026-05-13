# WS feature-generate-stream is outside the authenticate middleware

## Severity
medium — authorization regression on the features surface. An anonymous caller who can guess `feature._key` (= `project--slug`) and a `plan_id` can subscribe to a feature's plan-generation transcript over WebSocket, even though the HTTP polling counterpart for the same flow was auth-gated. No write path is exposed; the regression is read-only.

## Location
- `config/routes.sl:63` — `router_websocket("/ws/feature-generate-stream", "features#generate_stream")` sits in the unauthenticated block.
- `config/routes.sl:85-109` — `middleware("authenticate", -> { ... })`. The HTTP siblings that this WS replaces (`get("/features/:id/generate_tasks_log/:plan_id", ...)` at line 94, plus everything else under `resources("features")`) live here.
- `app/controllers/features_controller.sl:866-900` — `generate_stream(event)` handler. It does verify `Feature.find(feature_key)` succeeds, but does not consult `req["current_user"]` (the WS frame doesn't carry one) or any other authorization check.
- `app/controllers/features_controller.sl:925-940` — `_render_generate_progress` emits `data-stream-feature-id="<%= feature._key %>"` into the page, so the identifier surfaces to anyone who can view the rendered HTML; the security boundary collapses to "knowing the feature key".

## Issue
Before this branch, the only way to follow a feature's plan-run was `GET /features/:id/generate_tasks_log/:plan_id`, which is wrapped by the `authenticate` middleware. After this branch, the same data is available over an unauthenticated WebSocket. The other two WS routes (`/ws/run-stream`, `/ws/plan-stream`) don't change the auth posture — their HTTP siblings (`/projects/.../run/log`, `/projects/.../tasks/plan-log/:plan_id`) were already unauthenticated — but the features generate flow was inside `authenticate`.

The implementer's comment in `routes.sl:59-62` acknowledges that the WS handler is event-driven and that "cookie-based session lookup isn't reliably available here", and argues that the plan_id nonce gates access. That's true for the plan/run streams (those endpoints were already public). It's *not* a sufficient justification for the features stream, because the corresponding HTTP route was protected — and `feature._key` is `<project>--<slugified-title>`, which is largely guessable from a project name plus a feature title that may be public.

## Proposed Fix
Pick whichever of the three the project prefers — list the trade-offs and ask before committing:

1. **Move the WS route inside `authenticate`** (if Soli's `router_websocket` honors scoped middleware). Cheapest if it works; defer if the WS handshake can't read the session cookie.
2. **Mint a short-lived per-page WS token** in `features_controller#show` (random nonce stamped onto the rendered `data-stream-token` attribute, stored in `Setting` or in-memory with an expiry, validated by `generate_stream` on each tick). Survives the cookie-availability constraint.
3. **Drop the WS route entirely and keep `/features/:id/generate_tasks_log/:plan_id` HTMX polling** for the features flow alone. The other two streams (runs, plan-task) still benefit from WS; the auth-gated one stays on the older transport.

Whichever path is picked, add a controller spec that asserts the chosen access control: e.g. an anonymous client subscribing to `/ws/feature-generate-stream` for a known `feature_id` either gets an error frame or never reaches the resource.

## Acceptance Criteria
- An unauthenticated client cannot read a feature's plan-generation transcript over WS (verified by a new spec).
- Authenticated clients continue to receive the WS stream as they do today.
- The behavior is documented in the routes file (replace the existing comment with the new rationale).
- `soli test --coverage --coverage-min 90.0` still passes.
