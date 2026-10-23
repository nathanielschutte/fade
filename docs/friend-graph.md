# Friend map (design)

Status: **built (0.27.0).** Requested by Nate on 2026-10-23: a page that graphs friend relationships so distinct groups of friends stand out, built as a reusable module with two views: one every person can see, and an admin view with selectable scope. Plan entry: X15 in [plan.md](plan.md).

## What people see

**Friend map** (in the app, from the Friends sheet): you in the middle, your friends around you, a line between two friends who are friends with each other, and **?** for people your friends know that you don't. One ? per such person, joined to each of your friends who knows them. Friends who know each other settle into clusters, and each cluster gets an outlined region and a letter ("Group A"), so your circles of friends (school, work, family) show as separate islands. Tapping a friend says who they are, how many of your friends they know, and how many people they know that you don't.

**Admin graph** (`/admin#graph`, admins only):
- A switch between **everyone** (every account and every friendship) and **chosen people** (one or more; you by default).
- For chosen people, a depth: their friends (1) or friends of friends too (2).
- Real usernames throughout; no ?s.

## Privacy

The server already knows the friendship graph (it's metadata, like who's in which group); what changes is who gets to see parts of it.

- **Your map shows only what you already know, plus anonymous structure.** You see your friends (you can already see them in your chat list) and which of them are friends with each other. A ? carries no id, username, display name, or picture: in the response it's just `?1`, `?2`, ... with the order shuffled, so nothing hints at who it is or when they joined. What it does reveal is that a friend has friends you don't know, and when two of your friends share the same one. Nate asked for exactly this.
- **Only your own map.** `GET /api/graph` takes no parameters; there's no way to ask for someone else's.
- **Only current friendships**, and ? only for people at distance two through a current friend: ended friendships, pending requests, group co-membership, and blocked people never appear.
- **The admin graph is admins-only** (404 otherwise, like the rest of the panel) and shows what the server holds: usernames and friendships. No message content, nothing decrypted. The panel's "counts only, never content" rule still holds.

## The module

Three layers, each usable on its own:

| Layer | File | Job |
|---|---|---|
| Scope (server) | `server/src/graph.rs` | Which nodes and edges a request may see: one person's map with ?s for friends of friends, or for admins any set of people at depth 1–2, or everyone. Privacy is decided here, never in a client. |
| Graph tech (shared) | `shared/graph/graph.js` | Platform-neutral, no DOM: finding clusters, laying the graph out, outlining clusters. Like `shared/crypto/crypto.js`, it can be bundled by the iOS app. Tested in Node. |
| Renderer (web) | `server/static/graph-view.js` | Draws an SVG from a graph, its clusters, and its layout; hover and tap; a legend and a list view. Both pages use it with different options. |

### The graph format

What the server sends, and what the shared module and renderer take:

```json
{
  "nodes": [ { "key": "u5", "user_id": 5, "kind": "self" },
             { "key": "u9", "user_id": 9, "kind": "friend" },
             { "key": "?1", "kind": "unknown" } ],
  "edges": [ ["u5", "u9"], ["u9", "?1"] ]
}
```

`kind` is `self`, `friend`, or `unknown` on a person's map. On the admin graph it's `seed` (a chosen person) or `member`, and nodes carry `username`. Keys are unique per response.

### Finding groups of friends (clusters)

**Louvain modularity**, the standard way to find communities in a network. Each node starts alone. Nodes move to whichever neighbor's cluster gains the most modularity (how much more connected a cluster is inside than chance would predict). Clusters then merge into single nodes and the process repeats until nothing improves. Deterministic: nodes are visited in key order and ties go to the smallest cluster, so the same graph always gives the same groups.

- **On a person's map, the person is left out of clustering.** You're connected to everyone on your map, so including you would make one big cluster. Groups are found among your friends and the ?s.
- **Someone with no connections inside the map** (a friend who knows none of your other friends) stays alone, drawn grey and not lettered: "on their own" in the legend.
- **Cluster letters and colors follow size:** A is the largest. **Only the three largest clusters get color** (blue, orange, aqua). Those three pass the color-blindness and contrast checks against the app's background for every pair, and a fourth hue doesn't. Every cluster, colored or not, gets an outlined region and a letter, so groups never depend on color alone.

### Laying it out

A **force-directed layout** (Fruchterman–Reingold): nearby nodes push apart, every edge pulls together, and a gentle pull toward the middle keeps islands from drifting off. The movement allowed shrinks each step until the layout settles. Pushing only acts within five edge lengths: otherwise everyone pushes people with no friends in view so far out that the rest has to shrink to fit around them. Two adjustments make groups read clearly:

- **Clusters start apart.** Each cluster's nodes start near their own point on a circle, the largest first, so groups settle as separate islands rather than untangling from a heap.
- **You are pinned at the center** of your own map, with friends around you.

Starting positions come from a seeded random generator keyed on the graph, so the same graph gives the same picture every time, and a new friend doesn't reshuffle everything. The layout is O(n²) per step, a few milliseconds for the 100-account cap, and well under a second for a whole app of 500.

### Outlining groups

Each cluster's region is its nodes' **convex hull** (smallest enclosing polygon), drawn with a thick, rounded, translucent stroke so it reads as a soft padded blob. One or two nodes make a padded dot or capsule. The letter sits at the region's top.

### Drawing (renderer)

- SVG, sized to its box and fitted to the layout's bounds. Plain classes and attributes only (the app's CSP allows no inline styles or scripts).
- Nodes: you (largest, outlined); friends sized a little by how many of your friends they know; ?s small and grey with a "?" inside. Dots shrink a little on small screens, never below 60%.
- Names next to their nodes, on the outer side, so identity never relies on color. A name is placed only where it doesn't overlap another name or someone else's dot, with priority to you (or the chosen people), then the best-connected. A name that doesn't fit appears when its person or a neighbor is highlighted.
- A redraw happens only when the box changes width (phones fire resize events as the address bar slides), so a selection isn't lost while scrolling.
- Lines thin and recessive; hovering or tapping a node lights up its lines and neighbors, fades the rest, and shows a detail line (on your map: their group, how many of your friends they know, how many people you don't, and a **Message** button; on the admin graph: **Show their graph**).
- Nodes ease out from the middle when the map appears, then outlines and lines fade in. Off for anyone who prefers reduced motion.
- A legend (groups with their letter, color, and members) and a "Show as list" view listing every group and its people, for screen readers and for when the picture is too dense.
- Phones: the picture fills the sheet's width; tap instead of hover.

## API

- `GET /api/graph`: your friend map. Signed in; no parameters.
- `GET /api/admin/graph?all=1` or `?users=3,7&depth=1|2`: the admin graph. Plus `people` (every account's id and username) for the picker. Admins only; at most 50 people per request.

## Tests

- **Rust** (`graph.rs`): a person's map has exactly their friends, the edges among them, and one ? per distinct friend of a friend; no ? carries an id or name; ended friendships don't count; admin scopes at depth 1 and 2, and everyone.
- **Node** (`shared/graph/graph.test.js`, run by `scripts/test.sh`): two cliques joined by one edge make two clusters; leaving the center out of clustering; determinism; the layout is finite, keeps the pinned node fixed, and puts separate clusters apart; hulls.
- **Smoke test**: both endpoints, access rules, and that ?s carry no identifying fields.
- **Browser** (`tests/e2e/test_graph.py`): a person's map with mutual friends and a ?, tapping a friend, the list view, the admin switch and people picker, phone layout.
