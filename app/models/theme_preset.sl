# ThemePreset — custom theme presets stored in the `theme_presets`
# collection. Each row has `_key` as the preset name and `css_vars`
# holding a JSON hash of CSS variable overrides.
#
# Built-in presets ride the `base` field — "dark" rides the default
# Tailwind dark utilities, "light" pulls in `theme-light.css`. Each
# preset extends the same set of `--color-*` CSS variables; the
# settings page previews use them, and any CSS that opts into a
# `var(--color-*)` reference picks them up across the app.

class ThemePreset < Model
  validates("_key", { "presence": true })

  static def _vars(
    bg, surface, text, muted, border,
    accent, accent_hover, link,
    success, warning, danger,
    code_bg, code_text
  )
    return {
      "--color-bg":           bg,
      "--color-surface":      surface,
      "--color-text":         text,
      "--color-muted":        muted,
      "--color-border":       border,
      "--color-accent":       accent,
      "--color-accent-hover": accent_hover,
      "--color-link":         link,
      "--color-success":      success,
      "--color-warning":      warning,
      "--color-danger":       danger,
      "--color-code-bg":      code_bg,
      "--color-code-text":    code_text
    }
  end

  static def built_in_presets()
    return [
      {
        "_key": "dark", "name": "Dark", "is_default": true, "base": "dark",
        "css_vars": ThemePreset._vars(
          "#0f172a", "#1e293b", "#e2e8f0", "#64748b", "#334155",
          "#6366f1", "#818cf8", "#a5b4fc",
          "#10b981", "#f59e0b", "#ef4444",
          "rgba(99,102,241,0.12)", "#a5b4fc"
        )
      },
      {
        "_key": "light", "name": "Light", "is_default": true, "base": "light",
        "css_vars": ThemePreset._vars(
          "#f8fafc", "#ffffff", "#0f172a", "#64748b", "#e2e8f0",
          "#6366f1", "#4f46e5", "#4338ca",
          "#059669", "#d97706", "#dc2626",
          "rgba(99,102,241,0.1)", "#4338ca"
        )
      },
      {
        "_key": "dracula", "name": "Dracula", "is_default": true, "base": "dark",
        "css_vars": ThemePreset._vars(
          "#282a36", "#21222c", "#f8f8f2", "#6272a4", "#44475a",
          "#bd93f9", "#caa9fa", "#8be9fd",
          "#50fa7b", "#f1fa8c", "#ff5555",
          "rgba(189,147,249,0.15)", "#ff79c6"
        )
      },
      {
        "_key": "monokai", "name": "Monokai", "is_default": true, "base": "dark",
        "css_vars": ThemePreset._vars(
          "#272822", "#1e1f1c", "#f8f8f2", "#75715e", "#49483e",
          "#f92672", "#fd5fa3", "#66d9ef",
          "#a6e22e", "#fd971f", "#f92672",
          "rgba(249,38,114,0.12)", "#e6db74"
        )
      },
      {
        "_key": "nord", "name": "Nord", "is_default": true, "base": "dark",
        "css_vars": ThemePreset._vars(
          "#2e3440", "#3b4252", "#eceff4", "#4c566a", "#3b4252",
          "#88c0d0", "#8fbcbb", "#81a1c1",
          "#a3be8c", "#ebcb8b", "#bf616a",
          "rgba(136,192,208,0.15)", "#d8dee9"
        )
      },
      {
        "_key": "tokyo-night", "name": "Tokyo Night", "is_default": true, "base": "dark",
        "css_vars": ThemePreset._vars(
          "#1a1b26", "#24283b", "#c0caf5", "#565f89", "#292e42",
          "#7aa2f7", "#89b4fa", "#bb9af7",
          "#9ece6a", "#e0af68", "#f7768e",
          "rgba(122,162,247,0.15)", "#c0caf5"
        )
      },
      {
        "_key": "solarized-dark", "name": "Solarized Dark", "is_default": true, "base": "dark",
        "css_vars": ThemePreset._vars(
          "#002b36", "#073642", "#93a1a1", "#586e75", "#073642",
          "#268bd2", "#2aa198", "#268bd2",
          "#859900", "#b58900", "#dc322f",
          "rgba(38,139,210,0.12)", "#93a1a1"
        )
      },
      {
        "_key": "solarized-light", "name": "Solarized Light", "is_default": true, "base": "light",
        "css_vars": ThemePreset._vars(
          "#fdf6e3", "#eee8d5", "#586e75", "#93a1a1", "#eee8d5",
          "#268bd2", "#2aa198", "#268bd2",
          "#859900", "#b58900", "#dc322f",
          "rgba(38,139,210,0.1)", "#586e75"
        )
      },
      {
        "_key": "gruvbox-dark", "name": "Gruvbox Dark", "is_default": true, "base": "dark",
        "css_vars": ThemePreset._vars(
          "#282828", "#32302f", "#ebdbb2", "#928374", "#3c3836",
          "#fabd2f", "#fe8019", "#83a598",
          "#b8bb26", "#fabd2f", "#fb4934",
          "rgba(250,189,47,0.12)", "#ebdbb2"
        )
      },
      {
        "_key": "gruvbox-light", "name": "Gruvbox Light", "is_default": true, "base": "light",
        "css_vars": ThemePreset._vars(
          "#fbf1c7", "#f2e5bc", "#3c3836", "#7c6f64", "#d5c4a1",
          "#d65d0e", "#af3a03", "#076678",
          "#79740e", "#b57614", "#9d0006",
          "rgba(214,93,14,0.1)", "#3c3836"
        )
      },
      {
        "_key": "catppuccin-mocha", "name": "Catppuccin Mocha", "is_default": true, "base": "dark",
        "css_vars": ThemePreset._vars(
          "#1e1e2e", "#181825", "#cdd6f4", "#7f849c", "#313244",
          "#cba6f7", "#b4befe", "#89b4fa",
          "#a6e3a1", "#f9e2af", "#f38ba8",
          "rgba(203,166,247,0.15)", "#f5c2e7"
        )
      },
      {
        "_key": "catppuccin-latte", "name": "Catppuccin Latte", "is_default": true, "base": "light",
        "css_vars": ThemePreset._vars(
          "#eff1f5", "#e6e9ef", "#4c4f69", "#8c8fa1", "#dce0e8",
          "#8839ef", "#7287fd", "#1e66f5",
          "#40a02b", "#df8e1d", "#d20f39",
          "rgba(136,57,239,0.1)", "#4c4f69"
        )
      },
      {
        "_key": "rose-pine", "name": "Rosé Pine", "is_default": true, "base": "dark",
        "css_vars": ThemePreset._vars(
          "#191724", "#1f1d2e", "#e0def4", "#6e6a86", "#26233a",
          "#c4a7e7", "#9ccfd8", "#ebbcba",
          "#31748f", "#f6c177", "#eb6f92",
          "rgba(196,167,231,0.15)", "#e0def4"
        )
      },
      {
        "_key": "rose-pine-dawn", "name": "Rosé Pine Dawn", "is_default": true, "base": "light",
        "css_vars": ThemePreset._vars(
          "#faf4ed", "#fffaf3", "#575279", "#797593", "#dfdad9",
          "#907aa9", "#56949f", "#d7827e",
          "#286983", "#ea9d34", "#b4637a",
          "rgba(144,122,169,0.1)", "#575279"
        )
      },
      {
        "_key": "one-dark-pro", "name": "One Dark Pro", "is_default": true, "base": "dark",
        "css_vars": ThemePreset._vars(
          "#282c34", "#21252b", "#abb2bf", "#5c6370", "#3e4451",
          "#61afef", "#56b6c2", "#c678dd",
          "#98c379", "#e5c07b", "#e06c75",
          "rgba(97,175,239,0.15)", "#d19a66"
        )
      },
      {
        "_key": "github-dark", "name": "GitHub Dark", "is_default": true, "base": "dark",
        "css_vars": ThemePreset._vars(
          "#0d1117", "#161b22", "#c9d1d9", "#8b949e", "#30363d",
          "#58a6ff", "#79c0ff", "#a5d6ff",
          "#3fb950", "#d29922", "#f85149",
          "rgba(88,166,255,0.15)", "#c9d1d9"
        )
      },
      {
        "_key": "github-light", "name": "GitHub Light", "is_default": true, "base": "light",
        "css_vars": ThemePreset._vars(
          "#ffffff", "#f6f8fa", "#24292f", "#57606a", "#d0d7de",
          "#0969da", "#0550ae", "#0a3069",
          "#1a7f37", "#9a6700", "#cf222e",
          "rgba(9,105,218,0.1)", "#24292f"
        )
      },
      {
        "_key": "cyberpunk", "name": "Cyberpunk", "is_default": true, "base": "dark",
        "css_vars": ThemePreset._vars(
          "#0a0014", "#1a0a2e", "#f8f8f2", "#ff79c6", "#ff007f",
          "#00ffea", "#bd00ff", "#ffea00",
          "#39ff14", "#fffb00", "#ff003c",
          "rgba(0,255,234,0.15)", "#ff79c6"
        )
      }
    ]
  end

  static def all_with_builtins()
    return ThemePreset.built_in_presets() + ThemePreset.all()
  end

  static def find_by_key(key)
    for p in ThemePreset.built_in_presets()
      if p["_key"] == key
        return p
      end
    end
    let custom = ThemePreset.find_by("_key", key)
    if custom == nil
      return nil
    end
    return {
      "_key":       custom._key,
      "name":       custom.name,
      "is_default": false,
      "base":       (custom.base ?? "dark"),
      "css_vars":   custom.css_vars
    }
  end
end
