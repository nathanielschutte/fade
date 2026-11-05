// Drawing on a pic before it's sent (F13): pen strokes in a few colors and
// two sizes, emoji stickers you can move and resize, and undo. Everything is
// kept relative to the photo (0..1 across and down), so it lines up at any
// screen size and zoom, then flattened into the photo itself when it's sent.
// Nothing about the drawing travels separately: the pic is still one JPEG,
// encrypted like any other.
//
// A photo from the library can also be zoomed (1x to 4x) and moved before
// it's sent (X52, docs/implementation/pic-framing.md): what's sent is the part
// of the photo on screen, so recipients see what the sender saw.

export const COLORS = ["#ffffff", "#111111", "#ff4d4d", "#ffd23f", "#93c5a3", "#4da3ff"];
export const STICKERS = ["😂", "😍", "🔥", "✨", "👀", "🎉", "❤️", "🌲"];
const PEN = { thin: 0.008, thick: 0.02 }; // stroke width, as a share of the photo's width
const STICKER_SIZE = 0.16;                // a new sticker's size, the same way
const MIN_STICKER = 0.05;
const MAX_STICKER = 0.6;
const ZOOM_MAX = 4;
const MOVED_PX = 6;                       // a press that goes further is a drag, never a tap

/**
 * Wires drawing onto the camera preview. `els`: the preview <img>, the stage
 * it sits in, an overlay <canvas>, a sticker layer <div>, the toolbar's
 * controls, and `onView`, called whenever the photo's place on screen changes
 * (a resize, a zoom, a move). Returns { reset, hasMarks, flatten, ... }.
 */
export function createDrawing(els) {
  const { img, stage, canvas, layer } = els;
  const ctx = canvas.getContext("2d");
  const s = {
    pen: false, color: COLORS[2], size: "thin",
    strokes: [],          // { color, width, points: [[x, y], ...] }
    stickers: [],         // { emoji, x, y, size, el }
    undo: [],             // ["stroke", stroke] | ["sticker", sticker] | ["move", sticker, { x, y, size }]
    drawing: null,        // the stroke under the finger
    selected: null,       // the sticker last touched (resized by +/-, the wheel, or a pinch)
    // The whole photo, in the stage's coordinates: zoomed, it reaches past the stage.
    rect: { left: 0, top: 0, width: 1, height: 1 },
    // The part of it on screen (rect ∩ the stage): what's sent, and what a caption spans.
    visible: { left: 0, top: 0, width: 1, height: 1 },
    zoomable: false,      // a photo from the library (X52); one just taken isn't
    // The zoom, and the point of the photo (0..1) at the stage's middle, so a resize keeps the view.
    view: { z: 1, cx: 0.5, cy: 0.5 },
  };

  // Where the photo shows inside the stage: letterboxed (object-fit: contain),
  // then zoomed and moved, kept so no gap opens where it's larger than the stage.
  function layout() {
    const box = stage.getBoundingClientRect();
    const nw = img.naturalWidth || 1;
    const nh = img.naturalHeight || 1;
    const scale = Math.min(box.width / nw, box.height / nh);
    const base = { left: (box.width - nw * scale) / 2, top: (box.height - nh * scale) / 2, width: nw * scale, height: nh * scale };
    const { z } = s.view;
    const width = base.width * z, height = base.height * z;
    const fit = (size, room, at) => (size <= room ? (room - size) / 2 : Math.min(0, Math.max(room - size, room / 2 - at * size)));
    const left = fit(width, box.width, s.view.cx), top = fit(height, box.height, s.view.cy);
    s.view.cx = (box.width / 2 - left) / width;
    s.view.cy = (box.height / 2 - top) / height;
    s.rect = { left, top, width, height };
    const vl = Math.max(0, left), vt = Math.max(0, top);
    s.visible = { left: vl, top: vt, width: Math.min(box.width, left + width) - vl, height: Math.min(box.height, top + height) - vt };
    // The <img> fills the stage; this moves its letterboxed picture onto `rect`.
    img.style.transform = z === 1 ? "" : `translate(${left - z * base.left}px, ${top - z * base.top}px) scale(${z})`;
    // The canvas covers only what's on screen (one for the whole photo at 4x
    // would be enormous); the sticker layer is the whole photo, clipped by the stage.
    setBox(canvas, s.visible);
    setBox(layer, s.rect);
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.max(1, Math.round(s.visible.width * dpr));
    canvas.height = Math.max(1, Math.round(s.visible.height * dpr));
    redraw();
    for (const st of s.stickers) place(st);
    els.onView?.();
  }
  function setBox(el, r) {
    el.style.left = `${r.left}px`;
    el.style.top = `${r.top}px`;
    el.style.width = `${r.width}px`;
    el.style.height = `${r.height}px`;
  }

  /**
   * From where a gesture began (`from`: its zoom and the photo's rect), zooms
   * by `k` about a point on screen, which has moved by (dx, dy) since: what
   * was under it stays under it. A drag is k = 1.
   */
  function zoomAbout(from, clientX, clientY, k, dx = 0, dy = 0) {
    const box = stage.getBoundingClientRect();
    const z = Math.min(ZOOM_MAX, Math.max(1, from.z * k));
    const px = clientX - box.left, py = clientY - box.top;
    const fx = (px - dx - from.rect.left) / from.rect.width, fy = (py - dy - from.rect.top) / from.rect.height;
    const width = from.rect.width * (z / from.z), height = from.rect.height * (z / from.z);
    s.view = { z: z < 1.01 ? 1 : z, cx: (box.width / 2 - (px - fx * width)) / width, cy: (box.height / 2 - (py - fy * height)) / height };
    layout();
  }

  function strokePath(c, stroke, w, h) {
    c.strokeStyle = stroke.color;
    c.lineWidth = stroke.width * w;
    c.lineCap = "round";
    c.lineJoin = "round";
    c.beginPath();
    const [x0, y0] = stroke.points[0];
    c.moveTo(x0 * w, y0 * h);
    // A single tap still leaves a dot.
    if (stroke.points.length === 1) c.lineTo(x0 * w + 0.01, y0 * h);
    for (const [x, y] of stroke.points.slice(1)) c.lineTo(x * w, y * h);
    c.stroke();
  }

  function redraw() {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    // The canvas starts where the photo meets the stage: shift the photo's pixels to match.
    const k = canvas.width / s.visible.width;
    ctx.setTransform(1, 0, 0, 1, (s.rect.left - s.visible.left) * k, (s.rect.top - s.visible.top) * k);
    for (const stroke of s.strokes) strokePath(ctx, stroke, s.rect.width * k, s.rect.height * k);
  }

  function place(st) {
    st.el.style.left = `${st.x * 100}%`;
    st.el.style.top = `${st.y * 100}%`;
    st.el.style.fontSize = `${st.size * s.rect.width}px`;
    st.el.classList.toggle("selected", st === s.selected);
  }

  function select(st) {
    s.selected = st;
    for (const other of s.stickers) other.el.classList.toggle("selected", other === st);
    els.bigger.hidden = els.smaller.hidden = !st;
  }

  // A point on screen as a point of the photo (0..1), at whatever zoom.
  const rel = (e) => {
    const box = stage.getBoundingClientRect();
    const r = { left: box.left + s.rect.left, top: box.top + s.rect.top, width: s.rect.width, height: s.rect.height };
    return [
      Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)),
      Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)),
    ];
  };

  // ---------- pen ----------
  canvas.addEventListener("pointerdown", (e) => {
    if (!s.pen) return;
    e.preventDefault();
    if (s.drawing && s.zoomable) {
      // A second finger: it's a pinch (below), so the line the first one began isn't one.
      const begun = s.drawing;
      s.strokes = s.strokes.filter((x) => x !== begun);
      s.undo = s.undo.filter(([, item]) => item !== begun);
      s.drawing = null;
      redraw();
      changed();
      return;
    }
    canvas.setPointerCapture(e.pointerId);
    s.drawing = { color: s.color, width: PEN[s.size], points: [rel(e)] };
    s.strokes.push(s.drawing);
    s.undo.push(["stroke", s.drawing]);
    redraw();
    changed();
  });
  canvas.addEventListener("pointermove", (e) => {
    if (!s.drawing || gesture.pointers.size > 1) return;
    s.drawing.points.push(rel(e));
    redraw();
  });
  const endStroke = () => { s.drawing = null; };
  canvas.addEventListener("pointerup", endStroke);
  canvas.addEventListener("pointercancel", endStroke);

  // ---------- stickers ----------
  function addSticker(emoji) {
    const el = document.createElement("span");
    el.className = "sticker";
    el.textContent = emoji;
    el.setAttribute("role", "img");
    el.setAttribute("aria-label", `Sticker ${emoji}`);
    const st = { emoji, x: 0.5, y: 0.5, size: STICKER_SIZE, el };
    s.stickers.push(st);
    s.undo.push(["sticker", st]);
    layer.append(el);
    wireSticker(st);
    select(st);
    place(st);
    changed();
  }

  function resize(st, size) {
    st.size = Math.min(MAX_STICKER, Math.max(MIN_STICKER, size));
    place(st);
  }

  // One finger drags; a second finger anywhere pinches the sticker being dragged.
  const fingers = new Map();
  function wireSticker(st) {
    let start = null;
    st.el.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      e.stopPropagation();
      st.el.setPointerCapture(e.pointerId);
      select(st);
      fingers.set(e.pointerId, [e.clientX, e.clientY]);
      start = { x: st.x, y: st.y, size: st.size, px: e.clientX, py: e.clientY, spread: spread() };
      s.undo.push(["move", st, { x: st.x, y: st.y, size: st.size }]);
    });
    st.el.addEventListener("pointermove", (e) => {
      if (!start || !fingers.has(e.pointerId)) return;
      fingers.set(e.pointerId, [e.clientX, e.clientY]);
      if (fingers.size >= 2 && start.spread) {
        resize(st, start.size * (spread() / start.spread));
        return;
      }
      st.x = Math.min(1, Math.max(0, start.x + (e.clientX - start.px) / s.rect.width));
      st.y = Math.min(1, Math.max(0, start.y + (e.clientY - start.py) / s.rect.height));
      place(st);
    });
    const up = (e) => {
      fingers.delete(e.pointerId);
      if (!fingers.size) start = null;
    };
    st.el.addEventListener("pointerup", up);
    st.el.addEventListener("pointercancel", up);
    st.el.addEventListener("wheel", (e) => {
      e.preventDefault();
      s.undo.push(["move", st, { x: st.x, y: st.y, size: st.size }]);
      resize(st, st.size * (e.deltaY < 0 ? 1.1 : 1 / 1.1));
    }, { passive: false });
  }
  function spread() {
    const pts = [...fingers.values()];
    if (pts.length < 2) return 0;
    return Math.hypot(pts[0][0] - pts[1][0], pts[0][1] - pts[1][1]);
  }
  // A second finger landing elsewhere on the stage still pinches the selected sticker.
  stage.addEventListener("pointerdown", (e) => {
    if (s.selected && fingers.size === 1 && !s.pen) fingers.set(e.pointerId, [e.clientX, e.clientY]);
  });
  stage.addEventListener("pointermove", (e) => {
    if (!s.selected || !fingers.has(e.pointerId) || fingers.size < 2) return;
    fingers.set(e.pointerId, [e.clientX, e.clientY]);
  });
  const stageUp = (e) => fingers.delete(e.pointerId);
  stage.addEventListener("pointerup", stageUp);
  stage.addEventListener("pointercancel", stageUp);

  // ---------- zooming and moving the photo (X52) ----------
  // Two fingers pinch (and move) it; on a computer, a trackpad pinch or
  // Ctrl/Cmd with the wheel zooms where the pointer is. Once zoomed, one
  // finger (or the mouse) drags it, unless the pen or a sticker has it. A drag
  // is never a tap, so it doesn't start a caption.
  const gesture = { pointers: new Map(), from: null, moved: false, swallowClick: false };
  const owns = (e) => s.zoomable && !img.hidden && !s.selected && els.stickerTray.hidden
    && !e.target.closest?.("button, input, label, textarea, .sticker, .snap-caption-box, .draw-tools, .sticker-tray");
  function gestureStart() {
    const pts = [...gesture.pointers.values()].slice(0, 2);
    const two = pts.length > 1;
    gesture.from = {
      z: s.view.z, rect: { ...s.rect }, n: pts.length,
      mid: two ? [(pts[0][0] + pts[1][0]) / 2, (pts[0][1] + pts[1][1]) / 2] : pts[0],
      gap: two ? Math.hypot(pts[0][0] - pts[1][0], pts[0][1] - pts[1][1]) : 0,
    };
  }
  stage.addEventListener("pointerdown", (e) => {
    if (!gesture.pointers.size) {
      gesture.moved = false;
      gesture.swallowClick = false;
    }
    if (!owns(e) || (e.pointerType === "mouse" && e.button !== 0)) return;
    gesture.pointers.set(e.pointerId, [e.clientX, e.clientY]);
    // One finger is a drag only once zoomed, and never while the pen draws;
    // until then it's kept in case a second comes to pinch.
    if (gesture.pointers.size === 1 && (s.pen || s.view.z === 1)) return;
    if (gesture.pointers.size > 2) return;
    try { stage.setPointerCapture(e.pointerId); } catch { /* already gone */ }
    gestureStart();
  });
  stage.addEventListener("pointermove", (e) => {
    if (!gesture.pointers.has(e.pointerId)) return;
    gesture.pointers.set(e.pointerId, [e.clientX, e.clientY]);
    const f = gesture.from;
    if (!f) return;
    const pts = [...gesture.pointers.values()];
    if (f.n > 1 && pts.length > 1) {
      const mid = [(pts[0][0] + pts[1][0]) / 2, (pts[0][1] + pts[1][1]) / 2];
      const gap = Math.hypot(pts[0][0] - pts[1][0], pts[0][1] - pts[1][1]);
      gesture.moved = true;
      zoomAbout(f, mid[0], mid[1], f.gap ? gap / f.gap : 1, mid[0] - f.mid[0], mid[1] - f.mid[1]);
    } else if (f.n === 1 && s.view.z > 1 && !s.pen) {
      const dx = e.clientX - f.mid[0], dy = e.clientY - f.mid[1];
      if (!gesture.moved && Math.hypot(dx, dy) < MOVED_PX) return;
      gesture.moved = true;
      zoomAbout(f, e.clientX, e.clientY, 1, dx, dy);
    }
  });
  const gestureEnd = (e) => {
    if (!gesture.pointers.delete(e.pointerId)) return;
    if (gesture.moved) gesture.swallowClick = true;
    // A finger lifted from a pinch: the other one carries on, as a drag.
    if (gesture.pointers.size && gesture.from) gestureStart();
    else gesture.from = null;
  };
  stage.addEventListener("pointerup", gestureEnd);
  stage.addEventListener("pointercancel", gestureEnd);
  // The click a drag ends with isn't a tap on the photo (app.js's taps start a caption).
  stage.addEventListener("click", (e) => {
    if (!gesture.swallowClick) return;
    gesture.swallowClick = false;
    e.stopImmediatePropagation();
  }, true);
  stage.addEventListener("wheel", (e) => {
    if (!s.zoomable || img.hidden || !(e.ctrlKey || e.metaKey) || e.target.closest?.(".sticker")) return;
    e.preventDefault(); // the photo zooms, not the page
    const dy = Math.max(-30, Math.min(30, e.deltaMode === 1 ? e.deltaY * 16 : e.deltaY));
    zoomAbout({ z: s.view.z, rect: { ...s.rect } }, e.clientX, e.clientY, Math.exp(-dy * 0.01));
  }, { passive: false });
  // Safari's trackpad pinch comes as gesture events rather than the wheel.
  let safariPinch = null;
  stage.addEventListener("gesturestart", (e) => {
    if (!s.zoomable || img.hidden) return;
    e.preventDefault();
    safariPinch = { z: s.view.z, rect: { ...s.rect }, x: e.clientX, y: e.clientY };
  });
  stage.addEventListener("gesturechange", (e) => {
    if (!safariPinch) return;
    e.preventDefault();
    zoomAbout(safariPinch, safariPinch.x, safariPinch.y, e.scale);
  });
  stage.addEventListener("gestureend", () => { safariPinch = null; });

  // ---------- the toolbar ----------
  function setPen(on) {
    s.pen = on;
    canvas.classList.toggle("drawing", on);
    els.penButton.setAttribute("aria-pressed", String(on));
    els.colors.hidden = !on;
    els.sizeButton.hidden = !on;
    if (on) {
      els.stickerTray.hidden = true;
      select(null);
    }
  }
  els.penButton.addEventListener("click", () => setPen(!s.pen));
  for (const color of COLORS) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "swatch";
    b.style.background = color;
    b.setAttribute("aria-label", `Color ${color}`);
    b.setAttribute("aria-pressed", String(color === s.color));
    b.addEventListener("click", () => {
      s.color = color;
      for (const other of els.colors.children) other.setAttribute("aria-pressed", String(other === b));
    });
    els.colors.append(b);
  }
  els.sizeButton.addEventListener("click", () => {
    s.size = s.size === "thin" ? "thick" : "thin";
    els.sizeButton.textContent = s.size === "thin" ? "Thin" : "Thick";
  });
  els.stickerButton.addEventListener("click", () => {
    setPen(false);
    els.stickerTray.hidden = !els.stickerTray.hidden;
  });
  for (const emoji of STICKERS) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "sticker-pick";
    b.textContent = emoji;
    b.setAttribute("aria-label", `Add ${emoji}`);
    b.addEventListener("click", () => {
      addSticker(emoji);
      els.stickerTray.hidden = true;
    });
    els.stickerTray.append(b);
  }
  els.bigger.addEventListener("click", () => {
    if (!s.selected) return;
    s.undo.push(["move", s.selected, { x: s.selected.x, y: s.selected.y, size: s.selected.size }]);
    resize(s.selected, s.selected.size * 1.2);
  });
  els.smaller.addEventListener("click", () => {
    if (!s.selected) return;
    s.undo.push(["move", s.selected, { x: s.selected.x, y: s.selected.y, size: s.selected.size }]);
    resize(s.selected, s.selected.size / 1.2);
  });
  els.undoButton.addEventListener("click", () => {
    const last = s.undo.pop();
    if (!last) return;
    const [kind, item, prev] = last;
    if (kind === "stroke") {
      s.strokes = s.strokes.filter((x) => x !== item);
      redraw();
    } else if (kind === "sticker") {
      s.stickers = s.stickers.filter((x) => x !== item);
      item.el.remove();
      if (s.selected === item) select(null);
    } else {
      Object.assign(item, prev);
      place(item);
    }
    changed();
  });

  function changed() {
    els.undoButton.disabled = s.undo.length === 0;
  }

  new ResizeObserver(() => { if (!img.hidden) layout(); }).observe(stage);
  img.addEventListener("load", layout);

  return {
    /** A fresh photo (or retake, or closing the camera): nothing drawn, pen off, not zoomed.
     * `zoomable`: a photo from the library, which can be zoomed and moved. */
    reset({ zoomable = false } = {}) {
      s.zoomable = zoomable;
      s.view = { z: 1, cx: 0.5, cy: 0.5 };
      gesture.pointers.clear();
      gesture.from = null;
      img.style.transform = "";
      s.strokes = [];
      s.undo = [];
      for (const st of s.stickers) st.el.remove();
      s.stickers = [];
      setPen(false);
      select(null);
      els.stickerTray.hidden = true;
      changed();
      redraw();
    },
    hasMarks: () => s.strokes.length > 0 || s.stickers.length > 0,
    /** Zoomed in: only part of the photo is on screen, so only that part is sent. */
    cropped: () => s.view.z > 1,
    /** The part of the photo on screen, in the stage's coordinates. */
    visible: () => ({ ...s.visible }),
    /** Drawing, or a sticker picked: a tap on the photo is theirs, not a caption's. */
    busy: () => s.pen || Boolean(s.selected) || !els.stickerTray.hidden,
    /** Puts down the picked sticker and closes the tray. */
    settle() {
      select(null);
      els.stickerTray.hidden = true;
    },
    /**
     * The part of the photo on screen with everything drawn on it, drawn in
     * the photo's own pixels and then cropped: at most `edge` on its longest
     * side, never scaled up. Zoomed all the way out, the whole photo.
     */
    flatten(edge = Infinity) {
      const nw = img.naturalWidth, nh = img.naturalHeight;
      const crop = {
        x: ((s.visible.left - s.rect.left) / s.rect.width) * nw, y: ((s.visible.top - s.rect.top) / s.rect.height) * nh,
        w: (s.visible.width / s.rect.width) * nw, h: (s.visible.height / s.rect.height) * nh,
      };
      const scale = Math.min(1, edge / Math.max(crop.w, crop.h));
      const out = document.createElement("canvas");
      out.width = Math.max(1, Math.round(crop.w * scale));
      out.height = Math.max(1, Math.round(crop.h * scale));
      const c = out.getContext("2d");
      c.imageSmoothingQuality = "high";
      c.drawImage(img, crop.x, crop.y, crop.w, crop.h, 0, 0, out.width, out.height);
      // From here on, the whole photo's coordinates, moved so the crop's corner is at 0, 0.
      const w = nw * (out.width / crop.w), h = nh * (out.height / crop.h);
      c.translate(-crop.x * (out.width / crop.w), -crop.y * (out.height / crop.h));
      for (const stroke of s.strokes) strokePath(c, stroke, w, h);
      c.textAlign = "center";
      c.textBaseline = "middle";
      for (const st of s.stickers) {
        c.font = `${Math.round(st.size * w)}px system-ui, "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", sans-serif`;
        c.fillText(st.emoji, st.x * w, st.y * h);
      }
      return out;
    },
  };
}
