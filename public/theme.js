(function () {
  const STORAGE_KEY = "theme";

  function readPreferred() {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved === "light" || saved === "dark" || saved.startsWith("custom:"))
      return saved;
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches
      ? "light"
      : "dark";
  }

  function apply(theme) {
    const root = document.documentElement;
    root.classList.toggle("light", theme === "light");
    root.classList.toggle("dark", theme !== "light");
    document.querySelectorAll("[data-theme-toggle]").forEach(function (btn) {
      btn.setAttribute("aria-pressed", theme === "light" ? "true" : "false");
      btn.setAttribute(
        "aria-label",
        theme === "light" ? "Switch to dark theme" : "Switch to light theme"
      );
    });
  }

  window.__setTheme = function (theme) {
    localStorage.setItem(STORAGE_KEY, theme);
    apply(theme);
  };

  window.__toggleTheme = function () {
    const next = document.documentElement.classList.contains("light") ? "dark" : "light";
    window.__setTheme(next);
  };

  apply(readPreferred());

  document.addEventListener("click", function (e) {
    const btn = e.target.closest && e.target.closest("[data-theme-toggle]");
    if (btn) {
      e.preventDefault();
      window.__toggleTheme();
    }
  });
})();
