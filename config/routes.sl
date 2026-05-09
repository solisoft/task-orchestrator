# Routes configuration

get("/", "home#index")
get("/health", "home#health")

# Settings — global config (active agent + per-agent run caps)
get("/settings", "settings#show")
post("/settings", "settings#update")

# Project kanban
get("/projects/:name", "projects#show")

# Task viewer + actions. URLs use the task slug (filename without `.md`),
# which is the identifier on the Task model.
get("/projects/:name/tasks/new", "tasks#new")
# create must come before the literal-segment plan route, otherwise the
# Soli router prunes the `/tasks` POST branch when the static child is
# registered first and bare-`/tasks` POSTs fall through to a 404.
post("/projects/:name/tasks", "tasks#create")
post("/projects/:name/tasks/plan", "tasks#plan")
get("/projects/:name/tasks/:slug", "tasks#show")
post("/projects/:name/tasks/:slug/save", "tasks#save")
post("/projects/:name/tasks/:slug/queue", "tasks#queue")
post("/projects/:name/tasks/:slug/unqueue", "tasks#unqueue")

# Live agent-run viewer (status + log tail, HTMX-polled)
get("/projects/:name/tasks/:slug/run", "runs#show")
get("/projects/:name/tasks/:slug/run/log", "runs#log")
get("/debug", "debug#show")
