// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
export const PanelStack = {
  mounted() {
    this.selection = this.el.dataset.selection;
    this.panelSnapshots = new Map();
    this.modalBackground = new Map();
    this.stackDesktop = window.matchMedia("(min-width:960px)");
    this.stackAnimations = [];
    this.onStackResize = () => {
      this.clearStackReveal();
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
        this.stackReveal = hit;
        this.updateStackReveal();
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
    this.onStackFocusIn = event => {
      this.stackFocus = event.target.closest(".preview-panel-back-hit:focus-visible");
      this.updateStackReveal();
    };
    this.onStackFocusOut = event => {
      if (event.target !== this.stackFocus) return;
      this.stackFocus = null;
      this.updateStackReveal();
    };
    this.el.addEventListener("pointermove", this.onStackPointerMove);
    this.el.addEventListener("pointerout", this.onStackPointerOut);
    this.el.addEventListener("focusin", this.onStackFocusIn);
    this.el.addEventListener("focusout", this.onStackFocusOut);
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
      if (event.defaultPrevented) return;
      if (!["Escape", "Tab", "Enter", " "].includes(event.key)) {
        const hit = document.activeElement?.closest(".preview-panel-back-hit");
        if (hit && this.el.contains(hit)) {
          this.stackFocus = hit;
          this.updateStackReveal();
        }
      }
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
        if (this.revealedCard) this.clearStackReveal();
        else this.closePanel();
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
    // Release only our temporary modal changes before LiveView applies the next
    // server-owned attributes; an old inert snapshot must not override that patch.
    this.restoreBackground();
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
      this.updateStackReveal();
      const related = this.el.querySelector("#preview-related-results");
      if (related && this.relatedOpen !== undefined) related.open = this.relatedOpen;
      return;
    }
    this.selection = next;
    this.clearStackReveal();
    this.el.querySelector("#preview-related-results")?.removeAttribute("open");
    if (this.el.querySelector("#overview-panel")) {
      this.focusPanel();
      this.restorePanelPosition();
    }
    else this.focusBackground();
    this.animateStackChange();
  },
  focusBackground() {
    if (document.activeElement?.id === "preview-search") return;
    const visible = element => element && !element.closest('[hidden], [inert]') && element.getClientRects().length > 0;
    const trigger = document.getElementById(this.trigger);
    const pageHeading = this.el.querySelector('.preview-incident-page:not([inert]) h1[tabindex]');
    const fallback = document.getElementById(this.el.dataset.panelHeading || "overview-heading");
    const target = [trigger, pageHeading, fallback].find(visible);
    target?.focus({preventScroll: true});
  },
  syncOverlay() {
    const panel = this.el.querySelector("#overview-panel");
    const modal = !!panel && this.narrow.matches;
    panel?.setAttribute("aria-modal", String(modal));
    if (modal) {
      const selector = this.el.dataset.panelBackground ||
        ".preview-masthead,.preview-sidebar,.preview-heading,.preview-summary,.preview-list,.preview-skip";
      for (const element of this.el.querySelectorAll(selector)) {
        if (!this.modalBackground.has(element)) this.modalBackground.set(element, element.inert);
        element.inert = true;
      }
    } else {
      this.restoreBackground();
    }
    if (modal && !panel.contains(document.activeElement)) this.focusPanel();
  },
  restoreBackground() {
    for (const [element, inert] of this.modalBackground) element.inert = inert;
    this.modalBackground.clear();
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
    this.stackReveal = null;
    this.stackHover = null;
    this.updateStackReveal();
  },
  clearStackReveal() {
    this.stackFocus = null;
    this.clearStackHover();
  },
  updateStackReveal() {
    const card = [this.stackFocus, this.stackReveal].find(hit => hit?.isConnected);
    if (this.revealedCard && this.revealedCard !== card) delete this.revealedCard.dataset.revealed;
    if (card) card.dataset.revealed = "true";
    this.revealedCard = card;
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
    content.querySelectorAll("script, iframe, object, embed").forEach(element => element.remove());
    for (const element of [content, ...content.querySelectorAll("*")]) {
      for (const name of element.getAttributeNames()) {
        if (name === "id" || name === "autofocus" || /^(on|phx-|data-phx-|data-overview-)/.test(name)) {
          element.removeAttribute(name);
        }
      }
    }
    const selects = body.querySelectorAll("select");
    content.querySelectorAll("select").forEach((select, index) => {
      for (const [i, option] of Array.from(select.options).entries()) {
        option.selected = selects[index].options[i].selected;
      }
    });
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
    this.clearStackReveal();
    for (const animation of this.stackAnimations) animation.cancel();
    this.exitPanel?.remove();
    this.el.removeEventListener("pointermove", this.onStackPointerMove);
    this.el.removeEventListener("pointerout", this.onStackPointerOut);
    this.el.removeEventListener("focusin", this.onStackFocusIn);
    this.el.removeEventListener("focusout", this.onStackFocusOut);
    this.narrow.removeEventListener("change", this.onResize);
    this.restoreBackground();
    this.stackDesktop.removeEventListener("change", this.onStackResize);
    window.removeEventListener("popstate", this.onPopState, true);
    document.removeEventListener("click", this.onPanelNavigate, true);
    document.removeEventListener("click", this.onClick);
    document.removeEventListener("keydown", this.onKey);
  }
};
