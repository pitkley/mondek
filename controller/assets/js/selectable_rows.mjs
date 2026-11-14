// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
// Native checkbox interaction remains the keyboard and label contract.
export const SelectableRows = {
  mounted() {
    this.onSelectRow = event => {
      if (event.defaultPrevented || event.target.closest('input, label, button, a, select, textarea, summary, [contenteditable="true"]')) return;
      const row = event.target.closest('[data-select-row]');
      if (!row || !this.el.contains(row)) return;
      const checkbox = row.querySelector('input[type="checkbox"][data-row-checkbox]');
      if (checkbox && !checkbox.disabled) checkbox.click();
    };
    this.el.addEventListener('click', this.onSelectRow);
  },
  destroyed() {
    this.el.removeEventListener('click', this.onSelectRow);
  }
};
