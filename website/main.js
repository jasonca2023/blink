// Blink landing — interactions

// current year
document.getElementById("year").textContent = new Date().getFullYear();

// reveal — one orchestrated entrance per element as it enters the viewport
const revealEls = document.querySelectorAll(".stage, .cap, .install-step, .req");
revealEls.forEach((el) => el.classList.add("reveal"));

if ("IntersectionObserver" in window && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) {
          e.target.classList.add("in");
          io.unobserve(e.target);
        }
      });
    },
    { threshold: 0.15, rootMargin: "0px 0px -40px 0px" }
  );
  revealEls.forEach((el) => io.observe(el));
} else {
  revealEls.forEach((el) => el.classList.add("in"));
}

// DMG availability — the binary is served locally; if it isn't there yet,
// guide the visitor instead of handing them a broken download.
(async function checkDmg() {
  const link = document.getElementById("dmg-link");
  const label = document.getElementById("dmg-label");
  const status = document.getElementById("dmg-status");
  const url = link.getAttribute("href");

  const setUnavailable = () => {
    link.classList.add("disabled");
    link.removeAttribute("href");
    link.setAttribute("aria-disabled", "true");
    label.textContent = "Build not available yet";
    status.innerHTML =
      'No <code>Blink.dmg</code> in <code>downloads/</code> yet. ' +
      "Build it from source in Xcode, then run <code>./build-dmg.sh</code> to package it here.";
    link.addEventListener("click", (e) => e.preventDefault());
  };

  // file:// can't be probed reliably — leave the link live and optimistic.
  if (location.protocol === "file:") {
    status.textContent = "macOS 14.2+ · drag Blink to your Applications folder";
    return;
  }

  try {
    const res = await fetch(url, { method: "HEAD", cache: "no-store" });
    if (!res.ok) return setUnavailable();
    const size = Number(res.headers.get("content-length"));
    const mb = size ? ` · ${(size / 1048576).toFixed(0)} MB` : "";
    status.textContent = `macOS 14.2+ · drag Blink to Applications${mb}`;
  } catch {
    setUnavailable();
  }
})();
