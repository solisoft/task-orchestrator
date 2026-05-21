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
  validates("_key", {"presence": true})

  # SoliKV cache TTL for memoized Setting.get reads (seconds). Settings
  # change rarely — theme, plan_model, agent caps — so a 5-minute TTL
  # cuts the "FOR doc IN settings FILTER doc._key == ..." round-trip on
  # most page renders to a single cache hit. Writes go through `set`
  # below, which invalidates the cache key explicitly so a freshly-set
  # value is visible immediately, not after the TTL expires.
  static def _cache_ttl_seconds()
    300
  end

  static def _cache_key(key)
    "_setting:" + key
  end

  # Sentinel for "the row exists but holds nil/missing" so a cached
  # absence still short-circuits the DB lookup. Cache.get returns nil
  # for both "not in cache" and "cached as nil" — those need to be
  # distinguishable.
  static def _cache_miss_sentinel()
    "__setting_nil__"
  end

  # Look up the value for `key`. Returns the stored value (any type), or
  # `nil` if the row doesn't exist. Callers wanting a default should
  # reach for `get_or` instead of `Setting.get(k) ?? default` so a
  # stored-but-falsy value (`0`, `""`) round-trips correctly — `??`
  # short-circuits on `nil` only, which is what we want here too.
  #
  # Memoized via SoliKV `Cache.*` with a short TTL — same key is reused
  # across workers so a write in any process invalidates all caches.
  # `Setting.set` punches the key out on write; readers see the new
  # value on the next call. Settings written outside the model API
  # (direct AQL, manual DB writes) bypass invalidation and stay stale
  # until the TTL expires — that's the documented contract.
  static def get(key)
    cached = Cache.get(Setting._cache_key(key)) rescue nil
    if cached.present?
      return nil if cached == Setting._cache_miss_sentinel()
      return cached
    end
    s = Setting.find_by("_key", key)
    value = (s.nil?) ? nil : s.value
    stash = (value.nil?) ? Setting._cache_miss_sentinel() : value
    Cache.set(Setting._cache_key(key), stash, Setting._cache_ttl_seconds()) rescue null
    return value
  end

  # Same as `get`, but returns `default_value` when the row is absent.
  # `get_or("limit_daily_claude", 0)` is the canonical "unlimited"
  # encoding the dashboard expects.
  static def get_or(key, default_value)
    v = Setting.get(key)
    return default_value if v.nil?
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
    h = {}
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

  # CSS variables for the currently-active preset — built-in or custom.
  # Layouts inline these onto `:root` so utility classes that opt into
  # `var(--color-bg)` etc. flip with the preset. Views can't reach the
  # model layer directly (see CLAUDE.md), so every controller calls this
  # and threads the hash through `render()` as `theme_css_vars`.
  static def current_theme_css_vars()
    preset = ThemePreset.find_by_key(Setting.current_theme())
    return {} if preset.nil?
    return preset["css_vars"]
  end

  # "dark" or "light" — which baseline stylesheet the active preset
  # rides. Goes onto `<html class>` so Tailwind's `dark:` utilities and
  # `theme-light.css` overrides keep working when a preset like
  # "Dracula" or "GitHub Light" is selected.
  static def current_theme_class()
    preset = ThemePreset.find_by_key(Setting.current_theme())
    return "dark" if preset.nil?
    base = preset["base"] ?? "dark"
    return "light" if base == "light"
    return "dark"
  end

  # Stored preset map: { "preset_name": { "css_vars": {...} }, ... }
  static def theme_presets()
    return Setting.get("theme_presets") ?? {}
  end

  # Persist a new preset or overwrite an existing one by name.
  static def set_theme_preset(name, css_vars)
    presets = Setting.theme_presets()
    presets[name] = {"css_vars": css_vars}
    Setting.set("theme_presets", presets)
  end

  # Remove a preset by name. Returns true if it existed.
  static def remove_theme_preset(name)
    presets = Setting.theme_presets()
    return false if presets[name].nil?
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

    # Punch the cache key BEFORE the write so a concurrent reader can't
    # repopulate the cache from the stale row in the gap between the
    # write completing and the cache invalidation. Worst-case repopulate
    # races read the new value off disk — never the old one off cache.
    Cache.delete(Setting._cache_key(key)) rescue null
    existing = Setting.find_by("_key", key)
    if existing.nil?
      created = Setting.create({
        "_key": key,
        "value": value
      })
      Cache.delete(Setting._cache_key(key)) rescue null
      return created
    end
    Setting.update(key, {"value": value})
    Cache.delete(Setting._cache_key(key)) rescue null
    return Setting.find_by("_key", key)
  end

  # Drop a key from the DB and from the cache. Symmetric with `set`.
  static def unset(key)
    Cache.delete(Setting._cache_key(key)) rescue null
    existing = Setting.find_by("_key", key)
    return false if existing.nil?
    existing.delete()
    Cache.delete(Setting._cache_key(key)) rescue null
    return true
  end

  # Drop every row and punch every key out of the cache. Override so test
  # `before_each(Setting.delete_all())` doesn't leave cached values
  # behind that would shadow a freshly-cleared DB. `Cache.clear()` wipes
  # the whole namespace — Setting is the only cache user in this app, and
  # tests want a hard reset between specs, so the broad sweep is fine.
  static def delete_all()
    Cache.clear() rescue null
    @sdbql{ FOR doc IN settings REMOVE doc IN settings }
  end
end
