//! The friend map (docs/friend-graph.md): which people and friendships a
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
//! Only current friendships count: ended ones, requests, and groups never do.

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
    /// "self", "friend" or "unknown" on a person's map; "seed" or "member" on the admin graph.
    pub kind: &'static str,
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
    g.nodes.push(Node {
        key: user_key(me),
        user_id: Some(me),
        username: None,
        kind: "self",
    });
    for &f in friends {
        g.nodes.push(Node {
            key: user_key(f),
            user_id: Some(f),
            username: None,
            kind: "friend",
        });
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
        g.nodes.push(Node {
            key: key.clone(),
            user_id: None,
            username: None,
            kind: "unknown",
        });
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
        g.nodes.push(Node {
            key: user_key(id),
            user_id: Some(id),
            username: names.get(&id).map(|n| n.to_string()),
            kind: if chosen.contains(&id) {
                "seed"
            } else {
                "member"
            },
        });
    }
    for &(a, b) in edges {
        if included.contains(&a) && included.contains(&b) {
            g.edges.push([user_key(a), user_key(b)]);
        }
    }
    g
}

/// `GET /api/graph`: your own friend map.
pub async fn mine(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Graph>> {
    let edges = friendships(&state.db).await?;
    let g = ego(me.id, &edges, |v| v.shuffle(&mut rand::thread_rng()));
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
}

/// `GET /api/admin/graph?all=1` or `?users=3,7&depth=1`: admins only.
pub async fn admin(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Query(q): Query<AdminQuery>,
) -> AppResult<Json<Value>> {
    if !state.config.is_admin(&me.username) {
        return Err(AppError::not_found("Not found."));
    }
    let seeds: Option<Vec<i64>> = if q.all == Some(1) {
        None
    } else {
        let ids: Vec<i64> = match q.users.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            None => vec![me.id],
            Some(list) => list
                .split(',')
                .map(|s| s.trim().parse::<i64>())
                .collect::<Result<_, _>>()
                .map_err(|_| AppError::bad("Choose people by their ids, separated by commas."))?,
        };
        if ids.len() > MAX_SEEDS {
            return Err(AppError::bad(format!(
                "Choose at most {MAX_SEEDS} people at once."
            )));
        }
        Some(ids)
    };
    let depth = q.depth.unwrap_or(1).clamp(1, 2);
    let people: Vec<(i64, String)> =
        sqlx::query_as("SELECT id, username FROM users ORDER BY lower(username)")
            .fetch_all(&state.db)
            .await?;
    let edges = friendships(&state.db).await?;
    let g = scoped(&edges, &people, seeds.as_deref(), depth);
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
        "people": people.iter().map(|(id, name)| json!({ "id": id, "username": name })).collect::<Vec<_>>(),
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
