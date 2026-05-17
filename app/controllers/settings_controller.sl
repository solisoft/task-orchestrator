# Settings — global app config (active agent + per-agent run caps).
# Backed by the `Setting` key/value model.

class SettingsController < ApplicationController
  current_user:        Any
  title:               Any
  agent_type:          Any
  agents:              Any
  agents_config:       Any
  limits:              Any
  plan_model:          Any
  review_model:        Any
  claude_options:      Any
  opencode_options:    Any
  codex_options:       Any
  opencode_models:     Any
  codex_models:        Any
  claude_model_ids:    Any
  claude_model_labels: Any
  allowed_set:         Any
  allowed_orphans:     Any
  presets:             Any

  def show(req)
    _email = session_get("user_email") ?? ""
    current_plan_model = Setting.get_or("plan_model", "claude-sonnet-4-6")
    pmd                = plan_model_picker_data(current_plan_model)
    # Settings is the only page that needs the full opencode universe (to
    # render the allowlist checkbox panel). The shell-out is paid here, not
    # in `plan_model_picker_data`, so every other page stays cheap.
    opencode_all = list_opencode_models()
    codex_all    = list_codex_models()
    allowed      = Plan.allowed_model_ids()
    claude_ids   = Plan.claude_model_ids()
    @current_user        = _email == "" ? nil : (User.find_by_email(_email) rescue nil)
    @title               = "Settings"
    @agent_type          = Setting.get_or("agent_type", Task.known_agents()[0])
    @agents              = Task.known_agents()
    @agents_config       = this._settings_load_agents_config()
    @limits              = this._settings_load_limits()
    @plan_model          = current_plan_model
    @review_model        = Plan.default_review_model()
    @claude_options      = pmd["claude_options"]
    @opencode_options    = pmd["opencode_options"]
    @codex_options       = pmd["codex_options"]
    @opencode_models     = opencode_all
    @codex_models        = codex_all
    @claude_model_ids    = claude_ids
    @claude_model_labels = Plan.claude_model_labels()
    @allowed_set         = this._settings_allowed_set(allowed)
    @allowed_orphans     = this._settings_allowed_orphans(allowed, claude_ids, opencode_all, codex_all)
    @presets             = ThemePreset.all_with_builtins()
    render("settings/show")
  end

  def update(req)
    # Read from `req["all"]` — the framework's merged view of route params,
    # query string, JSON body, and URL-encoded form body. Reading from
    # `req["form"]` alone would miss JSON requests (the test client uses
    # JSON by default), and `req["json"]` alone would miss real form
    # POSTs from the settings page. The merged hash covers both.
    form = this._settings_form(req)
    agent_type = (form["agent_type"] ?? "").trim()
    if agent_type != "" and this._settings_known_agent(agent_type)
      Setting.set("agent_type", agent_type)
    end
    theme = (form["theme"] ?? "").trim()
    if theme != "" and this._settings_known_theme(theme)
      Setting.set("theme", theme)
    end
    # The allowlist write has to land BEFORE the plan_model write, because
    # `Plan.is_allowed_model` reads it back when validating the candidate.
    # Otherwise a single POST that both narrows the allowlist and switches
    # plan_model would validate against the previous allowlist state.
    if form["allowed_models_present"] != nil
      Setting.set("allowed_models", this._settings_collect_allowed(form))
    end
    raw_plan_model = (form["plan_model"] ?? "").trim()
    if raw_plan_model != ""
      variant = (form["plan_variant"] ?? "").trim()
      candidate = raw_plan_model
      is_opencode = raw_plan_model.index_of("/") > 0
      if is_opencode and variant != "" and variant != "default" and _matches_charset(variant, "variant")
        candidate = raw_plan_model + ":" + variant
      end
      resolved = Plan.allow_plan_model(candidate)
      # Two gates before we persist: the value must shape-validate
      # (`allow_plan_model` rewrites anything else to the canonical
      # default — don't persist that, it'd silently overwrite the saved
      # choice on every junk POST), AND it must be on the user's
      # `allowed_models` allowlist (no-op when the allowlist is empty).
      if resolved == candidate and Plan.is_allowed_model(resolved)
        Setting.set("plan_model", resolved)
      end
    end
    raw_review_model = (form["review_model"] ?? "").trim()
    if raw_review_model != ""
      variant = (form["review_variant"] ?? "").trim()
      candidate = raw_review_model
      is_opencode = raw_review_model.index_of("/") > 0
      if is_opencode and variant != "" and variant != "default" and _matches_charset(variant, "variant")
        candidate = raw_review_model + ":" + variant
      end
      resolved = Plan.allow_plan_model(candidate)
      if resolved == candidate and Plan.is_allowed_model(resolved)
        Setting.set("review_model", resolved)
      end
    end
    for a in Task.known_agents()
      enabled_key = "enabled_" + a
      enabled_val = form[enabled_key]
      if enabled_val != nil and (enabled_val == "1" or enabled_val == "true")
        AgentConfig.set(a, true)
      else
        AgentConfig.set(a, false)
      end
    end
    for a in Task.known_agents()
      Setting.set("limit_daily_"  + a, this._settings_parse_limit(form["limit_daily_"  + a]))
      Setting.set("limit_weekly_" + a, this._settings_parse_limit(form["limit_weekly_" + a]))
    end
    redirect("/settings")
  end

  def set_theme(req)
    form = this._settings_form(req)
    theme = (form["theme"] ?? "").trim()
    if theme == "" or not this._settings_known_theme(theme)
      return { "status": 422, "body": "Unknown theme" }
    end
    Setting.set("theme", theme)
    return { "status": 204, "body": "" }
  end

  def create_preset(req)
    json = req["json"]
    if json == nil
      return { "status": 400, "body": "JSON expected" }
    end
    name = (json["name"] ?? "").trim()
    css_vars = json["css_vars"]
    if name == "" or css_vars == nil
      return { "status": 422, "body": "name and css_vars are required" }
    end
    key = "custom:" + name
    Setting.set_theme_preset(key, css_vars)
    ThemePreset.create({ "_key": key, "name": name, "css_vars": css_vars })
    redirect("/settings")
  end

  def update_preset(req)
    name = req.params["name"]
    json = req["json"]
    if json == nil
      return { "status": 400, "body": "JSON expected" }
    end
    key = "custom:" + name
    existing = ThemePreset.find_by("_key", key)
    if existing == nil
      return { "status": 404, "body": "Preset not found" }
    end
    css_vars = json["css_vars"]
    if css_vars == nil
      return { "status": 422, "body": "css_vars is required" }
    end
    existing.css_vars = css_vars
    if json["name"] != nil and json["name"].trim() != ""
      existing.name = json["name"].trim()
    end
    existing.save()
    Setting.set_theme_preset(key, css_vars)
    redirect("/settings")
  end

  def delete_preset(req)
    name = req.params["name"]
    key = "custom:" + name
    existing = ThemePreset.find_by("_key", key)
    if existing != nil
      existing.delete()
    end
    Setting.remove_theme_preset(key)
    redirect("/settings")
  end

  # Pull the merged-body view out of `req`, falling back across `all` /
  # `form` / `json` / `params` so the same controller works for plain HTML
  # form posts, JSON API calls, and the test client.
  def _settings_form(req)
    merged = req["all"]
    if merged != nil
      return merged
    end
    form = req["form"]
    if form != nil
      return form
    end
    json = req["json"]
    if json != nil
      return json
    end
    return req["params"] ?? {}
  end

  # { "claude": true, "opencode": false, ... } — reflects whether each
  # agent is currently enabled. Unset means true (enabled by default).
  #
  # Bulk-loads the agent_configs collection once and reads from the hash
  # so the per-agent loop is O(1) DB calls — `AgentConfig.get_or` would
  # have fanned out one `FILTER doc._key == @val` query per known agent.
  def _settings_load_agents_config()
    configs = AgentConfig.all_as_hash()
    h = {}
    for a in Task.known_agents()
      v = configs[a]
      if v == nil
        v = true
      end
      h[a] = v
    end
    h
  end

  # { "claude": { "daily": N, "weekly": N }, ... } — every known agent
  # is present (zero-filled) so the view can iterate without nil-checking.
  #
  # Mirrors `_home_load_limits`: one `Setting.all()` scan, read from the
  # hash inside the loop.
  def _settings_load_limits()
    settings = Setting.all_as_hash()
    h = {}
    for a in Task.known_agents()
      h[a] = {
        "daily":  settings["limit_daily_"  + a] ?? 0,
        "weekly": settings["limit_weekly_" + a] ?? 0
      }
    end
    h
  end

  # Coerce a raw form value into a non-negative int. Empty / blank /
  # unparseable / negative all collapse to `0` (= "unlimited"), so a
  # fat-fingered "abc" never accidentally locks the user out.
  def _settings_parse_limit(raw)
    if raw == nil
      return 0
    end
    s = str(raw).trim()
    if s == ""
      return 0
    end
    n = int(s) rescue 0
    if n < 0
      return 0
    end
    return n
  end

  def _settings_known_agent(name)
    for a in Task.known_agents()
      if a == name
        return true
      end
    end
    return false
  end

  def _settings_known_theme(name)
    if name.starts_with("custom:")
      return true
    end
    # Accept any built-in preset key (dark / light / dracula / nord / …).
    # Custom user presets ride the `custom:` prefix.
    for p in ThemePreset.built_in_presets()
      if p["_key"] == name
        return true
      end
    end
    return false
  end

  # Walk the form looking for `allowed_<id>=1` checkboxes, keep only the
  # ids that round-trip through `Plan.allow_plan_model` (= shape-valid
  # Claude SDK or opencode "provider/model[:variant]"), and return them as
  # a deduplicated list. Anything malformed is silently dropped — the
  # allowlist must never carry a value that wouldn't survive the
  # shell-safety gate downstream.
  def _settings_collect_allowed(form)
    out  = []
    seen = {}
    for key in form.keys()
      if not key.starts_with("allowed_")
        next
      end
      if key == "allowed_models_present"
        next
      end
      val = form[key]
      if val != "1" and val != "true" and val != true
        next
      end
      id = key.substring("allowed_".length(), key.length)
      if id == ""
        next
      end
      if Plan.allow_plan_model(id) != id
        next
      end
      if seen[id] == true
        next
      end
      seen[id] = true
      out.push(id)
    end
    out
  end

  # Pre-compute `{ id: true, ... }` from the persisted allowlist so the
  # view's per-row `checked` check is an O(1) hash lookup instead of an
  # inner loop over the array on every checkbox.
  def _settings_allowed_set(allowed)
    h = {}
    for id in (allowed ?? [])
      h[id] = true
    end
    h
  end

  # Ids in the saved allowlist that aren't in the current Claude + opencode
  # detection. Surfaced in their own panel so the user can see (and untick)
  # stale entries — e.g. an opencode provider that's been uninstalled —
  # rather than having them silently vanish from the page.
  def _settings_allowed_orphans(allowed, claude_ids, opencode_models, codex_models)
    known = {}
    for c in claude_ids
      known[c] = true
    end
    for m in (opencode_models ?? [])
      known[m] = true
    end
    for m in (codex_models ?? [])
      known[m] = true
    end
    out = []
    for id in (allowed ?? [])
      if known[id] != true
        out.push(id)
      end
    end
    out
  end
end
