//! The friend map (docs/implementation/friend-graph.md): which people and friendships a
//! request may see. Privacy is decided here, never in a client.
//!
//! A person's own map (`GET /api/graph`) has them, their friends, the
//! friendships among those friends, and one anonymous "?" for each person a
//! friend knows that they don't. A "?" carries no id or name, and the order
//! of the "?"s is shuffled, so nothing hints at who one is.
//!
//! The admin graph (`GET /api/admin/graph`) has real usernames: everyone, or
//! the people chosen and their friends (depth 1) or friends of friends
//! (depth 2).
//!
//! Only current friendships count: ended ones and requests never do.
//!
//! Group chats are added only when asked for (`?chats=1`): a node per chat,
//! lined to its members who are on the map (`add_chats`). A chat's name is
//! shown only to its members.

use std::collections::{BTreeMap, BTreeSet};

use axum::{
    extract::{Query, State},
    Json,
};
use rand::seq::SliceRandom;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::SqlitePool;

use crate::{
    auth::AuthUser,
    error::{AppError, AppResult},
    SharedState,
};

/// At most this many people chosen at once on the admin graph.
const MAX_SEEDS: usize = 50;

#[derive(Debug, Serialize, PartialEq)]
pub struct Node {
    pub key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    /// On a PowerUser's graph, what to call someone they don't know ("Someone K7Q2").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub alias: Option<String>,
    /// "self", "friend" or "unknown" on a person's map; "seed" or "member" on
    /// the admin graph; "chat" for a group chat on either.
    pub kind: &'static str,
    /// A group chat's name and id: only when the viewer is in it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group_id: Option<i64>,
    /// A group chat's members, and how many of them aren't on the map.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub others: Option<usize>,
}

impl Node {
    fn person(
        key: String,
        user_id: Option<i64>,
        username: Option<String>,
        kind: &'static str,
    ) -> Self {
        Node {
            key,
            user_id,
            username,
            alias: None,
            kind,
            name: None,
            group_id: None,
            size: None,
            others: None,
        }
    }
}

#[derive(Debug, Default, Serialize)]
pub struct Graph {
    pub nodes: Vec<Node>,
    pub edges: Vec<[String; 2]>,
}

fn user_key(id: i64) -> String {
    format!("u{id}")
}

/// Every current friendship, as (lower id, higher id).
async fn friendships(db: &SqlitePool) -> sqlx::Result<Vec<(i64, i64)>> {
    sqlx::query_as("SELECT user_lo, user_hi FROM friendships WHERE ended_at IS NULL")
        .fetch_all(db)
        .await
}

/// Every current group membership, as (group id, user id).
async fn memberships(db: &SqlitePool) -> sqlx::Result<Vec<(i64, i64)>> {
    sqlx::query_as("SELECT group_id, user_id FROM group_members WHERE left_at IS NULL")
        .fetch_all(db)
        .await
}

/// The group chats `user` is in now, by id, with their names.
async fn chats_of(db: &SqlitePool, user: i64) -> sqlx::Result<BTreeMap<i64, String>> {
    let rows: Vec<(i64, String)> = sqlx::query_as(
        "SELECT g.id, g.name FROM groups g JOIN group_members m ON m.group_id = g.id
         WHERE m.user_id = ? AND m.left_at IS NULL",
    )
    .bind(user)
    .fetch_all(db)
    .await?;
    Ok(rows.into_iter().collect())
}

fn adjacency(edges: &[(i64, i64)]) -> BTreeMap<i64, BTreeSet<i64>> {
    let mut adj: BTreeMap<i64, BTreeSet<i64>> = BTreeMap::new();
    for &(a, b) in edges {
        adj.entry(a).or_default().insert(b);
        adj.entry(b).or_default().insert(a);
    }
    adj
}

/// `me`'s own map. `shuffle` puts the "?"s in a random order before they're
/// sorted by which friends know them (tests pass one that does nothing).
pub fn ego(me: i64, edges: &[(i64, i64)], shuffle: impl FnOnce(&mut Vec<BTreeSet<i64>>)) -> Graph {
    let adj = adjacency(edges);
    let none = BTreeSet::new();
    let friends = adj.get(&me).unwrap_or(&none);
    let mut g = Graph::default();
    g.nodes
        .push(Node::person(user_key(me), Some(me), None, "self"));
    for &f in friends {
        g.nodes
            .push(Node::person(user_key(f), Some(f), None, "friend"));
        g.edges.push([user_key(me), user_key(f)]);
    }
    // Friends who are friends with each other, and who each friend knows that `me` doesn't.
    let mut strangers: BTreeMap<i64, BTreeSet<i64>> = BTreeMap::new();
    for &f in friends {
        for &other in adj.get(&f).unwrap_or(&none) {
            if other == me {
                continue;
            }
            if friends.contains(&other) {
                if f < other {
                    g.edges.push([user_key(f), user_key(other)]);
                }
            } else {
                strangers.entry(other).or_default().insert(f);
            }
        }
    }
    // Only who-knows-them survives; the ids are dropped here.
    let mut unknown: Vec<BTreeSet<i64>> = strangers.into_values().collect();
    shuffle(&mut unknown);
    unknown.sort(); // stable: equal sets keep their shuffled order
    for (i, knowers) in unknown.iter().enumerate() {
        let key = format!("?{}", i + 1);
        g.nodes
            .push(Node::person(key.clone(), None, None, "unknown"));
        for &f in knowers {
            g.edges.push([user_key(f), key.clone()]);
        }
    }
    g
}

/// The admin graph: everyone (`seeds` None), or the seeds and everyone within
/// `depth` friendships of them, with every friendship among those people.
pub fn scoped(
    edges: &[(i64, i64)],
    people: &[(i64, String)],
    seeds: Option<&[i64]>,
    depth: u8,
) -> Graph {
    let adj = adjacency(edges);
    let names: BTreeMap<i64, &str> = people.iter().map(|(id, n)| (*id, n.as_str())).collect();
    let chosen: BTreeSet<i64> = seeds
        .unwrap_or_default()
        .iter()
        .copied()
        .filter(|id| names.contains_key(id))
        .collect();
    let included: BTreeSet<i64> = match seeds {
        None => names.keys().copied().collect(),
        Some(_) => {
            let mut seen = chosen.clone();
            let mut frontier = chosen.clone();
            for _ in 0..depth {
                let next: BTreeSet<i64> = frontier
                    .iter()
                    .flat_map(|id| adj.get(id).into_iter().flatten().copied())
                    .filter(|id| !seen.contains(id))
                    .collect();
                seen.extend(&next);
                frontier = next;
            }
            seen
        }
    };
    let mut g = Graph::default();
    for &id in &included {
        g.nodes.push(Node::person(
            user_key(id),
            Some(id),
            names.get(&id).map(|n| n.to_string()),
            if chosen.contains(&id) {
                "seed"
            } else {
                "member"
            },
        ));
    }
    for &(a, b) in edges {
        if included.contains(&a) && included.contains(&b) {
            g.edges.push([user_key(a), user_key(b)]);
        }
    }
    g
}

/// Adds group chats: a node for each one with at least `min` people on the
/// map, lined to them (`only_mine`: just the viewer's own chats). Members
/// who aren't on the map are only counted, so a "?" is never tied to a chat,
/// which could say who it is. The name and id go only to members (`mine`).
/// `hide` (a PowerUser's secret and id) gives the chats they aren't in an
/// alias for a key, like the people they don't know. Call before `obscure`.
pub fn add_chats(
    g: &mut Graph,
    members: &[(i64, i64)],
    mine: &BTreeMap<i64, String>,
    only_mine: bool,
    min: usize,
    hide: Option<(&[u8], i64)>,
) {
    let on_map: BTreeMap<i64, String> = g
        .nodes
        .iter()
        .filter_map(|n| Some((n.user_id?, n.key.clone())))
        .collect();
    let mut chats: BTreeMap<i64, Vec<i64>> = BTreeMap::new();
    for &(chat, user) in members {
        chats.entry(chat).or_default().push(user);
    }
    for (chat, people) in chats {
        let name = mine.get(&chat);
        if only_mine && name.is_none() {
            continue;
        }
        let here: Vec<String> = people
            .iter()
            .filter_map(|u| on_map.get(u).cloned())
            .collect();
        if here.len() < min {
            continue;
        }
        let key = match (name, hide) {
            // (Negated: a chat's alias is never a person's.)
            (None, Some((secret, viewer))) => {
                format!("x{}", &crate::roles::alias(secret, viewer, -chat)[1..])
            }
            _ => format!("c{chat}"),
        };
        for person in &here {
            g.edges.push([key.clone(), person.clone()]);
        }
        g.nodes.push(Node {
            name: name.cloned(),
            group_id: name.map(|_| chat),
            size: Some(people.len()),
            others: Some(people.len() - here.len()),
            ..Node::person(key, None, None, "chat")
        });
    }
}

/// On a PowerUser's graph, everyone but them and their friends (`known`)
/// becomes anonymous: an alias for a key (roles::alias, per viewer, unrelated
/// to the id), no id, no username, and a short label. Lines follow.
pub fn obscure(g: &mut Graph, viewer: i64, known: &BTreeSet<i64>, secret: &[u8]) {
    let mut renamed: BTreeMap<String, String> = BTreeMap::new();
    for n in &mut g.nodes {
        let Some(id) = n.user_id else { continue };
        if known.contains(&id) {
            continue;
        }
        let alias = crate::roles::alias(secret, viewer, id);
        n.alias = Some(format!(
            "Someone {}",
            alias[alias.len() - 4..].to_uppercase()
        ));
        renamed.insert(std::mem::replace(&mut n.key, alias), n.key.clone());
        n.user_id = None;
        n.username = None;
    }
    for edge in &mut g.edges {
        for end in edge.iter_mut() {
            if let Some(new) = renamed.get(end) {
                *end = new.clone();
            }
        }
    }
}

#[derive(Deserialize)]
pub struct MapQuery {
    /// `chats=1`: add your group chats.
    chats: Option<u8>,
}

/// `GET /api/graph` (`?chats=1`): your own friend map.
pub async fn mine(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Query(q): Query<MapQuery>,
) -> AppResult<Json<Graph>> {
    let edges = friendships(&state.db).await?;
    let mut g = ego(me.id, &edges, |v| v.shuffle(&mut rand::thread_rng()));
    if q.chats == Some(1) {
        let members = memberships(&state.db).await?;
        let mine = chats_of(&state.db, me.id).await?;
        add_chats(&mut g, &members, &mine, true, 1, None);
    }
    tracing::debug!(user_id = me.id, nodes = g.nodes.len(), "friend map viewed");
    Ok(Json(g))
}

#[derive(Deserialize)]
pub struct AdminQuery {
    /// `all=1`: everyone.
    all: Option<u8>,
    /// Comma-separated user ids; you by default.
    users: Option<String>,
    /// 1 (their friends) or 2 (friends of friends).
    depth: Option<u8>,
    /// `chats=1`: add group chats with two or more people on the graph.
    chats: Option<u8>,
}

/// `GET /api/admin/graph?all=1` or `?users=3,7&depth=1`: admins only.
pub async fn admin(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Query(q): Query<AdminQuery>,
) -> AppResult<Json<Value>> {
    // PowerUsers and Admins (roles.md). PowerUsers see everyone they aren't
    // friends with as anonymous, and choose them by alias, never by id.
    let role = crate::roles::require(&state, &me, crate::roles::Role::Power).await?;
    let power = role.is_power();
    let people: Vec<(i64, String)> =
        sqlx::query_as("SELECT id, username FROM users ORDER BY lower(username)")
            .fetch_all(&state.db)
            .await?;
    let (known, secret) = if power {
        let mut known: BTreeSet<i64> = crate::roles::friend_ids(&state.db, me.id)
            .await?
            .into_iter()
            .collect();
        known.insert(me.id);
        (known, crate::roles::alias_key(&state.db).await?)
    } else {
        (BTreeSet::new(), Vec::new())
    };
    let by_alias: BTreeMap<String, i64> = if power {
        people
            .iter()
            .map(|(id, _)| (crate::roles::alias(&secret, me.id, *id), *id))
            .collect()
    } else {
        BTreeMap::new()
    };
    let unknown_choice = || AppError::bad("Choose people from the list, or from the graph.");
    let seeds: Option<Vec<i64>> = if q.all == Some(1) {
        None
    } else {
        let ids: Vec<i64> = match q.users.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            None => vec![me.id],
            Some(list) => list
                .split(',')
                .map(|s| {
                    let s = s.trim();
                    match s.parse::<i64>() {
                        // A PowerUser names only people they know by id.
                        Ok(id) if !power || known.contains(&id) => Ok(id),
                        Ok(_) => Err(unknown_choice()),
                        Err(_) => by_alias.get(s).copied().ok_or_else(unknown_choice),
                    }
                })
                .collect::<Result<_, _>>()?,
        };
        if ids.len() > MAX_SEEDS {
            return Err(AppError::bad(format!(
                "Choose at most {MAX_SEEDS} people at once."
            )));
        }
        Some(ids)
    };
    let depth = q.depth.unwrap_or(1).clamp(1, 2);
    let edges = friendships(&state.db).await?;
    let mut g = scoped(&edges, &people, seeds.as_deref(), depth);
    if q.chats == Some(1) {
        let members = memberships(&state.db).await?;
        let mine = chats_of(&state.db, me.id).await?;
        let hide = power.then_some((secret.as_slice(), me.id));
        add_chats(&mut g, &members, &mine, false, 2, hide);
    }
    if power {
        obscure(&mut g, me.id, &known, &secret);
    }
    tracing::debug!(
        user_id = me.id,
        nodes = g.nodes.len(),
        all = seeds.is_none(),
        "admin friend graph viewed"
    );
    Ok(Json(json!({
        "graph": g,
        "depth": depth,
        "all": seeds.is_none(),
        // The picker: PowerUsers choose among themselves and their friends.
        "people": people
            .iter()
            .filter(|(id, _)| !power || known.contains(id))
            .map(|(id, name)| json!({ "id": id, "username": name }))
            .collect::<Vec<_>>(),
        "anonymous": power,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    fn keys(g: &Graph) -> Vec<&str> {
        g.nodes.iter().map(|n| n.key.as_str()).collect()
    }

    fn has_edge(g: &Graph, a: &str, b: &str) -> bool {
        g.edges
            .iter()
            .any(|[x, y]| (x == a && y == b) || (x == b && y == a))
    }

    #[test]
    fn a_persons_map() {
        // 1 knows 2, 3, 4. 2 and 3 know each other. 3 knows 5; 3 and 4 both know 6.
        // 7 knows only 5 (two steps from 1's friends: not on the map).
        let edges = [
            (1, 2),
            (1, 3),
            (1, 4),
            (2, 3),
            (3, 5),
            (3, 6),
            (4, 6),
            (5, 7),
        ];
        let g = ego(1, &edges, |_| {});
        assert_eq!(keys(&g), ["u1", "u2", "u3", "u4", "?1", "?2"]);
        assert_eq!(g.nodes[0].kind, "self");
        assert!(g.nodes[1..4].iter().all(|n| n.kind == "friend"));
        for f in ["u2", "u3", "u4"] {
            assert!(has_edge(&g, "u1", f));
        }
        assert!(has_edge(&g, "u2", "u3"), "friends who know each other");
        assert!(!has_edge(&g, "u2", "u4"));
        // One ? per stranger: 5 (known by 3) and 6 (known by 3 and 4), sorted by who knows them.
        assert!(has_edge(&g, "u3", "?1") && has_edge(&g, "u4", "?2") && has_edge(&g, "u3", "?2"));
        assert_eq!(g.edges.len(), 3 + 1 + 3);
        // A ? says nothing about who it is.
        let json = serde_json::to_value(&g).unwrap();
        for n in json["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|n| n["kind"] == "unknown")
        {
            assert_eq!(
                n.as_object().unwrap().keys().collect::<Vec<_>>(),
                ["key", "kind"]
            );
        }
        assert!(!json.to_string().contains("\"u5\"") && !json.to_string().contains("\"u6\""));
    }

    #[test]
    fn a_map_with_no_friends_is_just_you() {
        let g = ego(9, &[(1, 2)], |_| {});
        assert_eq!(keys(&g), ["u9"]);
        assert!(g.edges.is_empty());
    }

    #[test]
    fn strangers_are_shuffled_before_sorting() {
        // Three strangers all known by the same friend: their order is the shuffle's.
        let edges = [(1, 2), (2, 10), (2, 11), (2, 12)];
        let g = ego(1, &edges, |v| v.reverse());
        assert_eq!(keys(&g), ["u1", "u2", "?1", "?2", "?3"]);
    }

    #[test]
    fn admin_scopes() {
        let people: Vec<(i64, String)> = (1..=7).map(|i| (i, format!("p{i}"))).collect();
        let edges = [(1, 2), (2, 3), (3, 4), (5, 6)];
        let all = scoped(&edges, &people, None, 1);
        assert_eq!(
            all.nodes.len(),
            7,
            "everyone, including people with no friends"
        );
        assert_eq!(all.edges.len(), 4);
        assert!(all
            .nodes
            .iter()
            .all(|n| n.kind == "member" && n.username.is_some()));

        let one = scoped(&edges, &people, Some(&[2]), 1);
        assert_eq!(keys(&one), ["u1", "u2", "u3"]);
        assert_eq!(one.nodes[1].kind, "seed");
        assert_eq!(one.nodes[1].username.as_deref(), Some("p2"));
        let two = scoped(&edges, &people, Some(&[2]), 2);
        assert_eq!(keys(&two), ["u1", "u2", "u3", "u4"]);
        assert_eq!(two.edges.len(), 3);

        let both = scoped(&edges, &people, Some(&[1, 5, 99]), 1);
        assert_eq!(
            keys(&both),
            ["u1", "u2", "u5", "u6"],
            "unknown ids are ignored"
        );
        assert_eq!(both.nodes.iter().filter(|n| n.kind == "seed").count(), 2);
    }

    #[test]
    fn a_powerusers_graph_hides_strangers() {
        let people: Vec<(i64, String)> = (1..=4).map(|i| (i, format!("p{i}"))).collect();
        let edges = [(1, 2), (2, 3), (3, 4)];
        let mut g = scoped(&edges, &people, None, 1);
        let known: BTreeSet<i64> = [1, 2].into();
        obscure(&mut g, 1, &known, &[9u8; 32]);
        let json = serde_json::to_string(&g).unwrap();
        for hidden in [
            "p3",
            "p4",
            "\"u3\"",
            "\"u4\"",
            "\"user_id\":3",
            "\"user_id\":4",
        ] {
            assert!(!json.contains(hidden), "{hidden} leaked: {json}");
        }
        let strangers: Vec<&Node> = g.nodes.iter().filter(|n| n.alias.is_some()).collect();
        assert_eq!(strangers.len(), 2);
        assert!(strangers
            .iter()
            .all(|n| n.key.starts_with('a') && n.user_id.is_none() && n.username.is_none()));
        assert!(strangers[0]
            .alias
            .as_deref()
            .unwrap()
            .starts_with("Someone "));
        // Lines follow the new keys.
        assert!(has_edge(&g, "u2", &strangers[0].key) || has_edge(&g, "u2", &strangers[1].key));
        assert!(has_edge(&g, &strangers[0].key, &strangers[1].key));
        assert!(
            g.nodes.iter().any(|n| n.username.as_deref() == Some("p2")),
            "friends keep their names"
        );
    }

    #[test]
    fn group_chats_on_a_persons_map() {
        // 1 knows 2 and 3; 2 knows 5 (a ? on 1's map).
        // Chat 10: 1, 2, 5. Chat 11: 2, 3 (1 isn't in it). Chat 12: 1 alone with 6.
        let edges = [(1, 2), (1, 3), (2, 5)];
        let members = [
            (10, 1),
            (10, 2),
            (10, 5),
            (11, 2),
            (11, 3),
            (12, 1),
            (12, 6),
        ];
        let mine: BTreeMap<i64, String> = [(10, "trip".to_owned()), (12, "us".to_owned())].into();
        let mut g = ego(1, &edges, |_| {});
        let before = g.edges.len();
        add_chats(&mut g, &members, &mine, true, 1, None);
        let chats: Vec<&Node> = g.nodes.iter().filter(|n| n.kind == "chat").collect();
        assert_eq!(chats.len(), 2, "only my own chats");
        assert_eq!(
            (
                chats[0].key.as_str(),
                chats[0].name.as_deref(),
                chats[0].group_id,
                chats[0].size,
                chats[0].others
            ),
            ("c10", Some("trip"), Some(10), Some(3), Some(1))
        );
        assert!(has_edge(&g, "c10", "u1") && has_edge(&g, "c10", "u2"));
        // 5 is in the chat and is the ?: never lined to it, only counted.
        assert!(
            !g.edges
                .iter()
                .any(|[a, b]| (a == "c10" && b.starts_with('?'))
                    || (b == "c10" && a.starts_with('?')))
        );
        assert_eq!((chats[1].key.as_str(), chats[1].others), ("c12", Some(1)));
        assert_eq!(g.edges.len(), before + 3);
        let json = serde_json::to_string(&g).unwrap();
        assert!(!json.contains("\"c11\""), "a chat I'm not in: {json}");
    }

    #[test]
    fn group_chats_on_the_admin_graph() {
        let people: Vec<(i64, String)> = (1..=4).map(|i| (i, format!("p{i}"))).collect();
        let edges = [(1, 2), (2, 3), (3, 4)];
        // Chat 20: 3, 4 (viewer 1 isn't in it). Chat 21: 1, 2. Chat 22: 4 and someone off the graph.
        let members = [(20, 3), (20, 4), (21, 1), (21, 2), (22, 4), (22, 9)];
        let mine: BTreeMap<i64, String> = [(21, "ours".to_owned())].into();

        // An Admin: chats with two people on the graph; names only of their own.
        let mut g = scoped(&edges, &people, None, 1);
        add_chats(&mut g, &members, &mine, false, 2, None);
        let chats: Vec<&Node> = g.nodes.iter().filter(|n| n.kind == "chat").collect();
        assert_eq!(chats.len(), 2);
        assert_eq!(
            (
                chats[0].key.as_str(),
                chats[0].name.as_deref(),
                chats[0].group_id
            ),
            ("c20", None, None)
        );
        assert_eq!(
            (chats[1].key.as_str(), chats[1].name.as_deref()),
            ("c21", Some("ours"))
        );
        assert!(has_edge(&g, "c20", "u3") && has_edge(&g, "c20", "u4"));

        // A PowerUser (1, friends with 2): chats they aren't in are aliased, and so are the people.
        let mut g = scoped(&edges, &people, None, 1);
        add_chats(&mut g, &members, &mine, false, 2, Some((&[9u8; 32], 1)));
        obscure(&mut g, 1, &[1, 2].into(), &[9u8; 32]);
        let json = serde_json::to_string(&g).unwrap();
        for hidden in ["\"c20\"", "\"u3\"", "\"u4\"", "p3", "p4"] {
            assert!(!json.contains(hidden), "{hidden} leaked: {json}");
        }
        let theirs = g
            .nodes
            .iter()
            .find(|n| n.kind == "chat" && n.name.is_none())
            .unwrap();
        assert!(theirs.key.starts_with('x') && theirs.group_id.is_none());
        let strangers: Vec<&str> = g
            .nodes
            .iter()
            .filter(|n| n.alias.is_some())
            .map(|n| n.key.as_str())
            .collect();
        assert!(
            strangers.iter().all(|k| has_edge(&g, &theirs.key, k)),
            "lines follow the aliases"
        );
        assert!(g
            .nodes
            .iter()
            .any(|n| n.key == "c21" && n.name.as_deref() == Some("ours")));
    }

    #[tokio::test]
    async fn only_current_memberships_count() {
        let db = temp_db().await;
        for (id, name) in [(1, "ana"), (2, "ben")] {
            sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (?, ?, 'h', 'k', 'w', 0)")
                .bind(id).bind(name).execute(&db).await.unwrap();
        }
        sqlx::query(
            "INSERT INTO groups (id, name, created_by, created_at) VALUES (7, 'trip', 1, 0)",
        )
        .execute(&db)
        .await
        .unwrap();
        sqlx::query("INSERT INTO group_members (group_id, user_id, role, joined_at, left_at) VALUES (7, 1, 'owner', 0, NULL), (7, 2, 'member', 0, 5)")
            .execute(&db)
            .await
            .unwrap();
        assert_eq!(memberships(&db).await.unwrap(), vec![(7, 1)]);
        assert_eq!(
            chats_of(&db, 1).await.unwrap(),
            BTreeMap::from([(7, "trip".to_owned())])
        );
        assert!(chats_of(&db, 2).await.unwrap().is_empty(), "left");
    }

    #[tokio::test]
    async fn only_current_friendships_count() {
        let db = temp_db().await;
        for (id, name) in [(1, "ana"), (2, "ben"), (3, "cal")] {
            sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (?, ?, 'h', 'k', 'w', 0)")
                .bind(id).bind(name).execute(&db).await.unwrap();
        }
        sqlx::query("INSERT INTO friendships (user_lo, user_hi, created_at, ended_at) VALUES (1, 2, 0, NULL), (1, 3, 0, 5)")
            .execute(&db)
            .await
            .unwrap();
        assert_eq!(friendships(&db).await.unwrap(), vec![(1, 2)]);
    }
}
