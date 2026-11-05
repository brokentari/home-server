// Collapses long queues on service cards behind a "More..." button. Re-applies whenever
// Homepage redraws.
(() => {
  const SHOW = 4;                        // queue items shown before "More..."
  const expanded = new Set();            // cards the viewer opened (until the page reloads)

  // A queue item is the widget's progress-bar row (see Homepage's QueueEntry component)
  const isQueueItem = (el) =>
    el.tagName === "DIV" && ["relative", "h-5", "rounded-md", "m-1"].every((c) => el.classList.contains(c));

  function apply() {
    for (const card of document.querySelectorAll("li.service[data-name]")) {
      const name = card.dataset.name;
      const stats = card.querySelector(".service-container");
      if (!stats) continue;
      const box = stats.parentElement;
      const items = [...box.children].filter(isQueueItem);
      let button = box.querySelector(":scope > .queue-more");
      const hidden = items.length - SHOW;
      const open = expanded.has(name);

      items.forEach((el, i) => {
        const display = hidden > 0 && !open && i >= SHOW ? "none" : "";
        if (el.style.display !== display) el.style.display = display;
      });
      if (hidden <= 0) {
        button?.remove();
        continue;
      }
      if (!button) {
        button = document.createElement("button");
        button.type = "button";
        button.className = "queue-more";
        button.addEventListener("click", (e) => {
          e.preventDefault();
          e.stopPropagation();
          expanded.has(name) ? expanded.delete(name) : expanded.add(name);
          apply();
        });
      }
      const label = open ? "Show less" : `More... (${hidden})`;
      if (button.textContent !== label) button.textContent = label;
      const last = items[items.length - 1];
      if (last.nextSibling !== button) last.after(button);   // keep it under the list
    }
  }

  let queued = false;
  new MutationObserver(() => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      apply();
    });
  }).observe(document.body, { childList: true, subtree: true });
  apply();
})();
