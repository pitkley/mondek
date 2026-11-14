// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import {Socket} from "phoenix";
import {LiveSocket} from "phoenix_live_view";
import {PanelStack} from "./panel_stack.mjs";
import {SelectableRows} from "./selectable_rows.mjs";
import {PreviewFilterPicker} from "./filter_picker.mjs";
import {CopyPrompt, InventoryNavigation, InventoryTargetScroll} from "./workflow_hooks.mjs";

const OverviewPanel = {
  ...PanelStack,
  mounted() {
    PanelStack.mounted.call(this);
  }
};

const MaintenancePanel = {
  ...OverviewPanel,
  mounted() {
    OverviewPanel.mounted.call(this);
    this.onChoiceRowClick = event => {
      const row = event.target.closest(".preview-maintenance-choice-row");
      if (!row || event.target.closest("input, label")) return;
      row.querySelector('input[type="checkbox"]').click();
    };
    this.el.addEventListener("click", this.onChoiceRowClick);
  },
  destroyed() {
    this.el.removeEventListener("click", this.onChoiceRowClick);
    OverviewPanel.destroyed.call(this);
  },
  beforeUpdate() {
    OverviewPanel.beforeUpdate.call(this);
    const {maintenanceEntity, maintenanceSurface} = this.el.dataset;
    this.maintenancePresentation = {
      entity: maintenanceEntity,
      surface: maintenanceSurface,
      disclosures: new Map(Array.from(
        this.el.querySelectorAll(".preview-maintenance-workflow details[id]"),
        details => [details.id, details.open]
      ))
    };
  },
  updated() {
    OverviewPanel.updated.call(this);
    const previous = this.maintenancePresentation;
    const {maintenanceEntity, maintenanceSurface} = this.el.dataset;
    if (!maintenanceEntity || previous?.entity !== maintenanceEntity ||
        previous.surface === maintenanceSurface) return;
    this.el.querySelectorAll(".preview-maintenance-workflow details[id]").forEach(details => {
      if (previous.disclosures.has(details.id)) details.open = previous.disclosures.get(details.id);
    });
  }
};

const csrfToken = document.querySelector('meta[name="csrf-token"]').getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken}, hooks: {OverviewPanel, MaintenancePanel, PreviewFilterPicker, SelectableRows, CopyPrompt, InventoryNavigation, InventoryTargetScroll}
});
liveSocket.connect();
window.liveSocket = liveSocket;

// A new page receives focus; patches retain filter, form and panel intent.
window.addEventListener("phx:navigate", event => {
  if (event.detail.patch || event.detail.pop) return;
  if (document.querySelector("#overview-panel")) return;
  document.getElementById("main-content")?.focus({preventScroll: true});
});
