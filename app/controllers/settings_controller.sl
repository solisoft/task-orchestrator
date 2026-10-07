# Settings — global app config (active agent + per-agent run caps).
# Backed by the `Setting` key/value model.
class SettingsController < ApplicationController
  current_user: Any
  title: Any
  agent_type: Any
  agents: Any
  agents_config: Any
  limits: Any
  plan_model: Any
  review_model: Any
  claude_options: Any
  opencode_options: Any
  codex_options: Any
  opencode_models: Any
  codex_models: Any
  claude_model_ids: Any
  claude_model_labels: Any
  allowed_set: Any
  allowed_orphans: Any
  presets: Any
  bonfire: Any
  settings_notice: Any

  def show(req)
    _email = session_get("user_email") ?? ""
    current_plan_model = Plan.default_plan_model()
    pmd = plan_model_picker_data(current_plan_model)
    # Settings is the only page that needs the full opencode universe (to
    # render the allowlist checkbox panel). The shell-out is paid here, not
    # in `plan_model_picker_data`, so every other page stays cheap.
    opencode_all = list_opencode_models()
    codex_all = list_codex_models()
    allowed = Plan.allowed_model_ids()
    claude_ids = Plan.claude_model_ids()
    @current_user = _email == "" ? nil : (User.find_by_email(_email) rescue nil)
    @title = "Settings"
    @agent_type = Setting.get_or("agent_type", Task.known_agents()[0])
    @agents = Task.known_agents()
    @agents_config = this._settings_load_agents_config()
    @limits = this._settings_load_limits()
    @plan_model = current_plan_model
    @review_model = Plan.default_review_model()
    @claude_options = pmd["claude_options"]
    @opencode_options = pmd["opencode_options"]
    @codex_options = pmd["codex_options"]
    @opencode_models = opencode_all
    @codex_models = codex_all
    @claude_model_ids = claude_ids
    @claude_model_labels = Plan.claude_model_labels()
    @bonfire = this._settings_bonfire_status()
    @settings_notice = this._settings_notice(req)
    @allowed_set = this._settings_allowed_set(allowed)
    @allowed_orphans = this._settings_allowed_orphans(allowed, claude_ids, opencode_all, codex_all)
    @presets = ThemePreset.all_with_builtins()
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
    Setting.set("agent_type", agent_type) if agent_type != "" && this._settings_known_agent(agent_type)
    theme = (form["theme"] ?? "").trim()
    Setting.set("theme", theme) if theme != "" && this._settings_known_theme(theme)

    # The allowlist write has to land BEFORE the plan_model write, because
    # `Plan.is_allowed_model` reads it back when validating the candidate.
    # Otherwise a single POST that both narrows the allowlist and switches
    # plan_model would validate against the previous allowlist state.
    Setting.set("allowed_models", this._settings_collect_allowed(form)) if form["allowed_models_present"].present?
    raw_plan_model = (form["plan_model"] ?? "").trim()
    if raw_plan_model != ""
      variant = (form["plan_variant"] ?? "").trim()
      candidate = raw_plan_model
      is_opencode = raw_plan_model.index_of("/") > 0
      if is_opencode && variant != "" && variant != "default" && _matches_charset(variant, "variant")
        candidate = raw_plan_model + ":" + variant
      end
      resolved = Plan.allow_plan_model(candidate)
      # Two gates before we persist: the value must shape-validate
      # (`allow_plan_model` rewrites anything else to the canonical
      # default — don't persist that, it'd silently overwrite the saved
      # choice on every junk POST), AND it must be on the user's
      # `allowed_models` allowlist (no-op when the allowlist is empty).
      Setting.set("plan_model", resolved) if resolved == candidate && Plan.is_allowed_model(resolved)
    end
    raw_review_model = (form["review_model"] ?? "").trim()
    if raw_review_model != ""
      variant = (form["review_variant"] ?? "").trim()
      candidate = raw_review_model
      is_opencode = raw_review_model.index_of("/") > 0
      if is_opencode && variant != "" && variant != "default" && _matches_charset(variant, "variant")
        candidate = raw_review_model + ":" + variant
      end
      resolved = Plan.allow_plan_model(candidate)
      Setting.set("review_model", resolved) if resolved == candidate && Plan.is_allowed_model(resolved)
    end
    for a in Task.known_agents()
      enabled_key = "enabled_" + a
      enabled_val = form[enabled_key]
      if enabled_val.present? && (enabled_val == "1" || enabled_val == "true")
        AgentConfig.set(a, true)
      else
        AgentConfig.set(a, false)
      end
    end
    for a in Task.known_agents()
      Setting.set("limit_daily_" + a, this._settings_parse_limit(form["limit_daily_" + a]))
      Setting.set("limit_weekly_" + a, this._settings_parse_limit(form["limit_weekly_" + a]))
    end
    if form["bonfire_present"] == "1"
      bonfire_error = this._settings_apply_bonfire(form)
      return {"status": 422, "body": bonfire_error} if bonfire_error.present?
    end
    redirect("/settings?saved=1")
  end

  # POST /settings/bonfire/check — call Bonfire's /api/v1/me with the
  # saved token and come back with "connected as <email>" or the error.
  def check_bonfire(req)
    url = Setting.get_or("bonfire_url", TicketSource.default_bonfire_url())
    token = str(Setting.get_or("bonfire_token", "")).trim
    if token == ""
      return redirect("/settings?bonfire_check=" + url_encode("No token saved yet") + "#integrations")
    end

    me = TicketSource._bonfire_get({"host": url, "token": token}, "/api/v1/me")
    text = me["ok"] ? "ok:" + str(me["data"]["email"] ?? "") : (me["error"] ?? "failed")
    redirect("/settings?bonfire_check=" + url_encode(text) + "#integrations")
  end

  # What the Integrations card shows: URL, whether a token is saved and its
  # last 4 characters (enough to recognise it, never the token itself).
  def _settings_bonfire_status()
    token = str(Setting.get_or("bonfire_token", "")).trim
    {
      "url": Setting.get_or("bonfire_url", TicketSource.default_bonfire_url()),
      "token_set": token != "",
      "token_hint": token.length > 4 ? token.substring(token.length - 4, token.length) : ""
    }
  end

  # Banner from the post-save / post-check redirect: nil or {"kind", "text"}.
  def _settings_notice(req)
    query = req["query"] ?? {}
    check = query["bonfire_check"]
    if check.present?
      if check.starts_with("ok:")
        return {"kind": "ok", "text": "Bonfire connected as " + check.substring(3, check.length) + "."}
      end

      return {"kind": "error", "text": "Bonfire check failed: " + check}
    end
    return {"kind": "ok", "text": "Settings saved."} if query["saved"] == "1"

    nil
  end

  # Bonfire ticket source: base URL + API token (from Bonfire's
  # /account/tokens). An empty token field keeps the stored token — it is
  # never echoed back into the page — and `bonfire_token_clear` drops it.
  # Returns an error message, or nil when everything was saved.
  def _settings_apply_bonfire(form)
    url = (form["bonfire_url"] ?? "").trim
    while url.ends_with("/")
      url = url.substring(0, url.length - 1)
    end
    url = TicketSource.default_bonfire_url() if url == ""
    valid_url = Regex.matches("^https?://[A-Za-z0-9.-]+(:[0-9]+)?$", url)
    return "Bonfire URL must look like https://host[:port]" if !valid_url

    Setting.set("bonfire_url", url)
    token = (form["bonfire_token"] ?? "").trim
    if form["bonfire_token_clear"].present?
      Setting.unset("bonfire_token")
    elsif token != ""
      Setting.set("bonfire_token", token)
    end
    nil
  end

  def set_theme(req)
    form = this._settings_form(req)
    theme = (form["theme"] ?? "").trim()
    if theme == "" || !this._settings_known_theme(theme)
      return {"status": 422, "body": "Unknown theme"}
    end

    Setting.set("theme", theme)
    return {"status": 204, "body": ""}
  end

  def create_preset(req)
    json = req["json"]
    if json.nil?
      return {"status": 400, "body": "JSON expected"}
    end

    name = (json["name"] ?? "").trim()
    css_vars = json["css_vars"]
    if name == "" || css_vars.nil?
      return {"status": 422, "body": "name and css_vars are required"}
    end

    key = "custom:" + name
    Setting.set_theme_preset(key, css_vars)
    ThemePreset.create({
      "name": name,
      "css_vars": css_vars
    }, {"key": key})
    redirect("/settings")
  end

  def update_preset(req)
    name = req.params["name"]
    json = req["json"]
    if json.nil?
      return {"status": 400, "body": "JSON expected"}
    end

    key = "custom:" + name
    existing = ThemePreset.find_by("_key", key)
    if existing.nil?
      return {"status": 404, "body": "Preset not found"}
    end

    css_vars = json["css_vars"]
    if css_vars.nil?
      return {"status": 422, "body": "css_vars is required"}
    end

    existing.css_vars = css_vars
    existing.name = json["name"].trim() if json["name"].present? && json["name"].trim() != ""
    existing.save()
    Setting.set_theme_preset(key, css_vars)
    redirect("/settings")
  end

  def delete_preset(req)
    name = req.params["name"]
    key = "custom:" + name
    existing = ThemePreset.find_by("_key", key)
    existing.delete() if existing.present?
    Setting.remove_theme_preset(key)
    redirect("/settings")
  end

  # Pull the merged-body view out of `req`, falling back across `all` /
  # `form` / `json` / `params` so the same controller works for plain HTML
  # form posts, JSON API calls, and the test client.
  def _settings_form(req)
    merged = req["all"]
    return merged if merged.present?
    form = req["form"]
    return form if form.present?
    json = req["json"]
    return json if json.present?
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
      v = true if v.nil?
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
      h[a] = {"daily": settings["limit_daily_" + a] ?? 0, "weekly": settings["limit_weekly_" + a] ?? 0}
    end
    h
  end

  # Coerce a raw form value into a non-negative int. Empty / blank /
  # unparseable / negative all collapse to `0` (= "unlimited"), so a
  # fat-fingered "abc" never accidentally locks the user out.
  def _settings_parse_limit(raw)
    return 0 if raw.nil?
    s = str(raw).trim()
    return 0 if s == ""
    n = int(s) rescue 0
    return 0 if n < 0
    return n
  end

  def _settings_known_agent(name)
    for a in Task.known_agents()
      return true if a == name
    end
    return false
  end

  def _settings_known_theme(name)
    return true if name.starts_with("custom:")

    # Accept any built-in preset key (dark / light / dracula / nord / …).
    # Custom user presets ride the `custom:` prefix.
    for p in ThemePreset.built_in_presets()
      return true if p["_key"] == name
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
    out = []
    seen = {}
    for key in form.keys()
      next if !key.starts_with("allowed_")
      next if key == "allowed_models_present"
      val = form[key]
      next if val != "1" && val != "true" && val != true
      id = key.substring("allowed_".length(), key.length)
      next if id == ""
      next if Plan.allow_plan_model(id) != id
      next if seen[id] == true
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
      out.push(id) if known[id] != true
    end
    out
  end
end
