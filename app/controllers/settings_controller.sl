# Settings — global app config (active agent + per-agent run caps).
# Backed by the `Setting` key/value model.

fn show(req)
  render("settings/show", {
    "title": "Settings",
    "agent_type": Setting.get_or("agent_type", Task.known_agents()[0]),
    "agents": Task.known_agents(),
    "agents_config": _settings_load_agents_config(),
    "limits": _settings_load_limits(),
    "plan_model": Setting.get_or("plan_model", "claude-sonnet-4-6"),
    "opencode_models": list_opencode_models(),
    "theme": Setting.current_theme()
  })
end

fn update(req)
  # Read from `req["all"]` — the framework's merged view of route params,
  # query string, JSON body, and URL-encoded form body. Reading from
  # `req["form"]` alone would miss JSON requests (the test client uses
  # JSON by default), and `req["json"]` alone would miss real form
  # POSTs from the settings page. The merged hash covers both.
  let form = _settings_form(req)
  let agent_type = (form["agent_type"] ?? "").trim()
  if agent_type != "" and _settings_known_agent(agent_type)
    Setting.set("agent_type", agent_type)
  end
  let theme = (form["theme"] ?? "").trim()
  if theme != "" and _settings_known_theme(theme)
    Setting.set("theme", theme)
  end
  let raw_plan_model = (form["plan_model"] ?? "").trim()
  if raw_plan_model != ""
    let variant = (form["plan_variant"] ?? "").trim()
    let candidate = raw_plan_model
    let is_opencode = raw_plan_model.index_of("/") > 0
    if is_opencode and variant != "" and variant != "default" and _matches_charset(variant, "variant")
      candidate = raw_plan_model + ":" + variant
    end
    let resolved = _allow_plan_model(candidate)
    # `_allow_plan_model` returns the canonical default for any value
    # that didn't match the allowlist. Persist only when the user's
    # input actually round-trips — otherwise we'd silently rewrite
    # their saved choice to "claude-sonnet-4-6" on every junk POST.
    if resolved == candidate
      Setting.set("plan_model", resolved)
    end
  end
  for a in Task.known_agents()
    let enabled_key = "enabled_" + a
    let enabled_val = form[enabled_key]
    if enabled_val != nil and (enabled_val == "1" or enabled_val == "true")
      AgentConfig.set(a, true)
    else
      AgentConfig.set(a, false)
    end
  end
  for a in Task.known_agents()
    Setting.set("limit_daily_"  + a, _settings_parse_limit(form["limit_daily_"  + a]))
    Setting.set("limit_weekly_" + a, _settings_parse_limit(form["limit_weekly_" + a]))
  end
  redirect("/settings")
end

# Pull the merged-body view out of `req`, falling back across `all` /
# `form` / `json` / `params` so the same controller works for plain HTML
# form posts, JSON API calls, and the test client.
fn _settings_form(req)
  let merged = req["all"]
  if merged != nil
    return merged
  end
  let form = req["form"]
  if form != nil
    return form
  end
  let json = req["json"]
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
fn _settings_load_agents_config()
  let configs = AgentConfig.all_as_hash()
  let h = {}
  for a in Task.known_agents()
    let v = configs[a]
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
fn _settings_load_limits()
  let settings = Setting.all_as_hash()
  let h = {}
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
fn _settings_parse_limit(raw)
  if raw == nil
    return 0
  end
  let s = str(raw).trim()
  if s == ""
    return 0
  end
  let n = int(s) rescue 0
  if n < 0
    return 0
  end
  return n
end

fn _settings_known_agent(name)
  for a in Task.known_agents()
    if a == name
      return true
    end
  end
  return false
end

# Whitelist for the theme setting — the layout only knows how to render
# these two values, so anything else gets dropped on POST rather than
# silently persisting a value that produces a broken page.
fn _settings_known_theme(name)
  return name == "dark" or name == "light"
end
