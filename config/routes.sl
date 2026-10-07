# Routes

# ── Authentication (unscoped) ────────
get("/login", "auth#login_form")
post("/login", "auth#login")
get("/logout", "auth#logout")

# ── Ops (unscoped) ───────────────────
# Health probe stays open for monitoring (k8s liveness, uptime checks).
get("/health", "home#health")

# ── Webhooks (unscoped) ──────────────
# GitHub/GitLab PR events. No session — each delivery authenticates
# itself against a Setting-stored secret (HMAC signature for GitHub,
# shared token for GitLab) inside the controller.
post("/webhooks/github", "webhooks#github")
post("/webhooks/gitlab", "webhooks#gitlab")

# ── Streams (WebSocket — unscoped) ───
# Soli's WS dispatcher doesn't run HTTP middleware on these routes, so
# they each authenticate themselves via per-stream tokens echoed by the
# client. Moving them inside `middleware("authenticate", …)` would be a
# no-op at best and broken at worst.
router_websocket("/ws/code-review-stream", "tasks#code_review_stream")
router_websocket("/ws/feature-generate-stream", "features#generate_stream")
router_websocket("/ws/run-stream", "runs#stream")

# ── Auth-gated routes ─────────────────
# Every HTML page and JSON action a signed-in user can reach lives here.
# Unscoped exceptions above are the gate itself (/login, /logout) and the
# ops endpoint (/health). Anonymous callers get a 302 to /login.

middleware("authenticate", fn() {

  # ── Root & Utility ──────────────────
  get("/", "home#landing")
  get("/debug", "debug#show")
  get("/debug/features", "debug#features_probe")
  get("/debug/demote", "debug#demote_feature_todos")
  get("/debug/stamp", "debug#stamp_imported")
  get("/debug/unstamp", "debug#unstamp_imported")
  get("/debug/try-import", "debug#try_import")
  get("/debug/comments", "debug#comments_probe")
  get("/docs", "docs#index")

  # ── Projects ─────────────────────────
  get("/projects", "projects#index")
  get("/projects/:name", "projects#show")
  # Project settings modal (per-project webhook secrets, …)
  post("/projects/:name/settings", "projects#update_settings")
  # Pull tickets from the project's tracker (GitLab / GitHub / Bonfire)
  post("/projects/:name/tickets/import", "projects#import_tickets")

  # ── Tasks ────────────────────────────
  get("/projects/:name/tasks/new", "tasks#new")
  # create must precede the static-segment plan route (Soli pruning)
  post("/projects/:name/tasks", "tasks#create")
  get("/projects/:name/tasks/:slug/sidebar", "tasks#sidebar")
  # Static-segment GETs (sidebar, code-review) must precede the bare
  # `:slug` show route — Soli's router would otherwise capture
  # `expose-params/code-review` as the slug.
  get("/projects/:name/tasks/:slug/code-review", "tasks#code_review_panel")
  get("/projects/:name/tasks/:slug", "tasks#show")
  post("/projects/:name/tasks/:slug/save", "tasks#save")
  post("/projects/:name/tasks/:slug/queue", "tasks#queue")
  post("/projects/:name/tasks/:slug/unqueue", "tasks#unqueue")
  post("/projects/:name/tasks/:slug/merge", "tasks#merge_branch")
  post("/projects/:name/tasks/:slug/checkout", "tasks#checkout_branch")
  post("/projects/:name/tasks/:slug/mark-done", "tasks#mark_done")
  post("/projects/:name/tasks/:slug/commit-push", "tasks#commit_push")
  post("/projects/:name/tasks/:slug/react", "tasks#react")
  post("/projects/:name/tasks/:slug/code-review", "tasks#code_review")
  post("/projects/:name/tasks/:slug/archive", "tasks#archive")
  post("/projects/:name/tasks/:slug/unarchive", "tasks#unarchive")

  # ── Runs ─────────────────────────────
  get("/projects/:name/tasks/:slug/run", "runs#show")
  get("/projects/:name/tasks/:slug/run/log", "runs#log")
  post("/projects/:name/tasks/:slug/run/resume", "runs#resume")

  # ── Push notifications ───────────────
  post("/push_subscriptions", "push_subscriptions#create")
  post("/push_subscriptions/delete", "push_subscriptions#destroy")
  get("/push/vapid-public-key", "push_subscriptions#vapid_public_key")

  # ── Versions (nested under projects) ─
  get("/projects/:name/versions", "versions#index")
  get("/projects/:name/versions/new", "versions#new")
  post("/projects/:name/versions", "versions#create")
  get("/projects/:name/versions/:id", "versions#show")
  get("/projects/:name/versions/:id/edit", "versions#edit")
  post("/projects/:name/versions/:id/update", "versions#update")
  post("/projects/:name/versions/:id/destroy", "versions#destroy")

  # ── Settings ─────────────────────────
  get("/settings", "settings#show")
  post("/settings", "settings#update")
  # Lightweight theme-only endpoint — used by the header toggle to flip
  # dark↔light without round-tripping the full settings form.
  post("/settings/theme", "settings#set_theme")
  # Verify the saved Bonfire token (GET /api/v1/me) and report back.
  post("/settings/bonfire/check", "settings#check_bonfire")
  post("/settings/presets", "settings#create_preset")
  put("/settings/presets/:name", "settings#update_preset")
  delete("/settings/presets/:name", "settings#delete_preset")

  # ── Features ─────────────────────────
  # Explicit (no `resources` index) — the cross-project /features list
  # was retired in Phase 5; features live inside their project hub now.
  # Browsers only emit GET/POST, and Soli's router doesn't honor a
  # `?_method=put|delete` override, so we map the destructive verbs to
  # POST aliases below.
  get("/features/new", "features#new")
  post("/features", "features#create")
  get("/features/:id", "features#show")
  get("/features/:id/edit", "features#edit")
  post("/features/:id/update", "features#update")
  post("/features/:id/destroy", "features#destroy")
  post("/features/:id/generate_tasks", "features#generate_tasks")
  post("/features/:id/regenerate_tasks", "features#regenerate_tasks")
  post("/features/:id/refine_tasks", "features#refine_tasks")
  post("/features/:id/cancel_plan", "features#cancel_plan")
  get("/features/:id/generate_tasks_log/:plan_id", "features#generate_tasks_log")
  post("/features/:id/plan-answer/:plan_id", "features#plan_answer")
  post("/features/:id/publish", "features#publish")
  post("/features/:id/tasks/:slug/remove", "features#remove_task")
  post("/features/:id/assign-cycle", "features#assign_cycle")
  post("/features/:id/promote", "features#promote")

  # ── Comments (nested under features) ─
  post("/features/:id/comments", "comments#create")
  post("/comments/:key/delete", "comments#destroy")
  # Auto-mounts:
  #   GET    /comments/:id/attachment/:blob_id  → attachments#show
  #   POST   /comments/:id/attachment           → attachments#create  (unused — we attach inside comments#create)
  #   DELETE /comments/:id/attachment/:blob_id  → attachments#destroy
  uploads("comments", "attachment")
})
