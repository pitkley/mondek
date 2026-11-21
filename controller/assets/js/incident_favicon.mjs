// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
const link = document.getElementById("mondek-favicon");
if (link) {
  const base = link.getAttribute("href");
  const mark = new Image();
  let count = 0;

  function draw() {
    link.dataset.openAlerts = String(count);
    if (!count || !mark.complete || !mark.naturalWidth) {
      link.href = base;
      return;
    }

    const icon = document.createElement("canvas");
    icon.width = icon.height = 64;
    const context = icon.getContext("2d");
    if (!context) return;
    context.drawImage(mark, 0, 0, 64, 64);
    const label = count > 99 ? "99+" : String(count);
    context.font = `bold ${label.length > 2 ? 22 : 28}px system-ui`;
    const width = Math.max(35, context.measureText(label).width + 10);
    const left = 64 - width;
    context.fillStyle = "#9e1b23";
    context.beginPath();
    context.roundRect(left, 31, width, 33, 10);
    context.fill();
    context.fillStyle = "#fff";
    context.textAlign = "center";
    context.textBaseline = "middle";
    context.fillText(label, left + width / 2, 48);
    link.href = icon.toDataURL("image/png");
  }

  mark.addEventListener("load", draw);
  mark.src = base;
  window.addEventListener("phx:open-alert-count", ({detail}) => {
    if (!Number.isSafeInteger(detail.count) || detail.count < 0) return;
    count = detail.count;
    draw();
  });
}
