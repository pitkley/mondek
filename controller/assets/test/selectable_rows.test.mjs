// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import test from 'node:test';
import assert from 'node:assert/strict';
import {SelectableRows} from '../js/selectable_rows.mjs';

function fixture() {
  let handler;
  let changes = 0;
  const checkbox = {disabled: false, click() { changes++; }};
  const row = {querySelector() { return checkbox; }};
  const el = {
    contains: target => target === row,
    addEventListener(_, callback) { handler = callback; },
    removeEventListener(_, callback) { if (handler === callback) handler = null; }
  };
  const hook = {el};
  SelectableRows.mounted.call(hook);
  const click = ({interactive = false, outside = false, prevented = false} = {}) => handler?.({defaultPrevented: prevented, target: {closest(selector) { return selector === '[data-select-row]' ? (outside ? {} : row) : (interactive ? {} : null); }}});
  return {hook, checkbox, click, changes: () => changes};
}

test('row text selects its checkbox while labels and other controls retain native behavior', () => {
  const f = fixture();
  f.click();
  assert.equal(f.changes(), 1);
  f.click({interactive: true});
  f.click({outside: true});
  f.click({prevented: true});
  assert.equal(f.changes(), 1);
  f.checkbox.disabled = true;
  f.click();
  assert.equal(f.changes(), 1);
});

test('destroyed selection hosts no longer handle row clicks', () => {
  const f = fixture();
  SelectableRows.destroyed.call(f.hook);
  f.click();
  assert.equal(f.changes(), 0);
});
