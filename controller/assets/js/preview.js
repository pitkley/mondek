// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import {Socket} from "phoenix";
import {LiveSocket} from "phoenix_live_view";
import {PanelStack} from "./panel_stack.mjs";
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
  ...PanelStack,
  mounted() {
    syncThemeControls();
    PanelStack.mounted.call(this);
  }
};

const csrfToken = document.querySelector('meta[name="csrf-token"]').getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken}, hooks: {OverviewPanel, PreviewFilterPicker}
});
liveSocket.connect();
window.liveSocket = liveSocket;
