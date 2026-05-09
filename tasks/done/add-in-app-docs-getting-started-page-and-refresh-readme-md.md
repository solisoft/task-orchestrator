Now I have enough to draft the spec. The notes are short and the codebase is clear: the project is a Soli app with home/projects/tasks/runs/settings controllers and views, README exists but is stale (says "Web UI is paused" while routes are live). I'll pick reasonable defaults and note alternatives.

# Add in-app /docs "Getting Started" page and refresh README.md

## Severity
low — documentation work; no functional risk to the dispatch loop

## Location
- `config/routes.sl:1-32` — add `get("/docs", "docs#index")` (and any sub-pages) alongside existing top-level routes
- `app/controllers/` — new file `docs_controller.sl` (sibling of `home_controller.sl:1-19`, same `fn index(req)` shape)
- `app/views/docs/index.html.slv` — new view; mirror the layout/styling of `app/views/home/index.html.slv:1-39` and `app/views/settings/show.html.slv` (slate-950 + Tailwind utility classes, 2-space indent)
- `app/views/home/index.html.slv:8-10` — add a "📖 Docs" link in the header next to the existing "⚙ Settings" anchor
- `app/views/layouts/application.html.slv:1-52` — current layout already works; reuse the `task-md` CSS for any rendered prose
- `tests/docs_controller_spec.sl` — new spec, mirroring the BDD shape in `tests/CLAUDE.md`
- `README.md:113-123` — "Status" section is stale ("Web UI is paused") even though `config/routes.sl` shows the projects/tasks/runs/settings web UI is live; rewrite + add a pointer to `/docs`
- `README.md:9-24` — "Layout" tree omits `app/`, `config/`, `tests/`, `db/migrations/`; refresh to match the actual repo

## Issue
There is no in-app documentation today — a new user landing on `/` sees only the project list and a Settings link, with no onboarding path describing how to drop a task spec, queue it, install the watcher, or read the state files. The README covers some of this but is the only source and it is out of date: the "Status" section claims the web UI is paused (BUG-001), yet `config/routes.sl` plus the controllers under `app/controllers/` show a working projects/tasks/runs/settings UI driving the dispatch loop. The user wants both gaps closed: a polished in-browser Getting Started page, and a README that matches reality.

## Proposed Fix
Add a `DocsController` with an `index` action that renders a single, sectioned `/docs` page covering Overview → Setup (deps, watcher install) → Daily Use (drop / queue / watch) → Configuration (env vars) → Failure Mode → State files / worktrees, mirroring the README content but rewritten as a tour rather than a reference. Use the same slate-950 / rounded-2xl / `task-md` aesthetic as `home/index.html.slv` and `tasks/show.html.slv` so it lands native to the app. Wire it via `get("/docs", "docs#index")` in `config/routes.sl` and add a "📖 Docs" link next to "⚙ Settings" on the home header. Then rewrite README.md: refresh the Layout tree to include `app/`, `config/`, `tests/`, `db/migrations/`; replace the "Web UI is paused" Status block with the current state (web UI live; what works end-to-end); and add a one-liner pointing readers to `soli serve . --dev` + `/docs` for the rendered version. (Alternative considered: a multi-page docs section with side-nav routes per topic — heavier, deferred unless the page outgrows one screen.)

## Acceptance Criteria
- `GET /docs` returns 200 and renders `app/views/docs/index.html.slv` via `DocsController#index`
- Home page (`/`) shows a "📖 Docs" link in the header that navigates to `/docs`
- The docs page covers, at minimum: Overview, Setup, Daily Use, Configuration, Failure Mode — content sourced from current README + `bin/` script behavior, not invented
- `tests/docs_controller_spec.sl` asserts `res_status` 200 for `/docs` and that the rendered view path is `docs/index`
- README.md "Status" section reflects reality (web UI live, not paused), Layout tree lists `app/`, `config/`, `tests/`, `db/migrations/`, and a pointer to the in-app `/docs` is present
- `soli lint` clean on every changed file; `soli test --coverage --coverage-min 90.0` passes