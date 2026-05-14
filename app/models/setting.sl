# Setting — global key/value store, persisted in the solidb `settings`
# collection. One row per setting; `_key` is the setting name (e.g.
# `agent_type`, `limit_daily_claude`) and `value` holds the payload.
#
# Use the static helpers (`Setting.get`, `Setting.set`, `Setting.get_or`)
# rather than touching the inherited Model API directly — that way a
# missing row consistently looks like `nil` (`get`) or a default
# (`get_or`), and writes always go through the upsert path so the same
# code can both create and overwrite a setting.

class Setting < Model
  validates("_key", { "presence": true })

  # Look up the value for `key`. Returns the stored value (any type), or
  # `nil` if the row doesn't exist. Callers wanting a default should
  # reach for `get_or` instead of `Setting.get(k) ?? default` so a
  # stored-but-falsy value (`0`, `""`) round-trips correctly — `??`
  # short-circuits on `nil` only, which is what we want here too.
  static def get(key)
    let s = Setting.find_by("_key", key)
    if s == nil
      return nil
    end
    return s.value
  end

  # Same as `get`, but returns `default_value` when the row is absent.
  # `get_or("limit_daily_claude", 0)` is the canonical "unlimited"
  # encoding the dashboard expects.
  static def get_or(key, default_value)
    let v = Setting.get(key)
    if v == nil
      return default_value
    end
    return v
  end

  # Bulk load every Setting row into `{ _key: value }`. Callers that
  # would otherwise issue `Setting.get_or(k, d)` N times in a loop
  # (e.g. the dashboard's per-agent daily/weekly limits) read once
  # from this hash instead, saving N-1 round-trips to solidb. Read
  # `hash[key] ?? default` to mirror `get_or`'s default-when-missing
  # semantics — `??` short-circuits on nil only, so a stored falsy 0
  # round-trips correctly.
  static def all_as_hash()
    let h = {}
    for s in Setting.all()
      h[s._key] = s.value
    end
    h
  end

  # The persisted UI theme name, or `"dark"` when nothing is set yet.
  # Sugar for the call every controller has to make to feed the layout
  # — `render("...", { ..., "theme": Setting.current_theme() })`.
  static def current_theme()
    return Setting.get_or("theme", "dark")
  end

  # Stored preset map: { "preset_name": { "css_vars": {...} }, ... }
  static def theme_presets()
    return Setting.get("theme_presets") ?? {}
  end

  # Persist a new preset or overwrite an existing one by name.
  static def set_theme_preset(name, css_vars)
    let presets = Setting.theme_presets()
    presets[name] = { "css_vars": css_vars }
    Setting.set("theme_presets", presets)
  end

  # Remove a preset by name. Returns true if it existed.
  static def remove_theme_preset(name)
    let presets = Setting.theme_presets()
    if presets[name] == nil
      return false
    end
    presets.delete(name)
    Setting.set("theme_presets", presets)
    return true
  end

  # Upsert: creates the row if missing, otherwise overwrites `value`.
  # Returns the persisted instance (or nil when the underlying update
  # didn't return one — Model.update is a static that returns the raw
  # DB response, so callers wanting the instance should re-find it).
  #
  # The update branch goes through the static `Model.update(key, hash)`
  # rather than `instance.value = v; instance.save()` because instance
  # save() on a one-field model didn't reliably persist the mutation in
  # the version of the framework this app targets — the static path
  # serialises the hash and round-trips the change correctly.
  static def set(key, value)
    let existing = Setting.find_by("_key", key)
    if existing == nil
      return Setting.create({ "_key": key, "value": value })
    end
    Setting.update(key, { "value": value })
    return Setting.find_by("_key", key)
  end
end
