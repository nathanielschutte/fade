// Drawing on a pic before it's sent (F13): pen strokes in a few colors and
// two sizes, emoji stickers you can move and resize, and undo. Everything is
// kept relative to the photo (0..1 across and down), so it lines up at any
// screen size, then flattened into the photo itself when it's sent. Nothing
// about the drawing travels separately: the pic is still one JPEG, encrypted
// like any other.

export const COLORS = ["#ffffff", "#111111", "#ff4d4d", "#ffd23f", "#93c5a3", "#4da3ff"];
export const STICKERS = ["😂", "😍", "🔥", "✨", "👀", "🎉", "❤️", "🌲"];
const PEN = { thin: 0.008, thick: 0.02 }; // stroke width, as a share of the photo's width
const STICKER_SIZE = 0.16;                // a new sticker's size, the same way
const MIN_STICKER = 0.05;
const MAX_STICKER = 0.6;

/**
 * Wires drawing onto the camera preview. `els`: the preview <img>, the stage
 * it sits in, an overlay <canvas>, a sticker layer <div>, and the toolbar's
 * controls. Returns { reset, hasMarks, flatten }.
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
    rect: { left: 0, top: 0, width: 1, height: 1 },
  };

  // Where the photo actually shows inside the stage (it's letterboxed: object-fit: contain).
  function layout() {
    const box = stage.getBoundingClientRect();
    const nw = img.naturalWidth || 1;
    const nh = img.naturalHeight || 1;
    const scale = Math.min(box.width / nw, box.height / nh);
    const width = nw * scale;
    const height = nh * scale;
    s.rect = { left: (box.width - width) / 2, top: (box.height - height) / 2, width, height };
    for (const el of [canvas, layer]) {
      el.style.left = `${s.rect.left}px`;
      el.style.top = `${s.rect.top}px`;
      el.style.width = `${width}px`;
      el.style.height = `${height}px`;
    }
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.max(1, Math.round(width * dpr));
    canvas.height = Math.max(1, Math.round(height * dpr));
    redraw();
    for (const st of s.stickers) place(st);
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
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    for (const stroke of s.strokes) strokePath(ctx, stroke, canvas.width, canvas.height);
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

  const rel = (e) => {
    const r = canvas.getBoundingClientRect();
    return [
      Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)),
      Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)),
    ];
  };

  // ---------- pen ----------
  canvas.addEventListener("pointerdown", (e) => {
    if (!s.pen) return;
    e.preventDefault();
    canvas.setPointerCapture(e.pointerId);
    s.drawing = { color: s.color, width: PEN[s.size], points: [rel(e)] };
    s.strokes.push(s.drawing);
    s.undo.push(["stroke", s.drawing]);
    redraw();
    changed();
  });
  canvas.addEventListener("pointermove", (e) => {
    if (!s.drawing) return;
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
    /** A fresh photo (or retake, or closing the camera): nothing drawn, pen off. */
    reset() {
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
    /** Drawing, or a sticker picked: a tap on the photo is theirs, not a caption's. */
    busy: () => s.pen || Boolean(s.selected) || !els.stickerTray.hidden,
    /** Puts down the picked sticker and closes the tray. */
    settle() {
      select(null);
      els.stickerTray.hidden = true;
    },
    /** The photo with everything drawn on it, at the photo's own size. */
    flatten() {
      const out = document.createElement("canvas");
      out.width = img.naturalWidth;
      out.height = img.naturalHeight;
      const c = out.getContext("2d");
      c.drawImage(img, 0, 0);
      for (const stroke of s.strokes) strokePath(c, stroke, out.width, out.height);
      c.textAlign = "center";
      c.textBaseline = "middle";
      for (const st of s.stickers) {
        c.font = `${Math.round(st.size * out.width)}px system-ui, "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", sans-serif`;
        c.fillText(st.emoji, st.x * out.width, st.y * out.height);
      }
      return out;
    },
  };
}
