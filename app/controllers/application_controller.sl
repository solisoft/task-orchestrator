# Shared base for every app controller. Framework's `Controller` is
# auto-loaded and supplies routing/render plumbing; this layer adds
# the theme locals the application layout reads on every page render,
# so individual actions don't have to repeat the three Setting lookups.

class ApplicationController < Controller
  static {
    this.before_action = fn(req) {
      @theme          = Setting.current_theme()
      @theme_css_vars = Setting.current_theme_css_vars()
      @theme_class    = Setting.current_theme_class()
    }
  }
end
