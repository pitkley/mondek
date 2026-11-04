// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import {Socket} from "phoenix";
import {LiveSocket} from "phoenix_live_view";

const themeKey = "mondek-preview-theme";
const themeNames = new Set(["pearl", "clear", "mist", "linen", "original"]);
const validTheme = value => themeNames.has(value) ? value : "pearl";
const syncThemeControls = () => {
  const theme = validTheme(document.documentElement.dataset.previewTheme);
  document.querySelectorAll("[data-preview-theme-choice]").forEach(input => { input.checked = input.value === theme; });
};
const applyTheme = value => {
  document.documentElement.dataset.previewTheme = validTheme(value);
  syncThemeControls();
};
let initialTheme = "pearl";
try { initialTheme = localStorage.getItem(themeKey); } catch { /* Browser storage may be disabled. */ }
applyTheme(initialTheme);
document.addEventListener("change", event => {
  if (!event.target.matches("[data-preview-theme-choice]")) return;
  const theme = validTheme(event.target.value);
  applyTheme(theme);
  try { localStorage.setItem(themeKey, theme); } catch { /* The current tab still switches. */ }
  const picker = document.querySelector("#preview-theme-picker");
  picker?.removeAttribute("open");
  picker?.querySelector("summary")?.focus({preventScroll: true});
});
document.addEventListener("click", event => {
  if (!event.target.closest(".preview-theme-picker")) document.querySelector("#preview-theme-picker")?.removeAttribute("open");
});
document.addEventListener("keydown", event => {
  const picker = document.querySelector("#preview-theme-picker[open]");
  if (picker && event.key === "Escape") {
    event.preventDefault();
    event.stopImmediatePropagation();
    picker.removeAttribute("open");
    picker.querySelector("summary")?.focus();
  }
});
window.addEventListener("storage", event => { if (event.key === themeKey) applyTheme(event.newValue); });

const OverviewPanel = {
  mounted() {
    syncThemeControls();
    this.selection = this.el.dataset.selection;
    this.trigger = this.el.querySelector(".preview-selected [data-overview-open]")?.id || null;
    this.narrow = window.matchMedia("(max-width:700px)");
    this.onResize = () => this.syncOverlay();
    this.narrow.addEventListener("change", this.onResize);
    this.onClick = event => {
      const opener = event.target.closest("[data-overview-open]");
      if (opener) this.trigger = opener.id;
      const panel = this.el.querySelector("#overview-panel");
      if (panel && !panel.contains(event.target) && !event.target.closest("[data-overview-row],a,button,.preview-theme-picker")) {
        this.closePanel();
        return;
      }
      if (event.target.closest("a,button,input,select,textarea") || window.getSelection()?.toString()) return;
      event.target.closest("[data-overview-row]")?.querySelector("[data-overview-open]")?.click();
    };
    this.onKey = event => {
      const panel = this.el.querySelector("#overview-panel");
      if (event.key === "Tab" && panel && this.narrow.matches) {
        const controls = [...panel.querySelectorAll("a[href],button,input,select,textarea,summary,[tabindex='0']")].filter(el => !el.disabled && el.getClientRects().length);
        const first = controls[0], last = controls[controls.length - 1];
        if (!controls.includes(document.activeElement) || (event.shiftKey && document.activeElement === first) || (!event.shiftKey && document.activeElement === last)) {
          event.preventDefault();
          (event.shiftKey ? last : first)?.focus();
        }
      }
      if (event.key === "Escape" && this.el.querySelector("#overview-panel")) {
        event.preventDefault();
        this.closePanel();
      }
    };
    document.addEventListener("click", this.onClick);
    document.addEventListener("keydown", this.onKey);
    this.syncOverlay();
    if (this.el.querySelector("#overview-panel")) this.focusPanel();
  },
  beforeUpdate() {
    this.searchFocused = document.activeElement?.id === "preview-search";
    this.relatedOpen = this.el.querySelector("#preview-related-results")?.open;
  },
  updated() {
    this.syncOverlay();
    if (this.searchFocused && !this.el.querySelector("#overview-panel")) this.el.querySelector("#preview-search")?.focus({preventScroll: true});
    const next = this.el.dataset.selection;
    if (next === this.selection) {
      const related = this.el.querySelector("#preview-related-results");
      if (related && this.relatedOpen !== undefined) related.open = this.relatedOpen;
      return;
    }
    this.selection = next;
    this.el.querySelector("#preview-related-results")?.removeAttribute("open");
    if (this.el.querySelector("#overview-panel")) this.focusPanel();
    else if (document.activeElement?.id !== "preview-search") (document.getElementById(this.trigger) || document.getElementById("overview-heading"))?.focus({preventScroll: true});
  },
  syncOverlay() {
    const panel = this.el.querySelector("#overview-panel");
    const modal = !!panel && this.narrow.matches;
    panel?.setAttribute("aria-modal", String(modal));
    this.el.querySelectorAll(".preview-masthead,.preview-sidebar,.preview-heading,.preview-summary,.preview-list,.preview-skip").forEach(el => { el.inert = modal; });
    if (modal && !panel.contains(document.activeElement)) this.focusPanel();
  },
  closePanel() {
    this.el.querySelector("[data-overview-close]")?.click();
  },
  focusPanel() {
    const panel = this.el.querySelector("#overview-panel");
    if (panel) panel.scrollTop = 0;
    this.el.querySelector("#overview-panel-title")?.focus({preventScroll: true});
  },
  destroyed() {
    this.narrow.removeEventListener("change", this.onResize);
    this.el.querySelectorAll("[inert]").forEach(el => { el.inert = false; });
    document.removeEventListener("click", this.onClick);
    document.removeEventListener("keydown", this.onKey);
  }
};

const csrfToken = document.querySelector('meta[name="csrf-token"]').getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken}, hooks: {OverviewPanel}
});
liveSocket.connect();
window.liveSocket = liveSocket;
