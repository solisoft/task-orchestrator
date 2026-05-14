# ThemePreset — custom theme presets stored in the `theme_presets`
# collection. Each row has `_key` as the preset name and `css_vars`
# holding a JSON hash of CSS variable overrides.
#
# Built-in presets (dark, light) are handled as constants in
# `Setting.current_theme()` and are not stored here.

class ThemePreset < Model
  validates("_key", { "presence": true })

  static def built_in_presets()
    return [
      {
        "_key":    "dark",
        "name":    "Dark",
        "is_default": true,
        "css_vars": {
          "--color-bg":        "#0f172a",
          "--color-text":      "#e2e8f0",
          "--color-accent":    "#6366f1",
          "--color-border":    "#334155",
          "--color-surface":   "#1e293b",
          "--color-muted":     "#64748b"
        }
      },
      {
        "_key":    "light",
        "name":    "Light",
        "is_default": true,
        "css_vars": {
          "--color-bg":        "#f8fafc",
          "--color-text":      "#0f172a",
          "--color-accent":    "#6366f1",
          "--color-border":    "#e2e8f0",
          "--color-surface":   "#ffffff",
          "--color-muted":     "#64748b"
        }
      }
    ]
  end

  static def all_with_builtins()
    return ThemePreset.built_in_presets() + ThemePreset.all()
  end
end