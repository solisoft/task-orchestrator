# AgentConfig — per-agent enabled/disabled flag, persisted in the
# solidb `agent_configs` collection. One row per agent name
# (_key = agent name, e.g. `claude`, `opencode`); `value` holds
# whether the agent is enabled (boolean, default true when no row
# exists).
#
# Use the static helpers (`AgentConfig.get`, `AgentConfig.set`,
# `AgentConfig.get_or`, `AgentConfig.enabled_agents`) rather than
# touching the inherited Model API directly.

class AgentConfig < Model
  validates("_key", { "presence": true })

  static def get(key)
    let c = AgentConfig.find_by("_key", key)
    if c == nil
      return nil
    end
    return c.value
  end

  static def get_or(key, default_value)
    let v = AgentConfig.get(key)
    if v == nil
      return default_value
    end
    return v
  end

  static def set(key, value)
    let existing = AgentConfig.find_by("_key", key)
    if existing == nil
      return AgentConfig.create({ "_key": key, "value": value })
    end
    AgentConfig.update(key, { "value": value })
    return AgentConfig.find_by("_key", key)
  end

  # Bulk load every AgentConfig row into `{ _key: value }`. Lets
  # callers that read many keys in a loop (`enabled_agents`, the
  # settings form's per-agent checkbox state) issue one query instead
  # of N. Missing keys are simply absent from the hash; callers read
  # `hash[key] ?? default` to recover the "unset means enabled" rule.
  static def all_as_hash()
    let h = {}
    for c in AgentConfig.all()
      h[c._key] = c.value
    end
    h
  end

  static def enabled_agents(all_agents)
    let configs = AgentConfig.all_as_hash()
    let enabled = []
    for a in all_agents
      let v = configs[a]
      # Unset (`nil`) means enabled by default — the row only exists
      # once the user has explicitly flipped the agent off (or on).
      if v == nil or v != false
        enabled.push(a)
      end
    end
    enabled
  end
end