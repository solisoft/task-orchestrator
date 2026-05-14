(function () {
  // The server is the source of truth for theme — `<html class>` and
  // `<html data-theme>` are set from Setting.current_theme() on every
  // render, and the inline head script mirrors the value to localStorage
  // so this file just has to sync the toggle button and persist clicks.

  function activeClass() {
    return document.documentElement.classList.contains("light") ? "light" : "dark";
  }

  function refreshButtons() {
    const isLight = activeClass() === "light";
    document.querySelectorAll("[data-theme-toggle]").forEach(function (btn) {
      btn.setAttribute("aria-pressed", isLight ? "true" : "false");
      btn.setAttribute(
        "aria-label",
        isLight ? "Switch to dark theme" : "Switch to light theme"
      );
    });
  }

  function persist(theme) {
    try { localStorage.setItem("theme", theme); } catch (e) {}
    // Persist server-side so the next render uses it. We reload on
    // success so every CSS-variable / class swap lands cleanly — the
    // dark↔light pair toggles a lot of utility-class colours, and
    // re-rendering is simpler than hand-swapping every node.
    const body = new FormData();
    body.append("theme", theme);
    fetch("/settings/theme", { method: "POST", body: body, credentials: "same-origin" })
      .then(function (r) {
        if (r.ok) {
          window.location.reload();
        }
      })
      .catch(function () {});
  }

  window.__toggleTheme = function () {
    persist(activeClass() === "light" ? "dark" : "light");
  };

  refreshButtons();

  document.addEventListener("click", function (e) {
    const btn = e.target.closest && e.target.closest("[data-theme-toggle]");
    if (btn) {
      e.preventDefault();
      window.__toggleTheme();
    }
  });
})();
