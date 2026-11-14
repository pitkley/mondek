// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import {Socket} from "phoenix";
import {LiveSocket} from "phoenix_live_view";
import {PreviewFilterPicker} from "./filter_picker.mjs";

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
    this.panelSnapshots = new Map();
    this.stackDesktop = window.matchMedia("(min-width:960px)");
    this.stackAnimations = [];
    this.onStackResize = () => {
      this.clearStackHover();
      this.syncPanelSnapshots();
    };
    this.onStackPointerMove = event => {
      const hit = event.pointerType === "mouse" && event.target.closest(".preview-panel-back-hit");
      if (!hit || !this.stackDesktop.matches) return;
      clearTimeout(this.stackLeaveTimer);
      if (hit === this.stackHover) return;
      clearTimeout(this.stackHoverTimer);
      this.stackHover = hit;
      this.stackHoverTimer = setTimeout(() => {
        if (!hit.isConnected || !hit.matches(":hover")) return;
        if (this.stackReveal) delete this.stackReveal.dataset.revealed;
        this.stackReveal = hit;
        hit.dataset.revealed = "true";
      }, 220);
    };
    this.onStackPointerOut = event => {
      const hit = event.target.closest(".preview-panel-back-hit");
      if (!hit || this.stackHover !== hit || hit.contains(event.relatedTarget)) return;
      clearTimeout(this.stackHoverTimer);
      this.stackHover = null;
      // During the handoff the pointer can briefly land on a border or on the list.
      if (this.stackReveal) this.stackLeaveTimer = setTimeout(() => this.clearStackHover(), 180);
    };
    this.el.addEventListener("pointermove", this.onStackPointerMove);
    this.el.addEventListener("pointerout", this.onStackPointerOut);
    this.onPopState = () => this.capturePanel();
    this.onPanelNavigate = event => {
      if (event.target.closest("a[data-phx-link='patch']")) this.capturePanel();
    };
    this.stackDesktop.addEventListener("change", this.onStackResize);
    window.addEventListener("popstate", this.onPopState, true);
    this.trigger = this.el.querySelector(".preview-selected [data-overview-open]")?.id || null;
    this.narrow = window.matchMedia("(max-width:700px)");
    this.onResize = () => this.syncOverlay();
    this.narrow.addEventListener("change", this.onResize);
    this.onClick = event => {
      const opener = event.target.closest("[data-overview-open]");
      if (opener) this.trigger = opener.id;
      const panel = this.el.querySelector("#overview-panel");
      if (panel && !panel.contains(event.target) && !event.target.closest("[data-overview-row],a,button,.preview-theme-picker,.preview-filter-popup")) {
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
    document.addEventListener("click", this.onPanelNavigate, true);
    document.addEventListener("click", this.onClick);
    document.addEventListener("keydown", this.onKey);
    this.syncOverlay();
    if (this.el.querySelector("#overview-panel")) this.focusPanel();
    this.syncPanelSnapshots();
  },
  beforeUpdate() {
    this.previousStack = this.measureStack();
    this.searchFocused = document.activeElement?.id === "preview-search";
    this.relatedOpen = this.el.querySelector("#preview-related-results")?.open;
  },
  updated() {
    this.syncOverlay();
    this.syncPanelSnapshots();
    if (this.searchFocused && !this.el.querySelector("#overview-panel")) this.el.querySelector("#preview-search")?.focus({preventScroll: true});
    const next = this.el.dataset.selection;
    if (next === this.selection) {
      const related = this.el.querySelector("#preview-related-results");
      if (related && this.relatedOpen !== undefined) related.open = this.relatedOpen;
      return;
    }
    this.selection = next;
    this.clearStackHover();
    this.el.querySelector("#preview-related-results")?.removeAttribute("open");
    if (this.el.querySelector("#overview-panel")) {
      this.focusPanel();
      this.restorePanelPosition();
    }
    else if (this.el.querySelector("#incident-page")) this.el.querySelector("#incident-heading")?.focus();
    else if (document.activeElement?.id !== "preview-search") (document.getElementById(this.trigger) || document.getElementById(this.el.dataset.panelHeading || "overview-heading"))?.focus({preventScroll: true});
    this.animateStackChange();
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
    if (panel) document.getElementById(panel.getAttribute("aria-labelledby"))?.focus({preventScroll: true});
  },
  clearStackHover() {
    clearTimeout(this.stackHoverTimer);
    clearTimeout(this.stackLeaveTimer);
    if (this.stackReveal) delete this.stackReveal.dataset.revealed;
    this.stackReveal = null;
    this.stackHover = null;
  },
  measureStack() {
    const front = this.el.querySelector("#overview-panel");
    const positions = new Map();
    for (const card of this.el.querySelectorAll("[data-panel-back-path]")) {
      if (card.getClientRects().length) positions.set(card.dataset.panelBackPath, card.getBoundingClientRect());
    }
    if (front?.dataset.panelPath) positions.set(front.dataset.panelPath, front.getBoundingClientRect());
    return {
      positions,
      front: front && {
        path: front.dataset.panelPath,
        rect: front.getBoundingClientRect(),
        className: front.className
      }
    };
  },
  animateStackChange() {
    for (const animation of this.stackAnimations) animation.cancel();
    this.stackAnimations = [];
    this.exitPanel?.remove();
    this.exitPanel = null;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    const previous = this.previousStack;
    const front = this.el.querySelector("#overview-panel");
    const returning = front?.dataset.panelPath && previous?.positions.has(front.dataset.panelPath);
    const closing = previous?.front && !front && !this.el.querySelector("#incident-page");
    const opening = front && !previous?.front;
    const pushing = front && previous?.front?.path &&
      [...this.el.querySelectorAll("[data-panel-back-path]")].some(card => card.dataset.panelBackPath === previous.front.path);
    const motion = {duration: 150, easing: "ease-out"};

    if (returning || pushing) {
      for (const card of this.el.querySelectorAll("[data-panel-back-path]")) {
        const from = previous.positions.get(card.dataset.panelBackPath);
        if (from && card.getClientRects().length) this.moveStackCard(card, from, motion);
      }
    }

    if (returning && this.stackDesktop.matches) {
      this.moveStackCard(front, previous.positions.get(front.dataset.panelPath), motion);
    } else if (opening || pushing) {
      this.stackAnimations.push(front.animate(
        [{transform: "translateX(100%)"}, {transform: "translateX(0)"}], motion
      ));
    }

    if (closing || (returning && this.stackDesktop.matches)) this.slideOutPanel(previous.front, motion);
  },
  moveStackCard(card, from, motion) {
    // A hover reveal can still be returning when LiveView swaps the cards.
    for (const animation of card.getAnimations()) {
      if (animation.transitionProperty === "translate") animation.cancel();
    }
    const to = card.getBoundingClientRect();
    this.stackAnimations.push(card.animate([
      {
        transform: `translateX(${from.left - to.left}px)`,
        insetBlockStart: `${from.top}px`,
        insetBlockEnd: `${window.innerHeight - from.bottom}px`
      },
      {
        transform: "translateX(0)",
        insetBlockStart: `${to.top}px`,
        insetBlockEnd: `${window.innerHeight - to.bottom}px`
      }
    ], motion));
  },
  slideOutPanel(previous, motion) {
    const saved = this.panelSnapshots.get(previous?.path);
    const rect = previous?.rect;
    if (!saved || !rect || rect.left >= window.innerWidth) return;

    const exit = document.createElement("div");
    exit.className = previous.className + " preview-panel-exit";
    exit.inert = true;
    exit.setAttribute("aria-hidden", "true");
    Object.assign(exit.style, {
      inset: "auto",
      left: `${rect.left}px`,
      top: `${rect.top}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`
    });
    exit.append(saved.content.cloneNode(true));
    this.el.append(exit);
    exit.scrollTop = saved.scrollTop;
    this.exitPanel = exit;
    const animation = exit.animate(
      [{transform: "translateX(0)"}, {transform: `translateX(${window.innerWidth - rect.left}px)`}],
      motion
    );
    this.stackAnimations.push(animation);
    animation.onfinish = () => exit.remove();
  },
  capturePanel() {
    const panel = this.el.querySelector("#overview-panel[data-panel-path]");
    const body = panel?.querySelector(":scope > .pf-v6-c-card__body");
    if (!body) return;

    const content = this.copyPanelContent(body);
    const disclosures = [...body.querySelectorAll("details[id]")].map(detail => [detail.id, detail.open]);
    const path = panel.dataset.panelPath;
    this.panelSnapshots.delete(path);
    this.panelSnapshots.set(path, {content, scrollTop: panel.scrollTop, disclosures});
    // Bound the cache while allowing browser Back and Forward within the trail.
    if (this.panelSnapshots.size > 6) this.panelSnapshots.delete(this.panelSnapshots.keys().next().value);
  },
  copyPanelContent(body) {
    const content = body.cloneNode(true);
    // Snapshots are visual only. Keep them out of LiveView hooks and DOM ID lookups.
    for (const element of [content, ...content.querySelectorAll("*")]) {
      for (const name of element.getAttributeNames()) {
        if (name === "id" || /^(phx-|data-phx-|data-overview-)/.test(name)) {
          element.removeAttribute(name);
        }
      }
    }
    return content;
  },
  syncPanelSnapshots() {
    if (!this.stackDesktop.matches) return;

    for (const card of this.el.querySelectorAll("[data-panel-back-path]")) {
      const slot = card.querySelector(".preview-panel-snapshot");
      const saved = this.panelSnapshots.get(card.dataset.panelBackPath);
      const source = saved?.content || card.querySelector("template[data-panel-fallback]")?.content.textContent;
      if (slot.renderedSnapshot !== source) {
        const template = document.createElement("template");
        if (typeof source === "string") template.innerHTML = source;
        const body = saved?.content || template.content.firstElementChild;
        slot.replaceChildren(...(body ? [this.copyPanelContent(body)] : []));
        slot.renderedSnapshot = source;
      }
      slot.scrollTop = saved?.scrollTop || 0;
    }
  },
  restorePanelPosition() {
    const panel = this.el.querySelector("#overview-panel[data-panel-path]");
    const saved = panel && this.panelSnapshots.get(panel.dataset.panelPath);
    if (!saved) return;

    for (const [id, open] of saved.disclosures) {
      const disclosure = document.getElementById(id);
      if (disclosure && panel.contains(disclosure)) disclosure.open = open;
    }
    panel.scrollTop = saved.scrollTop;
  },
  destroyed() {
    this.clearStackHover();
    for (const animation of this.stackAnimations) animation.cancel();
    this.exitPanel?.remove();
    this.el.removeEventListener("pointermove", this.onStackPointerMove);
    this.el.removeEventListener("pointerout", this.onStackPointerOut);
    this.narrow.removeEventListener("change", this.onResize);
    this.el.querySelectorAll("[inert]").forEach(el => { el.inert = false; });
    this.stackDesktop.removeEventListener("change", this.onStackResize);
    window.removeEventListener("popstate", this.onPopState, true);
    document.removeEventListener("click", this.onPanelNavigate, true);
    document.removeEventListener("click", this.onClick);
    document.removeEventListener("keydown", this.onKey);
  }
};

const csrfToken = document.querySelector('meta[name="csrf-token"]').getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken}, hooks: {OverviewPanel, PreviewFilterPicker}
});
liveSocket.connect();
window.liveSocket = liveSocket;
