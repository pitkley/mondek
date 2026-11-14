// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
export const PreviewFilterPicker = {
  mounted() {
    this.input = this.el.querySelector('[role="combobox"]');
    this.open = false;
    this.listeners = new AbortController();
    const options = {signal: this.listeners.signal};
    const on = (event, callback) => this.el.addEventListener(event, callback, options);
    this.handleEvent("preview-filter-ready", ({id = "overview-search"} = {}) => {
      if (id !== this.el.id) return;
      this.input.focus({preventScroll: true});
      this.show();
    });
    on("focusin", event => {
      if (event.target !== this.input) return;
      if (this.restoringSearchFocus) {
        this.restoringSearchFocus = false;
        return;
      }
      this.show();
    });
    on("focusout", event => {
      if (event.relatedTarget && !this.el.contains(event.relatedTarget)) this.close();
    });
    on("compositionstart", event => {
      if (event.target !== this.input) return;
      this.composing = true;
      clearTimeout(this.queryTimer);
    });
    on("compositionend", event => {
      if (event.target !== this.input) return;
      this.composing = false;
      if (document.activeElement === this.input) this.queueQuery();
    });
    on("input", event => {
      if (event.target === this.input) this.queueQuery(event.isComposing);
    });
    on("pointerdown", event => {
      if (event.target.closest('[role="option"]')) event.preventDefault();
    });
    on("click", event => {
      if (event.target === this.input) this.show();
    });
    on("submit", () => {
      clearTimeout(this.queryTimer);
      if (!this.step) {
        // LiveView blurs the submitted input and restores focus after the reply.
        this.restoringSearchFocus = document.activeElement === this.input;
        this.close();
      }
    });
    on("keydown", event => this.keydown(event));
    document.addEventListener("click", event => {
      if (this.open && !this.el.contains(event.target)) this.close();
    }, options);
    this.updated();
  },
  queueQuery(composing = false) {
    this.activeOption = null;
    this.show();
    clearTimeout(this.queryTimer);
    if (!this.step || composing || this.composing) return;
    const step = this.step;
    const search = this.input.value;
    this.queryTimer = setTimeout(() => {
      if (this.open && this.step === step && this.input.value === search) {
        this.pushEvent("filter_query", {search}, () => {});
      }
    }, 100);
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
    const popup = this.el.querySelector("[data-filter-popup]");
    popup.classList.toggle("is-open", !!visible);
    const status = popup.querySelector("[role='status']");
    if (status) status.hidden = awaitingValues;
    popup.querySelector('[role="listbox"]').setAttribute("aria-busy", String(awaitingValues));
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
  moveBetweenChips(event) {
    if (!["ArrowLeft", "ArrowRight"].includes(event.key) ||
        event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return false;

    const direction = event.key === "ArrowLeft" ? -1 : 1;
    const fields = this.el.dataset.chipFields.split(" ").filter(Boolean);
    const step = this.chipMove ? this.chipMove.step : this.step;
    const index = step ? fields.indexOf(step) : fields.length;
    if (index < 0) return false;

    if (!this.chipMove) {
      const {value, selectionStart, selectionEnd} = this.input;
      const wholeChipSelected = step && selectionStart === 0 && selectionEnd === value.length;
      const boundary = direction < 0 ? 0 : value.length;
      const atBoundary = selectionStart === boundary && selectionEnd === boundary;
      if ((!wholeChipSelected && !atBoundary) || (step && value !== this.initialChipValue)) return false;
    }

    const next = index + direction;
    if (next < 0 || next > fields.length) return false;
    event.preventDefault();
    if (!step && !this.chipMove) this.draftSearch = this.input.value;

    const move = {step: fields[next]};
    this.chipMove = move;
    clearTimeout(this.queryTimer);
    const done = () => {
      if (this.chipMove === move) this.chipMove = null;
    };
    if (move.step) this.pushEvent("filter_open", {field: move.step}, done);
    else this.pushEvent("filter_close", {reopen: true}, done);
    return true;
  },
  keydown(event) {
    if (event.target !== this.input || event.isComposing || this.composing) return;
    if (this.moveBetweenChips(event)) return;
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
    this.input = this.el.querySelector('[role="combobox"]');
    const next = this.el.dataset.step;
    if (next !== this.step || this.optionValue !== this.el.dataset.value) this.activeOption = null;
    this.optionValue = this.el.dataset.value;
    if (next !== this.step) {
      clearTimeout(this.queryTimer);
      this.open = !!next;
      this.input.value = this.el.dataset.value;
      if (next) {
        this.initialChipValue = this.input.value;
        this.input.focus({preventScroll: true});
        if (this.el.dataset.editingFilter === "true") this.input.select();
      } else if (this.draftSearch !== undefined) {
        this.input.value = this.draftSearch;
        this.input.setSelectionRange(0, 0);
        this.draftSearch = undefined;
      }
    }
    if (!next && this.search !== this.el.dataset.search) this.input.value = "";
    this.step = next;
    this.search = this.el.dataset.search;
    this.renderOptions();
  },
  destroyed() {
    clearTimeout(this.queryTimer);
    this.listeners.abort();
  }
};
