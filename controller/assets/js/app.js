// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import {Socket} from "phoenix";
import {LiveSocket} from "phoenix_live_view";

const CopyPrompt = {
  mounted() {
    this.copying = false;
    this.onPromptClick = async (event) => {
      const copy = event.target.closest("[data-copy-prompt]");
      const select = event.target.closest("[data-select-prompt]");
      if ((!copy && !select) || this.copying) return;
      const field = this.el.querySelector("[data-prompt-text]");
      if (!field) return;

      if (select) {
        field.focus();
        field.select();
        this.setPromptStatus("Prompt selected. Press Command+C or Ctrl+C to copy.");
        return;
      }

      const content = field.value;
      this.copying = true;
      copy.disabled = true;
      this.setPromptStatus("Copying prompt…");
      try {
        if (!navigator.clipboard?.writeText) throw new Error("Clipboard unavailable");
        await navigator.clipboard.writeText(content);
        if (this.el.isConnected) {
          const current = this.el.querySelector("[data-prompt-text]");
          this.setPromptStatus(current?.value === content
            ? "Prompt copied. Review it before sharing with your agent."
            : "The earlier prompt was copied. Copy again to include the updated context.");
        }
      } catch (_error) {
        if (this.el.isConnected) {
          const current = this.el.querySelector("[data-prompt-text]");
          current?.focus();
          current?.select();
          this.setPromptStatus("Clipboard unavailable. Prompt selected; press Command+C or Ctrl+C to copy.");
        }
      } finally {
        this.copying = false;
        const button = this.el.querySelector("[data-copy-prompt]");
        if (button) button.disabled = false;
      }
    };
    this.el.addEventListener("click", this.onPromptClick);
  },
  updated() {
    if (this.copying) {
      const button = this.el.querySelector("[data-copy-prompt]");
      if (button) button.disabled = true;
    }
  },
  destroyed() {
    this.el.removeEventListener("click", this.onPromptClick);
  },
  setPromptStatus(message) {
    const status = this.el.querySelector("[data-copy-status]");
    if (status) status.textContent = message;
  }
};

const InventoryNavigation = {
  mounted() {
    this.pendingPage = null;
    this.onPageRequest = (event) => {
      this.pendingPage = event.detail.path;
    };
    this.onInteraction = (event) => {
      // A later interaction wins over a slow pager response. Keep intent while
      // activating a pager, but never interrupt someone editing another control.
      if (!event.target?.closest?.(this.el.dataset.pageControls || "#inventory-pagination-top, #inventory-pagination-bottom")) {
        this.pendingPage = null;
      }
    };
    this.onNavigate = (event) => {
      const requested = this.pendingPage;
      this.pendingPage = null;
      if (!requested || !event.detail.patch || event.detail.pop) return;
      const destination = new URL(event.detail.href, window.location.href);
      if (destination.pathname + destination.search !== requested
          || this.el.dataset.pagePath !== requested) return;
      this.el.focus({preventScroll: true});
      this.el.scrollIntoView({block: "start"});
    };
    this.el.addEventListener("mondek:inventory-page", this.onPageRequest);
    window.addEventListener("phx:navigate", this.onNavigate);
    for (const type of ["focusin", "pointerdown", "input"]) {
      document.addEventListener(type, this.onInteraction);
    }
  },
  disconnected() {
    this.pendingPage = null;
  },
  reconnected() {
    this.pendingPage = null;
  },
  destroyed() {
    this.pendingPage = null;
    this.el.removeEventListener("mondek:inventory-page", this.onPageRequest);
    window.removeEventListener("phx:navigate", this.onNavigate);
    for (const type of ["focusin", "pointerdown", "input"]) {
      document.removeEventListener(type, this.onInteraction);
    }
  }
};

// The group index is independent from the selected results. Keep its position
// through live updates and detail navigation; only a new index filter resets it.
const InventoryTargetScroll = {
  mounted() {
    this.indexScope = this.el.dataset.indexScope;
    this.requestedPage = null;
    this.onScroll = () => {
      this.rememberScroll();
      this.loadMoreNearEnd();
    };
    this.el.addEventListener("scroll", this.onScroll, {passive: true});
    this.restoreScroll();
  },
  beforeUpdate() {
    this.scrollTop = this.el.scrollTop;
    this.indexScope = this.el.dataset.indexScope;
    this.loadButtonFocused = document.activeElement?.id === "inventory-load-more-groups";
  },
  updated() {
    this.el.scrollTop = this.indexScope === this.el.dataset.indexScope ? this.scrollTop || 0 : 0;
    this.rememberScroll();
    if (this.requestedPage !== this.pageKey()) this.requestedPage = null;
    if (this.loadButtonFocused && !this.el.querySelector("#inventory-load-more-groups")) {
      this.el.querySelector("#inventory-group-loader")?.focus({preventScroll: true});
    }
  },
  pageKey() {
    return this.el.dataset.indexScope + ":" + this.el.dataset.loaded;
  },
  loadMoreNearEnd() {
    if (this.el.dataset.hasMore !== "true" || this.requestedPage === this.pageKey()) return;
    if (this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight > 120) return;
    this.requestedPage = this.pageKey();
    this.pushEvent("load_more_groups", {});
  },
  rememberScroll() {
    try {
      const stored = JSON.parse(sessionStorage.getItem("mondek:group-scroll") || "{}");
      delete stored[this.el.dataset.indexScope];
      stored[this.el.dataset.indexScope] = this.el.scrollTop;
      const bounded = Object.fromEntries(Object.entries(stored).slice(-20));
      sessionStorage.setItem("mondek:group-scroll", JSON.stringify(bounded));
    } catch (_) { /* Storage may be unavailable; in-place updates still preserve scroll. */ }
  },
  restoreScroll() {
    try {
      const stored = JSON.parse(sessionStorage.getItem("mondek:group-scroll") || "{}");
      this.el.scrollTop = Number(stored[this.el.dataset.indexScope]) || 0;
    } catch (_) { /* Leave the first entry visible when storage is unavailable. */ }
  },
  reconnected() {
    this.requestedPage = null;
  },
  destroyed() {
    this.rememberScroll();
    this.el.removeEventListener("scroll", this.onScroll);
  }
};

const csrfToken = document.querySelector('meta[name="csrf-token"]').getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {CopyPrompt, InventoryNavigation, InventoryTargetScroll}
});
liveSocket.connect();

window.addEventListener("phx:page-loading-start", () => document.documentElement.classList.add("loading"));
window.addEventListener("phx:page-loading-stop", () => document.documentElement.classList.remove("loading"));
window.addEventListener("phx:navigate", (event) => {
  // Result paging has its own post-patch focus target. Other result filters,
  // including page size, keep focus on the control the operator is using.
  if (event.detail.patch
      && document.querySelector('[phx-hook="InventoryNavigation"]')) return;
  document.getElementById("main-content")?.focus({preventScroll: true});
});

window.liveSocket = liveSocket;
