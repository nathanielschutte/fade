// Draws a friend graph (docs/implementation/friend-graph.md) as SVG, with its groups
// outlined, a legend, and a list view. The app's own friend map and the
// admin graph both use it; the math is in /graph.js (shared/graph/graph.js).
// No inline styles or scripts (the CSP forbids them): classes, attributes,
// and CSSOM only.

import { clusters, hull, layout } from "/graph.js";

const SVG = "http://www.w3.org/2000/svg";
const LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
/** Only the three largest groups get a color: a fourth hue isn't distinguishable from these for every pair. */
const COLORED = 3;
const PAD = 16; // how far a group's outline reaches past its people

function svg(tag, attrs = {}) {
  const node = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs)) if (v != null) node.setAttribute(k, v);
  return node;
}

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (v == null || v === false) continue;
    if (k === "class") node.className = v;
    else if (k === "text") node.textContent = v;
    else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v);
  }
  for (const c of children.flat()) if (c != null) node.append(c);
  return node;
}

export const groupLetter = (i) => (i < LETTERS.length ? LETTERS[i] : `${i + 1}`);

/** Group chats (`?chats=1`) are nodes too: a chat's name only reaches its members. */
export const isChat = (n) => n.kind === "chat";
export const chatName = (n) => n.name || "A group chat";
/** "3 people" */
export const chatSummary = (n) => `${n.size} ${n.size === 1 ? "person" : "people"}`;

/** The people and friendships in a graph, leaving out group chats and their lines. */
export function counts(graph) {
  const chats = new Set(graph.nodes.filter(isChat).map((n) => n.key));
  return {
    people: graph.nodes.length - chats.size,
    friendships: graph.edges.filter(([a, b]) => !chats.has(a) && !chats.has(b)).length,
    chats: chats.size,
  };
}
const groupClass = (i) => (i >= 0 && i < COLORED ? `gc${i}` : "gcx");

/** "ana, ben, cal and 4 more" */
function names(list, max = 5) {
  if (list.length <= max) return list.join(", ");
  return `${list.slice(0, max).join(", ")} and ${list.length - max} more`;
}

/**
 * Whether `host` has changed width since it was last drawn. Phones fire
 * resize events as the address bar slides in and out; only a new width is
 * worth a redraw (which would replay the entrance and drop the selection).
 */
export function widthChanged(host) {
  return Math.max(280, Math.round(host.clientWidth || 600)) !== Number(host.dataset.width);
}

/**
 * Draws `graph` into `host` (emptied first).
 * - `center`: a key pinned in the middle and left out of grouping (a person's own map).
 * - `label(node)`: the name to show ("" for none).
 * - `describe(node, info)`: what to say when someone is picked: text or elements.
 *   `info` has `neighbors` (nodes) and `group` (index, -1 alone).
 * - `title`: what the picture is, for screen readers.
 * - `unknownNote`: legend text for "?" nodes, if any.
 * Group chats (kind "chat") are drawn as small squares lined to their
 * members, and left out of grouping: groups are about who knows who.
 * Returns { select(key) }.
 */
export function drawGraph(host, graph, { center = null, label = () => "", describe = null, title = "Friend graph", unknownNote = null } = {}) {
  const chatKeys = graph.nodes.filter(isChat).map((n) => n.key);
  const groups = clusters(graph, { ignore: [...(center ? [center] : []), ...chatKeys] });
  const pos = layout(graph, { groups, pin: center });
  const byKey = new Map(graph.nodes.map((n) => [n.key, n]));
  const neighbors = new Map(graph.nodes.map((n) => [n.key, new Set()]));
  for (const [a, b] of graph.edges) {
    neighbors.get(a)?.add(b);
    neighbors.get(b)?.add(a);
  }

  // Fit the layout to the box: as wide as it is, as tall as the shape needs.
  const W = Math.max(280, Math.round(host.clientWidth || 600));
  const xs = [...pos.values()].map((p) => p.x);
  const ys = [...pos.values()].map((p) => p.y);
  const [minX, maxX, minY, maxY] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
  const margin = W < 480 ? 46 : 70; // room for names at the edges
  const bw = Math.max(maxX - minX, 1);
  const bh = Math.max(maxY - minY, 1);
  const tallest = W < 480 ? Math.round(W * 1.2) : Math.min(Math.round(W * 0.7), 640);
  const scale = Math.min((W - 2 * margin) / bw, (tallest - 2 * margin) / bh, 3);
  const H = Math.round(Math.max(220, bh * scale + 2 * margin));
  const ox = (W - bw * scale) / 2;
  const oy = (H - bh * scale) / 2;
  const at = (key) => {
    const p = pos.get(key);
    return { x: ox + (p.x - minX) * scale, y: oy + (p.y - minY) * scale };
  };
  const mid = { x: W / 2, y: H / 2 };

  const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, class: "graph-svg", role: "img", "aria-label": title });
  const hulls = svg("g", { class: "gfade" });
  const lines = svg("g", { class: "gfade" });
  const dots = svg("g");
  root.append(hulls, lines, dots);

  // Group outlines: each group's convex hull, drawn with a wide round stroke
  // so it reads as a soft padded region; the letter sits above it.
  groups.groups.forEach((keys, i) => {
    const pts = hull(keys.map(at));
    const d = pts.map((p, j) => `${j ? "L" : "M"}${p.x.toFixed(1)},${p.y.toFixed(1)}`).join("") + (pts.length > 2 ? "Z" : "");
    hulls.append(svg("path", { d, class: `ghull ${groupClass(i)}` }));
    const top = pts.reduce((a, b) => (b.y < a.y ? b : a));
    const letter = svg("text", { x: top.x, y: Math.max(14, top.y - PAD - 6), class: `glabel ${groupClass(i)}`, "text-anchor": "middle" });
    letter.textContent = groupLetter(i);
    hulls.append(letter);
  });

  const lineFor = new Map(graph.nodes.map((n) => [n.key, []]));
  for (const [a, b] of graph.edges) {
    if (!byKey.has(a) || !byKey.has(b)) continue;
    const p = at(a);
    const q = at(b);
    const kind = isChat(byKey.get(a)) || isChat(byKey.get(b)) ? " to-chat"
      : a === center || b === center ? " from-center"
      : byKey.get(a).kind === "unknown" || byKey.get(b).kind === "unknown" ? " to-unknown" : "";
    const line = svg("line", { x1: p.x.toFixed(1), y1: p.y.toFixed(1), x2: q.x.toFixed(1), y2: q.y.toFixed(1), class: `gedge${kind}` });
    lines.append(line);
    lineFor.get(a).push(line);
    lineFor.get(b).push(line);
  }

  // Which names fit: the center and chosen people first, then the best
  // connected; a name that would overlap one already placed (or someone
  // else's dot) waits to be shown until its person is highlighted.
  const placed = [];
  const showName = new Set();
  // Dots shrink a little with the picture (phones), never below 60%.
  const shrink = Math.min(1, Math.max(0.6, scale / 1.6));
  const radius = (n) => shrink * (n.key === center ? 13 : n.kind === "unknown" ? 6 : isChat(n) ? 7 : 7 + Math.min(5, (neighbors.get(n.key).size - 1) * 0.6));
  // People's names before chats' names.
  const priority = (n) => (n.key === center ? 3 : n.kind === "seed" ? 2 : isChat(n) ? 0 : 1) * 1000 + neighbors.get(n.key).size;
  // Only chats you're in have a name to show.
  const nameOf = (n) => (isChat(n) ? n.name || "" : label(n));
  const named = graph.nodes.filter((n) => n.kind !== "unknown" && nameOf(n)).sort((a, b) => priority(b) - priority(a));
  const dotsAt = graph.nodes.map((n) => ({ ...at(n.key), r: radius(n), key: n.key }));
  for (const n of named) {
    const p = at(n.key);
    const r = radius(n);
    const w = nameOf(n).length * 6.6 + 4;
    const right = p.x >= W / 2 || n.key === center;
    const box = { x0: right ? p.x + r + 3 : p.x - r - 3 - w, x1: right ? p.x + r + 3 + w : p.x - r - 3, y0: p.y - 8, y1: p.y + 8 };
    const hits = (b) => !(b.x1 < box.x0 || b.x0 > box.x1 || b.y1 < box.y0 || b.y0 > box.y1);
    const onDot = dotsAt.some((d) => d.key !== n.key && hits({ x0: d.x - d.r, x1: d.x + d.r, y0: d.y - d.r, y1: d.y + d.r }));
    if (placed.some(hits) || onDot || box.x0 < 2 || box.x1 > W - 2) continue;
    placed.push(box);
    showName.add(n.key);
  }

  const dotFor = new Map();
  for (const n of graph.nodes) {
    const p = at(n.key);
    const g = groups.of.get(n.key) ?? -1;
    const unknown = n.kind === "unknown";
    const chat = isChat(n);
    const isCenter = n.key === center;
    const r = radius(n);
    const name = unknown ? "" : nameOf(n);
    const node = svg("g", {
      class: `gnode ${unknown ? "unknown" : chat ? "chat" : isCenter ? "center" : n.kind === "seed" ? "seed" : ""} ${groupClass(g)} enter`,
      tabindex: unknown ? null : "0",
      role: unknown ? null : "button",
      "aria-label": unknown ? null : chat ? `Group chat: ${chatName(n)}` : name,
    });
    // A chat is a rounded square, so it never reads as a person.
    node.append(chat
      ? svg("rect", { x: -r, y: -r, width: 2 * r, height: 2 * r, rx: 2.5, class: "gdot" })
      : svg("circle", { r, class: "gdot" }));
    // A bigger, invisible circle on top to tap: dots are small for fingers.
    if (!unknown) node.append(svg("circle", { r: Math.max(r + 6, 14), class: "ghit" }));
    if (unknown) {
      const q = svg("text", { class: "gq", "text-anchor": "middle", dy: "0.35em" });
      q.textContent = "?";
      node.append(q);
    } else if (name) {
      // Names on the outer side of their node, so they collide less.
      const right = p.x >= W / 2 || isCenter;
      const text = svg("text", { class: `gname${showName.has(n.key) ? "" : " quiet"}`, x: right ? r + 5 : -(r + 5), dy: "0.35em", "text-anchor": right ? "start" : "end" });
      text.textContent = name;
      node.append(text);
    }
    // Start at the middle, then ease out to place (unless motion is reduced; see style.css).
    node.style.transform = `translate(${mid.x}px, ${mid.y}px)`;
    node.dataset.x = p.x.toFixed(1);
    node.dataset.y = p.y.toFixed(1);
    dots.append(node);
    dotFor.set(n.key, node);
  }

  const caption = el("p", { class: "graph-caption", role: "status" });
  let selected = null;
  function light(key) {
    root.classList.toggle("has-focus", key != null);
    for (const [k, node] of dotFor) node.classList.toggle("lit", key != null && (k === key || neighbors.get(key).has(k)));
    for (const line of lines.children) line.classList.remove("lit");
    if (key != null) for (const line of lineFor.get(key)) line.classList.add("lit");
  }
  function select(key) {
    selected = key;
    light(key);
    const n = key != null ? byKey.get(key) : null;
    if (!n || !describe) {
      caption.replaceChildren();
      return;
    }
    const said = describe(n, { neighbors: [...neighbors.get(key)].map((k) => byKey.get(k)), group: groups.of.get(key) ?? -1 });
    caption.replaceChildren(...[said].flat());
  }
  for (const [key, node] of dotFor) {
    node.addEventListener("click", (e) => { e.stopPropagation(); select(selected === key ? null : key); });
    node.addEventListener("pointerenter", (e) => { if (e.pointerType === "mouse") light(key); });
    node.addEventListener("pointerleave", (e) => { if (e.pointerType === "mouse") light(selected); });
    node.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); select(key); }
    });
    node.addEventListener("focus", () => light(key));
    node.addEventListener("blur", () => light(selected));
  }
  root.addEventListener("click", () => select(null));

  // Legend: each group, its letter and color, and its people.
  const shown = (keys) => keys.map((k) => byKey.get(k)).filter((n) => n.kind !== "unknown").map(label).filter(Boolean);
  const strangers = (keys) => keys.filter((k) => byKey.get(k).kind === "unknown").length;
  const groupLine = (keys, i) => {
    const people = shown(keys);
    const extra = strangers(keys);
    const who = [people.length ? names(people) : null, extra ? `${extra} you don't know` : null].filter(Boolean).join(", plus ");
    return el("li", { class: "legend-row" },
      el("span", { class: `legend-key ${groupClass(i)}`, "aria-hidden": "true", text: groupLetter(i) }),
      el("span", {}, el("b", { text: `Group ${groupLetter(i)}` }), ` · ${who}`));
  };
  const legend = el("ul", { class: "graph-legend" }, groups.groups.map(groupLine));
  const alone = shown(groups.alone);
  if (alone.length) legend.append(el("li", { class: "legend-row" }, el("span", { class: "legend-key gcx", "aria-hidden": "true", text: "·" }), el("span", {}, el("b", { text: "On their own" }), ` · ${names(alone)}`)));
  const unknownCount = graph.nodes.filter((n) => n.kind === "unknown").length;
  if (unknownCount && unknownNote) legend.append(el("li", { class: "legend-row" }, el("span", { class: "legend-key unknown", "aria-hidden": "true", text: "?" }), el("span", { text: unknownNote(unknownCount) })));
  const chats = graph.nodes.filter(isChat);
  const chatNames = chats.filter((n) => n.name).map((n) => n.name);
  const unnamed = chats.length - chatNames.length;
  if (chats.length) {
    const what = [chatNames.length ? names(chatNames) : null, unnamed ? `${unnamed} you're not in` : null].filter(Boolean).join(", plus ");
    legend.append(el("li", { class: "legend-row" }, el("span", { class: "legend-key chat", "aria-hidden": "true" }), el("span", {}, el("b", { text: chats.length === 1 ? "Group chat" : "Group chats" }), ` · ${what}`)));
  }
  const membersOf = (n) => [...neighbors.get(n.key)].map((k) => byKey.get(k)).map(label).filter(Boolean);

  // The same, in full, as a list.
  const list = el("details", { class: "graph-list" },
    el("summary", { text: "Show as list" }),
    el("ul", {},
      groups.groups.map((keys, i) => el("li", {}, el("b", { text: `Group ${groupLetter(i)}: ` }),
        [shown(keys).join(", "), strangers(keys) ? `${shown(keys).length ? " and " : ""}${strangers(keys)} you don't know` : ""].join(""))),
      alone.length ? el("li", {}, el("b", { text: "On their own: " }), alone.join(", ")) : null,
      chats.map((n) => el("li", {}, el("b", { text: `${chatName(n)} (group chat): ` }),
        [membersOf(n).join(", "), n.others ? `${membersOf(n).length ? " and " : ""}${n.others} more` : ""].join(""))),
      el("li", { class: "muted", text: (({ people, friendships, chats: c }) => `${people} people, ${friendships} friendships${c ? `, ${c} group ${c === 1 ? "chat" : "chats"}` : ""}`)(counts(graph)) })));

  host.replaceChildren(el("div", { class: "graph" }, root, caption, legend, list));
  host.dataset.width = String(W);

  // Ease everyone out from the middle, then bring in the outlines and lines.
  requestAnimationFrame(() => requestAnimationFrame(() => {
    for (const node of dotFor.values()) {
      node.classList.remove("enter");
      node.style.transform = `translate(${node.dataset.x}px, ${node.dataset.y}px)`;
    }
    hulls.classList.add("shown");
    lines.classList.add("shown");
  }));

  return { select, groups };
}
