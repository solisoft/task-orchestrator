// Setting — key/value store for application configuration.

class Setting < Model
  validates("key", { "presence": true, "unique": true })
  validates("value", { "presence": true })

  static def get(key)
    let s = Setting.find_by("key", key)
    s == nil ? nil : s.value
  end

  static def set(key, value)
    let s = Setting.find_by("key", key)
    if s == nil
      s = Setting.create({ "key": key, "value": value })
    else
      s.value = value
      s.save()
    end
  end
end