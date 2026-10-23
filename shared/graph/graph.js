// The friend map's graph tech (docs/friend-graph.md): finding groups of
// friends, laying a graph out, and outlining groups. Plain math, no DOM, so
// every client can use it (the web app gets it as /graph.js).
//
// A graph is { nodes: [{ key, ... }], edges: [[keyA, keyB], ...] }.

/** A small, fast, seeded random generator (mulberry32): same seed, same numbers. */
export function random(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** A 32-bit hash of a string (FNV-1a), for seeding from a graph's keys. */
export function hash(text) {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 0x01000193);
  return h >>> 0;
}

/**
 * Louvain community detection on an undirected graph of `n` nodes. Returns
 * each node's community. Deterministic: nodes are visited in order, and a
 * node only moves for a strictly better gain.
 */
function louvain(n, edges) {
  let size = n;
  let adj = Array.from({ length: n }, () => new Map());
  let self = new Float64Array(n);
  let total = 0;
  for (const [a, b] of edges) {
    if (a === b) continue;
    adj[a].set(b, (adj[a].get(b) || 0) + 1);
    adj[b].set(a, (adj[b].get(a) || 0) + 1);
    total += 1;
  }
  const membership = Array.from({ length: n }, (_, i) => i);
  if (total === 0) return membership;
  const m2 = 2 * total; // the sum of every node's weighted degree, at every level

  for (let level = 0; level < 20; level++) {
    const k = new Float64Array(size);
    for (let i = 0; i < size; i++) {
      k[i] = 2 * self[i];
      for (const w of adj[i].values()) k[i] += w;
    }
    const comm = Array.from({ length: size }, (_, i) => i);
    const tot = Float64Array.from(k);
    let improved = false;
    for (let pass = 0; pass < 100; pass++) {
      let moved = false;
      for (let i = 0; i < size; i++) {
        const own = comm[i];
        tot[own] -= k[i];
        const toward = new Map();
        for (const [j, w] of adj[i]) toward.set(comm[j], (toward.get(comm[j]) || 0) + w);
        let best = own;
        let bestGain = (toward.get(own) || 0) - (tot[own] * k[i]) / m2;
        for (const c of [...toward.keys()].sort((x, y) => x - y)) {
          const gain = toward.get(c) - (tot[c] * k[i]) / m2;
          if (gain > bestGain + 1e-12) {
            best = c;
            bestGain = gain;
          }
        }
        comm[i] = best;
        tot[best] += k[i];
        if (best !== own) moved = improved = true;
      }
      if (!moved) break;
    }
    if (!improved) break;

    // Each community becomes one node; edges inside it become a self-loop.
    const renumber = new Map();
    for (const c of comm) if (!renumber.has(c)) renumber.set(c, renumber.size);
    const next = renumber.size;
    const nextAdj = Array.from({ length: next }, () => new Map());
    const nextSelf = new Float64Array(next);
    for (let i = 0; i < size; i++) {
      const ci = renumber.get(comm[i]);
      nextSelf[ci] += self[i];
      for (const [j, w] of adj[i]) {
        if (j < i) continue;
        const cj = renumber.get(comm[j]);
        if (ci === cj) nextSelf[ci] += w;
        else {
          nextAdj[ci].set(cj, (nextAdj[ci].get(cj) || 0) + w);
          nextAdj[cj].set(ci, (nextAdj[cj].get(ci) || 0) + w);
        }
      }
    }
    for (let i = 0; i < n; i++) membership[i] = renumber.get(comm[membership[i]]);
    if (next === size) break;
    size = next;
    adj = nextAdj;
    self = nextSelf;
  }
  return membership;
}

/**
 * Groups of friends: who's more connected to each other than to everyone
 * else. `ignore` lists keys to leave out (a person's own map leaves them out:
 * they know everyone on it, so they'd be counted in one of their own groups
 * and blur where the groups meet).
 *
 * Returns { groups: [[key, ...], ...] largest first (ties by first key),
 * alone: [key, ...] (no connections inside the map), of: Map key → group
 * index, or -1 for alone }. Ignored keys aren't in `of`.
 */
export function clusters(graph, { ignore = [] } = {}) {
  const skip = new Set(ignore);
  const keys = graph.nodes.map((n) => n.key).filter((k) => !skip.has(k)).sort();
  const index = new Map(keys.map((k, i) => [k, i]));
  const edges = graph.edges
    .filter(([a, b]) => index.has(a) && index.has(b))
    .map(([a, b]) => [index.get(a), index.get(b)]);
  const membership = louvain(keys.length, edges);
  const byCommunity = new Map();
  keys.forEach((k, i) => {
    if (!byCommunity.has(membership[i])) byCommunity.set(membership[i], []);
    byCommunity.get(membership[i]).push(k);
  });
  const all = [...byCommunity.values()];
  const groups = all.filter((g) => g.length > 1)
    .sort((a, b) => b.length - a.length || (a[0] < b[0] ? -1 : 1));
  const alone = all.filter((g) => g.length === 1).map((g) => g[0]).sort();
  const of = new Map();
  groups.forEach((g, i) => g.forEach((k) => of.set(k, i)));
  alone.forEach((k) => of.set(k, -1));
  return { groups, alone, of };
}

/**
 * A force-directed layout (Fruchterman–Reingold): nodes push apart, edges
 * pull together, and a gentle pull to the middle keeps islands close. Pushing
 * only acts within a few edge lengths: otherwise everyone pushes a loner (no
 * friends in view) so far out that the rest has to shrink to fit. Groups
 * start apart on a circle, and each node is drawn a little toward its own
 * group's middle, so groups settle as separate islands. `pin` is a key held
 * at the center (a person's own map). Same graph, same picture.
 *
 * Returns Map key → { x, y }, in arbitrary units centered near 0.
 */
export function layout(graph, { groups = null, pin = null, iterations = 300, seed = null } = {}) {
  const keys = graph.nodes.map((n) => n.key);
  const n = keys.length;
  const at = new Map(keys.map((k, i) => [k, i]));
  const rand = random(seed ?? hash([...keys].sort().join(",")));
  const k = 60; // ideal edge length
  const reach2 = (5 * k) ** 2; // pushing stops beyond this (squared)
  const radius = Math.max(k, k * Math.sqrt(n) * 0.9);
  const x = new Float64Array(n);
  const y = new Float64Array(n);
  const group = new Int32Array(n).fill(-1);
  const count = groups?.groups.length ?? 0;
  keys.forEach((key, i) => {
    const g = groups?.of.get(key) ?? -1;
    group[i] = g;
    // Groups start around a circle, largest first; everyone else scattered.
    const angle = g >= 0 && count > 1 ? (2 * Math.PI * g) / count : rand() * 2 * Math.PI;
    const r = g >= 0 && count > 1 ? radius * 0.6 : radius * (0.3 + 0.6 * rand());
    x[i] = Math.cos(angle) * r + (rand() - 0.5) * k;
    y[i] = Math.sin(angle) * r + (rand() - 0.5) * k;
  });
  const pinned = pin != null && at.has(pin) ? at.get(pin) : -1;
  if (pinned >= 0) x[pinned] = y[pinned] = 0;
  const links = graph.edges.filter(([a, b]) => at.has(a) && at.has(b) && a !== b).map(([a, b]) => [at.get(a), at.get(b)]);

  const dx = new Float64Array(n);
  const dy = new Float64Array(n);
  let temperature = radius / 4;
  const cool = temperature / (iterations + 1);
  for (let step = 0; step < iterations; step++) {
    dx.fill(0);
    dy.fill(0);
    for (let i = 0; i < n; i++) {
      for (let j = i + 1; j < n; j++) {
        let ex = x[i] - x[j];
        let ey = y[i] - y[j];
        let d2 = ex * ex + ey * ey;
        if (d2 > reach2) continue;
        if (d2 < 0.01) {
          ex = rand() - 0.5;
          ey = rand() - 0.5;
          d2 = ex * ex + ey * ey;
        }
        // Different groups push apart a bit harder, so islands stay distinct.
        const apart = group[i] !== group[j] && group[i] >= 0 && group[j] >= 0 ? 1.6 : 1;
        const f = (apart * k * k) / d2;
        dx[i] += ex * f; dy[i] += ey * f;
        dx[j] -= ex * f; dy[j] -= ey * f;
      }
    }
    for (const [a, b] of links) {
      const ex = x[a] - x[b];
      const ey = y[a] - y[b];
      const d = Math.sqrt(ex * ex + ey * ey) || 0.01;
      const f = d / k;
      dx[a] -= ex * f; dy[a] -= ey * f;
      dx[b] += ex * f; dy[b] += ey * f;
    }
    if (count > 0) {
      const cx = new Float64Array(count);
      const cy = new Float64Array(count);
      const cn = new Float64Array(count);
      for (let i = 0; i < n; i++) if (group[i] >= 0) { cx[group[i]] += x[i]; cy[group[i]] += y[i]; cn[group[i]]++; }
      for (let i = 0; i < n; i++) {
        const g = group[i];
        if (g < 0) continue;
        dx[i] += (cx[g] / cn[g] - x[i]) * 0.15;
        dy[i] += (cy[g] / cn[g] - y[i]) * 0.15;
      }
    }
    for (let i = 0; i < n; i++) {
      dx[i] -= x[i] * 0.02; // gravity
      dy[i] -= y[i] * 0.02;
      if (i === pinned) continue;
      const len = Math.sqrt(dx[i] * dx[i] + dy[i] * dy[i]) || 1;
      const move = Math.min(len, temperature);
      x[i] += (dx[i] / len) * move;
      y[i] += (dy[i] / len) * move;
    }
    temperature = Math.max(temperature - cool, 0.5);
  }
  return new Map(keys.map((key, i) => [key, { x: x[i], y: y[i] }]));
}

/** The convex hull of points ({x, y}), counterclockwise (Andrew's monotone chain). */
export function hull(points) {
  const pts = [...points].sort((a, b) => a.x - b.x || a.y - b.y);
  if (pts.length <= 2) return pts;
  const cross = (o, a, b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  const lower = [];
  for (const p of pts) {
    while (lower.length >= 2 && cross(lower.at(-2), lower.at(-1), p) <= 0) lower.pop();
    lower.push(p);
  }
  const upper = [];
  for (const p of pts.reverse()) {
    while (upper.length >= 2 && cross(upper.at(-2), upper.at(-1), p) <= 0) upper.pop();
    upper.push(p);
  }
  return lower.slice(0, -1).concat(upper.slice(0, -1));
}
