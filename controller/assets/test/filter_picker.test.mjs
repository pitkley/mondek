// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import assert from "node:assert/strict";
import {test} from "node:test";
import {PreviewFilterPicker} from "../js/filter_picker.mjs";

function mountPicker(t) {
  const input = {
    value: "",
    focus() { document.activeElement = input; }
  };
  const el = new EventTarget();
  el.id = "results-filter";
  el.querySelector = () => input;

  const document = new EventTarget();
  document.activeElement = input;
  globalThis.document = document;
  t.after(() => { delete globalThis.document; });
  t.mock.timers.enable({apis: ["setTimeout"]});

  const requests = [];
  let ready;
  const hook = {
    ...PreviewFilterPicker,
    el,
    step: "environment",
    handleEvent(_, callback) { ready = callback; },
    pushEvent(name, payload) { requests.push({name, payload}); },
    renderOptions() {},
    updated() {}
  };
  hook.mounted();

  function inputEvent(type, detail = {}) {
    const event = new Event(type);
    Object.assign(event, detail);
    Object.defineProperty(event, "target", {value: input});
    el.dispatchEvent(event);
  }

  return {document, hook, input, inputEvent, requests, ready};
}

test("composition cancels a pending lookup and queries the finalized value", t => {
  const {input, inputEvent, requests} = mountPicker(t);
  input.value = "T";
  inputEvent("input");
  inputEvent("compositionstart");
  input.value = "東";
  inputEvent("input", {isComposing: true});
  t.mock.timers.tick(1000);
  assert.deepEqual(requests, []);

  // Some input methods do not emit a second input event after composition ends.
  input.value = "東京";
  inputEvent("compositionend");
  t.mock.timers.tick(1000);
  assert.deepEqual(requests, [{name: "filter_query", payload: {search: "東京"}}]);
});

test("destroying a picker cancels its pending lookup and removes input listeners", t => {
  const {hook, input, inputEvent, requests} = mountPicker(t);
  input.value = "Prod";
  inputEvent("input");
  hook.destroyed();
  t.mock.timers.tick(1000);

  input.value = "Staging";
  inputEvent("input");
  t.mock.timers.tick(1000);
  assert.deepEqual(requests, []);
});

test("a ready event returns focus to the addressed picker", t => {
  const {document, input, ready} = mountPicker(t);
  document.activeElement = null;
  ready({id: "incidents-filter"});
  assert.equal(document.activeElement, null);
  ready({id: "results-filter"});
  assert.equal(document.activeElement, input);
});
