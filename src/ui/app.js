// SPDX-License-Identifier: PMPL-1.0-or-later
// SPDX-File-Origin: codegen
//
// Readable source for the paint.type web UI behaviour. For increment 0
// the shipped artifact is the self-contained index.html with this script
// inlined; keep this file in step with the <script> block there by hand.
//
// The UI captures pointer and control input, sends each as a Command over
// window.__gossamer_invoke("dispatch", ...), and blits the dirty rectangle
// the core returns. Gossamer injects the IPC bridge at document-end, so the
// page MUST wait for it (waitForBridge) before issuing new_doc; calling out
// before the bridge exists silently creates no document and nothing paints.
(function () {
  "use strict";
  const canvas = document.getElementById("canvas");
  const ctx = canvas.getContext("2d");
  const status = document.getElementById("status");
  const colourEl = document.getElementById("colour");
  const sizeEl = document.getElementById("size");
  const sizeVal = document.getElementById("size-val");
  const dot = document.getElementById("brush-dot");
  const DOC_W = canvas.width, DOC_H = canvas.height;

  function bridgeReady() { return typeof window.__gossamer_invoke === "function"; }

  function invoke(payload) {
    if (!bridgeReady()) return Promise.reject(new Error("Gossamer runtime unavailable"));
    return window.__gossamer_invoke("dispatch", payload);
  }

  function hexToRgba(hex) {
    return {
      r: parseInt(hex.slice(1, 3), 16) / 255,
      g: parseInt(hex.slice(3, 5), 16) / 255,
      b: parseInt(hex.slice(5, 7), 16) / 255,
      a: 1.0
    };
  }

  // Show what the current brush actually looks like: a soft disc of the
  // chosen diameter in the chosen colour, so size is legible before painting.
  function updatePreview() {
    const d = Number(sizeEl.value);
    sizeVal.textContent = d + " px";
    dot.style.width = d + "px";
    dot.style.height = d + "px";
    dot.style.background = "radial-gradient(circle, " + colourEl.value + " 0%, " +
      colourEl.value + " 35%, transparent 70%)";
  }

  function blit(dirty) {
    if (!dirty) return;
    const bytes = Uint8ClampedArray.from(atob(dirty.rgba_base64), (c) => c.charCodeAt(0));
    ctx.putImageData(new ImageData(bytes, dirty.w, dirty.h), dirty.x, dirty.y);
  }

  function canvasPos(ev) {
    const rect = canvas.getBoundingClientRect();
    return {
      x: (ev.clientX - rect.left) * (DOC_W / rect.width),
      y: (ev.clientY - rect.top) * (DOC_H / rect.height)
    };
  }

  async function waitForBridge() {
    for (let i = 0; i < 200 && !bridgeReady(); i++) {
      await new Promise((r) => setTimeout(r, 25));
    }
    return bridgeReady();
  }

  async function boot() {
    updatePreview();
    if (!(await waitForBridge())) {
      status.textContent = "IPC bridge unavailable - is this running inside Gossamer?";
      return;
    }
    await invoke({ cmd: "new_doc", w: DOC_W, h: DOC_H });
    const c = hexToRgba(colourEl.value);
    await invoke({ cmd: "set_colour", r: c.r, g: c.g, b: c.b, a: c.a });
    await invoke({ cmd: "set_brush", diameter: Number(sizeEl.value) });
    status.textContent = "Ready - drag on the canvas to paint.";
  }

  colourEl.addEventListener("input", () => {
    updatePreview();
    const c = hexToRgba(colourEl.value);
    invoke({ cmd: "set_colour", r: c.r, g: c.g, b: c.b, a: c.a }).catch(() => {});
  });
  sizeEl.addEventListener("input", () => {
    updatePreview();
    invoke({ cmd: "set_brush", diameter: Number(sizeEl.value) }).catch(() => {});
  });

  // Coalesce pointer moves: keep only the latest position and run at most one
  // invoke in flight, so a fast drag never queues behind the IPC channel. The
  // core interpolates between samples, so dropping intermediate moves is lossless.
  let painting = false;
  let pendingMove = null;
  let draining = false;

  async function drainMoves() {
    if (draining) return;
    draining = true;
    while (pendingMove !== null) {
      const p = pendingMove;
      pendingMove = null;
      try {
        const res = await invoke({ cmd: "pointer_move", x: p.x, y: p.y });
        if (res && res.ok === "painted") blit(res.dirty);
      } catch (e) { /* ignore */ }
    }
    draining = false;
  }

  canvas.addEventListener("pointerdown", async (ev) => {
    if (!bridgeReady()) return;
    painting = true;
    canvas.setPointerCapture(ev.pointerId);
    const p = canvasPos(ev);
    try {
      const res = await invoke({ cmd: "pointer_down", x: p.x, y: p.y });
      if (res && res.ok === "painted") blit(res.dirty);
    } catch (e) { /* ignore */ }
  });
  canvas.addEventListener("pointermove", (ev) => {
    if (!painting) return;
    pendingMove = canvasPos(ev);
    drainMoves();
  });
  canvas.addEventListener("pointerup", async () => {
    if (!painting) return;
    painting = false;
    while (draining || pendingMove !== null) {
      await new Promise((r) => setTimeout(r, 4));
      drainMoves();
    }
    try { await invoke({ cmd: "pointer_up" }); } catch (e) { /* ignore */ }
  });

  document.getElementById("save").addEventListener("click", async () => {
    if (!bridgeReady()) { status.textContent = "Cannot save - bridge unavailable."; return; }
    let path = "/tmp/painting.png";
    try {
      const chosen = await window.__gossamer_invoke("__gossamer_dialog_save", { defaultPath: path });
      if (chosen && typeof chosen === "string") path = chosen;
    } catch (e) { /* fall back to default path */ }
    const res = await invoke({ cmd: "save_png", path });
    status.textContent = (res && res.ok === "saved") ? "Saved " + res.path : "Save failed";
  });

  window.addEventListener("load", boot);
})();
