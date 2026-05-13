# Routes

# ── Authentication (unscoped) ────────

get("/login", "auth#login_form")
post("/login", "auth#login")
get("/logout", "auth#logout")

# ── Root & Utility ──────────────────

get("/", "home#landing")
get("/agents-dashboard", "home#index")
get("/plans", "plans#index")
get("/health", "home#health")
get("/debug", "debug#show")
get("/debug/features", "debug#features_probe")
get("/debug/demote", "debug#demote_feature_todos")
get("/debug/stamp", "debug#stamp_imported")
get("/debug/unstamp", "debug#unstamp_imported")
get("/debug/try-import", "debug#try_import")
get("/debug/comments", "debug#comments_probe")
get("/docs", "docs#index")

# ── Settings ─────────────────────────

get("/settings", "settings#show")
post("/settings", "settings#update")

# ── Projects ─────────────────────────

get("/projects/:name", "projects#show")

# ── Tasks ────────────────────────────

get("/projects/:name/tasks/new", "tasks#new")
# create must precede the static-segment plan route (Soli pruning)
post("/projects/:name/tasks", "tasks#create")
get("/projects/:name/tasks/:slug/sidebar", "tasks#sidebar")
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

# ── Plans (per-project) ──────────────

post("/projects/:name/tasks/plan", "tasks#plan")
get("/projects/:name/tasks/plan-log/:plan_id", "tasks#plan_log")
post("/projects/:name/tasks/plan-answer/:plan_id", "tasks#plan_answer")
post("/projects/:name/tasks/plan-refine/:plan_id", "tasks#plan_refine")
post("/projects/:name/tasks/plan-retry/:plan_id",  "tasks#plan_retry")
router_websocket("/ws/plan-stream", "tasks#plan_stream")
# Sits outside the `authenticate` block: the WS handler is event-driven, so
# cookie-based session lookup isn't reliably available here. The plan_id
# (a server-generated nonce) is what gates access, mirroring how
# `runs#stream` treats its slug.
router_websocket("/ws/feature-generate-stream", "features#generate_stream")

# ── Runs ─────────────────────────────

get("/projects/:name/tasks/:slug/run", "runs#show")
get("/projects/:name/tasks/:slug/run/log", "runs#log")
post("/projects/:name/tasks/:slug/run/resume", "runs#resume")
# Live WebSocket streams — the views drive these instead of 2s polling.
# Soli 1.0.3's `router_websocket` does not extract `:name`-style path
# params for WS routes, so all three streams ride a single static
# endpoint each; the client identifies the resource by echoing `project`
# / `slug` / `plan_id` / `feature_id` on every tick.
router_websocket("/ws/run-stream", "runs#stream")

# ── Push notifications ───────────────

post("/push_subscriptions", "push_subscriptions#create")
post("/push_subscriptions/delete", "push_subscriptions#destroy")
get("/push/vapid-public-key", "push_subscriptions#vapid_public_key")

# ── Auth-gated routes ─────────────────

middleware("authenticate", -> {

  # ── Features ─────────────────────────

  resources("features")
  post("/features/:id/generate_tasks", "features#generate_tasks")
  post("/features/:id/regenerate_tasks", "features#regenerate_tasks")
  post("/features/:id/refine_tasks", "features#refine_tasks")
  post("/features/:id/cancel_plan", "features#cancel_plan")
  get("/features/:id/generate_tasks_log/:plan_id", "features#generate_tasks_log")
  post("/features/:id/plan-answer/:plan_id", "features#plan_answer")
  post("/features/:id/publish", "features#publish")
  post("/features/:id/tasks/:slug/remove", "features#remove_task")

  # ── Comments (nested under features) ─

  post("/features/:id/comments", "comments#create")
  post("/comments/:key/delete", "comments#destroy")
  # Auto-mounts:
  #   GET    /comments/:id/attachment/:blob_id  → attachments#show
  #   POST   /comments/:id/attachment           → attachments#create  (unused — we attach inside comments#create)
  #   DELETE /comments/:id/attachment/:blob_id  → attachments#destroy
  uploads("comments", "attachment")

})
