# Settings — global app config (active agent + per-agent run caps).
# Backed by the `Setting` key/value model.

fn show(req)
  render("settings/show", {
    "title": "Settings",
    "agent_type": Setting.get_or("agent_type", Task.known_agents()[0]),
    "agents": Task.known_agents(),
    "agents_config": _settings_load_agents_config(),
    "limits": _settings_load_limits()
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
fn _settings_load_agents_config()
  let h = {}
  for a in Task.known_agents()
    h[a] = AgentConfig.get_or(a, true)
  end
  h
end

# { "claude": { "daily": N, "weekly": N }, ... } — every known agent
# is present (zero-filled) so the view can iterate without nil-checking.
fn _settings_load_limits()
  let h = {}
  for a in Task.known_agents()
    h[a] = {
      "daily":  Setting.get_or("limit_daily_"  + a, 0),
      "weekly": Setting.get_or("limit_weekly_" + a, 0)
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
