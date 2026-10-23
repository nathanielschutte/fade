// The friend map's graph tech, in Node. Run by scripts/test.sh:
//   node --test "shared/**/*.test.js"

import { test } from "node:test";
import assert from "node:assert/strict";

import { clusters, hash, hull, layout, random } from "./graph.js";

/** Every pair among `keys` connected. */
const clique = (keys) => keys.flatMap((a, i) => keys.slice(i + 1).map((b) => [a, b]));
const graphOf = (keys, edges) => ({ nodes: keys.map((key) => ({ key })), edges });

const A = ["a1", "a2", "a3", "a4", "a5"];
const B = ["b1", "b2", "b3", "b4"];
// Two tight groups joined by a single friendship, and someone on their own.
const twoGroups = graphOf([...A, ...B, "loner"], [...clique(A), ...clique(B), ["a1", "b1"]]);

test("finds two groups joined by one friendship", () => {
  const { groups, alone, of } = clusters(twoGroups);
  assert.deepEqual(groups, [A, B], "largest first");
  assert.deepEqual(alone, ["loner"]);
  assert.equal(of.get("a3"), 0);
  assert.equal(of.get("b2"), 1);
  assert.equal(of.get("loner"), -1);
});

test("the center of a person's map is left out of grouping", () => {
  // "me" knows everyone, so with them in, they'd be counted in one of the groups.
  const ego = graphOf(["me", ...A, ...B], [...clique(A), ...clique(B), ...[...A, ...B].map((k) => ["me", k])]);
  assert.ok(clusters(ego).of.get("me") >= 0);
  const { groups, of } = clusters(ego, { ignore: ["me"] });
  assert.deepEqual(groups, [A, B]);
  assert.equal(of.has("me"), false);
});

test("grouping is deterministic", () => {
  const shuffled = { nodes: [...twoGroups.nodes].reverse(), edges: [...twoGroups.edges].reverse() };
  assert.deepEqual(clusters(shuffled).groups, clusters(twoGroups).groups);
});

test("no friendships at all: everyone is on their own", () => {
  const { groups, alone } = clusters(graphOf(["x", "y"], []));
  assert.deepEqual(groups, []);
  assert.deepEqual(alone, ["x", "y"]);
});

test("a chain of three groups", () => {
  const C = ["c1", "c2", "c3"];
  const g = graphOf([...A, ...B, ...C], [...clique(A), ...clique(B), ...clique(C), ["a1", "b1"], ["b2", "c1"]]);
  assert.deepEqual(clusters(g).groups, [A, B, C]);
});

test("layout: finite, same every time, pinned center, groups apart", () => {
  const groups = clusters(twoGroups);
  const pos = layout(twoGroups, { groups, pin: "a1" });
  assert.equal(pos.size, twoGroups.nodes.length);
  for (const { x, y } of pos.values()) assert.ok(Number.isFinite(x) && Number.isFinite(y));
  assert.deepEqual(pos.get("a1"), { x: 0, y: 0 }, "the pinned node stays at the center");
  assert.deepEqual(layout(twoGroups, { groups, pin: "a1" }), pos, "deterministic");

  const centroid = (keys) => {
    const ps = keys.map((k) => pos.get(k));
    return { x: ps.reduce((s, p) => s + p.x, 0) / ps.length, y: ps.reduce((s, p) => s + p.y, 0) / ps.length };
  };
  const spread = (keys) => {
    const c = centroid(keys);
    return Math.max(...keys.map((k) => Math.hypot(pos.get(k).x - c.x, pos.get(k).y - c.y)));
  };
  const ca = centroid(A.slice(1));
  const cb = centroid(B);
  const apart = Math.hypot(ca.x - cb.x, ca.y - cb.y);
  assert.ok(apart > spread(B) * 1.5, `groups overlap: ${apart} vs ${spread(B)}`);
  // Nobody sits on top of anyone else.
  const all = [...pos.values()];
  for (let i = 0; i < all.length; i++) {
    for (let j = i + 1; j < all.length; j++) {
      assert.ok(Math.hypot(all[i].x - all[j].x, all[i].y - all[j].y) > 10, "two nodes overlap");
    }
  }
});

test("layout handles one node, and no edges", () => {
  assert.deepEqual([...layout(graphOf(["solo"], []), { pin: "solo" }).values()], [{ x: 0, y: 0 }]);
  const pos = layout(graphOf(["x", "y", "z"], []));
  for (const { x, y } of pos.values()) assert.ok(Number.isFinite(x) && Number.isFinite(y));
});

test("hull: corners of a square, and small cases", () => {
  const square = [{ x: 0, y: 0 }, { x: 2, y: 0 }, { x: 2, y: 2 }, { x: 0, y: 2 }, { x: 1, y: 1 }, { x: 1, y: 0 }];
  const h = hull(square);
  assert.equal(h.length, 4);
  assert.ok(!h.some((p) => p.x === 1 && p.y === 1), "the inside point isn't on the hull");
  assert.equal(hull([{ x: 1, y: 1 }]).length, 1);
  assert.equal(hull([{ x: 0, y: 0 }, { x: 3, y: 4 }]).length, 2);
});

test("seeded random and hash are stable", () => {
  const r1 = random(42);
  const r2 = random(42);
  for (let i = 0; i < 5; i++) {
    const v = r1();
    assert.equal(v, r2());
    assert.ok(v >= 0 && v < 1);
  }
  assert.equal(hash("abc"), hash("abc"));
  assert.notEqual(hash("abc"), hash("abd"));
});
