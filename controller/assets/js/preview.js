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

const OverviewFilterPicker = {
  mounted() {
    this.input = this.el.querySelector("#preview-search");
    this.open = false;
    this.handleEvent("overview-filter-ready", () => {
      this.input.focus({preventScroll: true});
      this.show();
    });
    this.el.addEventListener("focusin", event => {
      if (event.target !== this.input) return;
      if (this.restoringSearchFocus) {
        this.restoringSearchFocus = false;
        return;
      }
      this.show();
    });
    this.el.addEventListener("focusout", event => {
      if (event.relatedTarget && !this.el.contains(event.relatedTarget)) this.close();
    });
    this.el.addEventListener("input", event => {
      if (event.target !== this.input) return;
      this.activeOption = null;
      this.show();
      clearTimeout(this.queryTimer);
      if (!this.step || event.isComposing) return;
      const step = this.step;
      const search = this.input.value;
      this.queryTimer = setTimeout(() => {
        if (this.open && this.step === step && this.input.value === search) {
          this.pushEvent("filter_query", {search});
        }
      }, 100);
    });
    this.el.addEventListener("pointerdown", event => {
      if (event.target.closest('[role="option"]')) event.preventDefault();
    });
    this.el.addEventListener("click", event => {
      if (event.target === this.input) this.show();
    });
    this.el.addEventListener("submit", () => {
      clearTimeout(this.queryTimer);
      if (!this.step) {
        // LiveView blurs the submitted input and restores focus after the reply.
        this.restoringSearchFocus = document.activeElement === this.input;
        this.close();
      }
    });
    this.el.addEventListener("keydown", event => this.keydown(event));
    this.onOutside = event => {
      if (this.open && !this.el.contains(event.target)) this.close();
    };
    document.addEventListener("click", this.onOutside);
    this.updated();
  },
  show() {
    this.open = true;
    this.renderOptions();
  },
  close() {
    if (!this.open) return;
    clearTimeout(this.queryTimer);
    this.open = false;
    if (this.step) this.pushEvent("filter_close", {});
    this.renderOptions();
  },
  awaitingValues() {
    return !!this.step && this.input.value !== this.el.dataset.value;
  },
  renderOptions() {
    const query = this.input.value.trim().toLowerCase();
    const awaitingValues = this.awaitingValues();
    const options = [...this.el.querySelectorAll('[role="option"]')];
    for (const option of options) {
      option.hidden = awaitingValues || (option.dataset.searchText !== undefined ? !query :
        !!option.dataset.filterLabel && !option.dataset.filterLabel.toLowerCase().includes(query));
    }
    const available = options.filter(option => !option.hidden);
    const active = this.open && (available.includes(this.activeOption)
      ? this.activeOption
      : this.step && available[0]);
    this.selectOption(active || null);
    const visible = this.open && (this.step || options.some(option => !option.hidden));
    this.el.querySelector("#overview-filter-popup").classList.toggle("is-open", !!visible);
    const status = this.el.querySelector("#overview-filter-popup [role='status']");
    if (status) status.hidden = awaitingValues;
    this.el.querySelector("#overview-filter-options").setAttribute("aria-busy", String(awaitingValues));
    this.input.setAttribute("aria-expanded", String(!!visible));
  },
  selectOption(option) {
    this.activeOption = option;
    this.el.querySelectorAll('[role="option"]').forEach(item =>
      item.setAttribute("aria-selected", String(item === option))
    );
    if (option) this.input.setAttribute("aria-activedescendant", option.id);
    else this.input.removeAttribute("aria-activedescendant");
  },
  keydown(event) {
    if (event.target !== this.input || event.isComposing) return;
    if (event.key === "Escape" && this.input.getAttribute("aria-expanded") === "true") {
      event.preventDefault();
      event.stopPropagation();
      this.close();
      return;
    }
    if (event.key === "Backspace" && this.step) {
      const editingFilter = this.el.dataset.editingFilter === "true";
      const wholeValueSelected = this.input.selectionStart === 0 &&
        this.input.selectionEnd === this.input.value.length;
      if (this.input.value === "" || (editingFilter && wholeValueSelected)) {
        event.preventDefault();
        if (this.open && !event.repeat) {
          clearTimeout(this.queryTimer);
          if (editingFilter) this.pushEvent("filter_remove_edit", {});
          else this.pushEvent("filter_close", {reopen: true});
        }
        return;
      }
    }
    if (event.key === "Backspace" && !this.step && this.input.value === "") {
      const chip = [...this.el.querySelectorAll(".preview-filter-chip")].at(-1);
      const action = chip?.querySelector("button, a");
      if (action) {
        event.preventDefault();
        if (!event.repeat) action.click();
      }
      return;
    }
    const arrow = event.key === "ArrowDown" || event.key === "ArrowUp";
    if (arrow && !this.open) this.show();
    if (!this.open || this.awaitingValues()) return;

    const options = [...this.el.querySelectorAll('[role="option"]:not([hidden])')];
    if (!options.length) return;
    const active = options.indexOf(this.activeOption);
    if (event.key === "Enter") {
      const option = options[active] || (!this.step &&
        this.input.value.trim() && options.find(item => item.dataset.filterLabel));
      if (option) {
        event.preventDefault();
        option.click();
      }
    } else if (arrow) {
      event.preventDefault();
      const next = event.key === "ArrowDown"
        ? (active + 1) % options.length
        : (active < 0 ? options.length - 1 : (active - 1 + options.length) % options.length);
      this.selectOption(options[next]);
      options[next].scrollIntoView({block: "nearest"});
    }
  },
  updated() {
    const next = this.el.dataset.step;
    if (next !== this.step || this.optionValue !== this.el.dataset.value) this.activeOption = null;
    this.optionValue = this.el.dataset.value;
    if (next !== this.step) {
      clearTimeout(this.queryTimer);
      this.open = !!next;
      this.input.value = this.el.dataset.value;
      if (next) {
        this.input.focus({preventScroll: true});
        if (this.el.dataset.editingFilter === "true") this.input.select();
      }
    }
    if (!next && this.search !== this.el.dataset.search) this.input.value = "";
    this.step = next;
    this.search = this.el.dataset.search;
    this.renderOptions();
  },
  destroyed() {
    clearTimeout(this.queryTimer);
    document.removeEventListener("click", this.onOutside);
  }
};

const csrfToken = document.querySelector('meta[name="csrf-token"]').getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken}, hooks: {OverviewPanel, OverviewFilterPicker}
});
liveSocket.connect();
window.liveSocket = liveSocket;
