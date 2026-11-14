// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import test from 'node:test';
import { PanelStack } from '../js/panel_stack.mjs';

function globals(t, values) {
  const originals = Object.fromEntries(
    Object.keys(values).map(name => [name, Object.getOwnPropertyDescriptor(globalThis, name)])
  );
  for (const [name, value] of Object.entries(values)) {
    Object.defineProperty(globalThis, name, { configurable: true, value });
  }
  t.after(() => {
    for (const [name, descriptor] of Object.entries(originals)) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else delete globalThis[name];
    }
  });
}

function hoverLink() {
  return {
    dataset: {},
    isConnected: true,
    closest(selector) { return selector.startsWith('.preview-panel-back-hit') ? this : null; },
    contains: () => false,
    matches: () => true,
  };
}

test('the reveal survives a seam crossing and Escape dismisses it before navigating', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const docHandlers = {};
  const handlers = {};
  const media = { matches: true, addEventListener() {}, removeEventListener() {} };
  globals(t, {
    document: {
      addEventListener(name, fn) { docHandlers[name] = fn; },
      removeEventListener(name) { delete docHandlers[name]; },
    },
    window: { matchMedia: () => media, addEventListener() {}, removeEventListener() {} },
  });
  let closed = 0;
  let mounted = true;
  const hook = {
    ...PanelStack,
    el: {
      dataset: {},
      addEventListener(name, fn) { handlers[name] = fn; },
      removeEventListener(name) { delete handlers[name]; },
      querySelector(selector) { return selector === '#overview-panel' && mounted ? {} : null; },
      querySelectorAll: () => [],
    },
    syncOverlay() {},
    syncPanelSnapshots() {},
    focusPanel() {},
    closePanel() { closed += 1; },
  };
  hook.mounted();

  const bottom = hoverLink();
  const middle = hoverLink();
  const move = target => handlers.pointermove({ pointerType: 'mouse', target });
  const leave = target => handlers.pointerout({ target, relatedTarget: null });
  move(bottom);
  t.mock.timers.tick(219);
  assert.equal(bottom.dataset.revealed, undefined);
  t.mock.timers.tick(1);
  assert.equal(bottom.dataset.revealed, 'true');

  leave(bottom);
  t.mock.timers.tick(100);
  move(middle);
  t.mock.timers.tick(219);
  assert.equal(bottom.dataset.revealed, 'true');
  assert.equal(middle.dataset.revealed, undefined);
  t.mock.timers.tick(1);
  assert.equal(bottom.dataset.revealed, undefined);
  assert.equal(middle.dataset.revealed, 'true');

  const escape = { key: 'Escape', preventDefault() {} };
  docHandlers.keydown(escape);
  assert.equal(middle.dataset.revealed, undefined);
  assert.equal(closed, 0);
  docHandlers.keydown(escape);
  assert.equal(closed, 1);

  move(bottom);
  mounted = false;
  hook.destroyed();
  t.mock.timers.tick(220);
  assert.equal(bottom.dataset.revealed, undefined);
  assert.deepEqual(Object.keys(handlers), []);
  assert.deepEqual(Object.keys(docHandlers), []);
});

test('a return starts from the existing rear card, with its previous inset', (t) => {
  globals(t, { window: { innerHeight: 720, matchMedia: () => ({ matches: false }) } });
  const make = (path, left, top = 0) => ({
    dataset: { panelPath: path, panelBackPath: path },
    getBoundingClientRect: () => ({ left, top, bottom: 720 - top }),
    getClientRects: () => [1],
    getAnimations: () => [],
    animate(frames) {
      this.frames = frames;
      return { cancel() {} };
    },
  });
  const front = make('/member', 600);
  const rear = make('/shared', 552, 8);
  const departing = { path: '/result', rect: { left: 1232 } };
  const hook = {
    ...PanelStack,
    el: { querySelector: () => front, querySelectorAll: () => [rear] },
    stackDesktop: { matches: true },
    stackAnimations: [],
    previousStack: {
      front: departing,
      positions: new Map([
        ['/member', make('/member', 552, 8).getBoundingClientRect()],
        ['/shared', make('/shared', 504, 16).getBoundingClientRect()],
      ]),
    },
    slideOutPanel(panel) { this.departing = panel; },
  };
  hook.animateStackChange();

  assert.deepEqual(front.frames[0], {
    transform: 'translateX(-48px)', insetBlockStart: '8px', insetBlockEnd: '8px',
  });
  assert.equal(front.frames[1].insetBlockStart, '0px');
  assert.equal(rear.frames[0].insetBlockStart, '16px');
  assert.equal(rear.frames[1].insetBlockStart, '8px');
  assert.equal(hook.departing, departing);
});

test('promotion skips the hidden editor opener and focuses the active full page', t => {
  const focused = [];
  const element = (name, hidden = false) => ({closest: () => hidden ? {} : null, getClientRects: () => hidden ? [] : [1], focus: () => focused.push(name)});
  const trigger = element('hidden editor', true);
  const heading = element('full result');
  globals(t, {document: {activeElement: {}, getElementById: id => id === 'opener' ? trigger : heading}});
  const hook = {...PanelStack, trigger: 'opener', el: {dataset: {panelHeading: 'full-result-heading'}, querySelector: () => heading}};
  hook.focusBackground();
  assert.deepEqual(focused, ['full result']);
});

test('closing evidence restores a visible opener and keeps search focus when already there', t => {
  const focused = [];
  const trigger = {closest: () => null, getClientRects: () => [1], focus: () => focused.push('opener')};
  globals(t, {document: {activeElement: {}, getElementById: () => trigger}});
  const hook = {...PanelStack, trigger: 'opener', el: {dataset: {}, querySelector: () => null}};
  hook.focusBackground();
  assert.deepEqual(focused, ['opener']);
  document.activeElement = {id: 'preview-search'};
  hook.focusBackground();
  assert.deepEqual(focused, ['opener']);
});


test('a server patch owns inert after temporary modal background changes are released', t => {
  const owner = {inert: true};
  globals(t, {document: {activeElement: {id: ''}}});
  const hook = {
    ...PanelStack,
    modalBackground: new Map([[owner, true]]),
    measureStack: () => null,
    el: {querySelector: () => null, dataset: {}},
    narrow: {matches: true},
  };
  hook.beforeUpdate();
  assert.equal(hook.modalBackground.size, 0);
  // The server removes its own inactive-owner attribute when the trail closes.
  owner.inert = false;
  hook.syncOverlay();
  assert.equal(owner.inert, false);
});
