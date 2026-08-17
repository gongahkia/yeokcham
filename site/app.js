(() => {
  document.documentElement.classList.remove("no-js");

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
})();
