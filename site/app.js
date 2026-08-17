(() => {
  const root = document.documentElement;
  root.classList.remove("no-js");

  const themeToggle = document.querySelector("[data-theme-toggle]");
  const storedTheme = window.localStorage.getItem("yeokcham-guide-theme");
  const preferredDark = window.matchMedia("(prefers-color-scheme: dark)").matches;

  const applyTheme = (theme) => {
    const dark = theme === "dark";
    root.dataset.theme = theme;
    themeToggle.setAttribute("aria-pressed", String(dark));
    themeToggle.querySelector(".theme-label").textContent = dark ? "Day" : "Night";
    document.querySelector("meta[name='theme-color']").content = dark ? "#10201e" : "#f6f3ed";
  };

  applyTheme(storedTheme || (preferredDark ? "dark" : "light"));

  themeToggle.addEventListener("click", () => {
    const nextTheme = root.dataset.theme === "dark" ? "light" : "dark";
    window.localStorage.setItem("yeokcham-guide-theme", nextTheme);
    applyTheme(nextTheme);
  });

  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const source = button.parentElement.querySelector("code") || button.parentElement.querySelector(".terminal-body");
      if (!source) return;

      try {
        await navigator.clipboard.writeText(source.innerText);
        const label = button.textContent;
        button.textContent = "Copied";
        button.classList.add("is-copied");
        window.setTimeout(() => {
          button.textContent = label;
          button.classList.remove("is-copied");
        }, 1800);
      } catch {
        button.textContent = "Select code";
      }
    });
  });

  const header = document.querySelector("[data-header]");
  const updateHeader = () => header.classList.toggle("is-stuck", window.scrollY > 12);
  updateHeader();
  window.addEventListener("scroll", updateHeader, { passive: true });
})();
