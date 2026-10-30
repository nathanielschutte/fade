# Roles (design)

Status: **built (0.28.0).** Requested by Nate on 2026-10-23 (S2 in [plan.md](../management/plan.md)).

## The roles

| Role | Who | Where it comes from |
|---|---|---|
| **User** | Everyone who signs up | The default |
| **PowerUser** | People interested in how napsack is doing | Granted in the app by an Admin or another PowerUser; taken away only by an Admin |
| **PowerXtreme** | A PowerUser, and then some | Granted to PowerUsers, and taken away, by Admins only. For now it can do exactly what a PowerUser can (Nate, 2026-10-29: a step up for those who want one; more may come, [S4](../management/plan.md#s4-powerxtreme)) |
| **Admin** | A fixed few | A list in settings (an SSM parameter in production), never the database |

**PowerUser is for curiosity, not power.** PowerXtreme is the same, one step up: everywhere below, "PowerUser" includes it, and the server checks it the same way (`Role::is_power`). It shows how the app is doing; it never shows more private data than a User sees, and it can't act on anyone else. Every rule below is enforced by the server on every request; the pages only hide what the server already refuses.

## What each role can do

The admin panel becomes **System** (a gear in the account bar, shown to PowerUsers and Admins).

| | User | PowerUser | Admin |
|---|---|---|---|
| System → Overview: counts, chart, pics, social, server | – | yes | yes |
| Overview → the users table (usernames, last seen, per-person counts) and **Reset password** | – | **no** (not sent) | yes |
| System → Metrics: status, charts, table | – | yes | yes |
| Metrics → cost (estimate, billed amounts, AWS problems) | – | **no** (not sent) | yes |
| System → Graph: everyone, chosen people, depth, "show their graph" | – | yes, but people they aren't friends with are **anonymous** | yes, with usernames |
| System → Logs (addresses, user ids, events) | – | **no** | yes |
| System → Metrics → Incidents (health monitor records; mark resolved) | – | **no** | yes |
| System → Users (accounts, turn off and on, sign out everywhere, clear a sign-in lock, reset codes, announcements, admin activity; [admin-users.md](admin-users.md)) | – | **no** | yes |
| System → Roles: see roles | – | themselves and their friends | everyone |
| Make someone a PowerUser | – | their friends only | anyone |
| Take PowerUser away (PowerXtreme goes with it) | – | **no** | yes |
| Make a PowerUser a PowerXtreme, or back | – | **no** | yes |
| Reload the admin list from settings | – | no | yes |

Pages and endpoints a role can't use answer **404**, as the admin panel always has, so they don't confirm what exists.

### Anonymous people on a PowerUser's graph

On a PowerUser's graph, anyone who isn't them or their friend has:
- **No username.** They show as "Someone" plus a short code, like "Someone K7Q2".
- **No user id.** Their key is an alias (`a` + 12 hex characters), so it can't be matched against ids seen elsewhere, such as a group's member list.

Aliases are an HMAC of the viewer's id and the person's id, under a random server secret (`server_keys`, row `graph_alias`). The same person always has the same alias for the same viewer, so the picture stays stable, but two PowerUsers see different aliases and can't compare notes. Aliases work in `users=` (for "show their graph"), so every feature still works.

The people picker lists only the PowerUser and their friends. Anyone else is reached by tapping them in the graph.

**The iOS app** shows its debugging tools (Developer: the server's public settings and the encryption's checks) to Admins only, going by `role` in `/api/me`. They show nothing an account couldn't see anyway (`/api/config` is public); it's scoping, not protection.

## Where Admins come from

- **Production:** the SSM parameter `/fade/admins` (SecureString, comma-separated usernames). The server reads it at start, using the instance role and its own SigV4 signing (`aws.rs`), and again on **Reload admin list** (System → Roles, Admins only) or `scripts/reload-admins.sh`, which sends the service `SIGHUP`. The parameter is set with `scripts/set-admins.sh`, outside Terraform, so the list isn't in source control or Terraform state.
- **A renamed Admin stays one.** Admins are listed by username, and an old username stays its owner's forever (usernames.rs), so the list matches a name someone has now or had before. Update the list to the new name when convenient.
- **Development and tests:** `FADE_ADMINS` (comma-separated), as before. Production sets `FADE_ADMINS_PARAM=/fade/admins` and no `FADE_ADMINS`.
- **Both, if both are set:** the union. If the parameter can't be read at start, the server keeps `FADE_ADMINS` (possibly empty) and logs an error. If a reload fails, the current list stays.

## Data

```sql
CREATE TABLE user_roles (            -- PowerUser grants; append-only marks (Rule 1)
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id),
  role TEXT NOT NULL CHECK (role IN ('power')),
  granted_by INTEGER NOT NULL REFERENCES users(id),
  granted_at INTEGER NOT NULL,
  revoked_by INTEGER REFERENCES users(id),
  revoked_at INTEGER
);
CREATE UNIQUE INDEX user_roles_current ON user_roles(user_id, role) WHERE revoked_at IS NULL;
```

Taking PowerUser away marks the grant's `revoked_at`; granting again adds a new row. The history of who granted and revoked what, and when, is kept.

PowerXtreme has its own table, `user_role_upgrades` (the same columns; `role` is `powerxtreme`, with no CHECK so later steps can join it), because `user_roles` allows only `power` and migrations never rewrite a table. It counts only on top of a current PowerUser grant, and taking PowerUser away marks it ended too.

## API

- `GET /api/me` adds `role` (`user`, `power`, `powerxtreme`, or `admin`); `is_admin` stays for older clients.
- `GET /api/admin/roles`: `{ role, people: [{ id, username, role, granted_by, granted_at }] }`. Everyone for Admins; for PowerUsers, themselves and their friends.
- `POST /api/admin/roles/{user_id}`: make them a PowerUser. Admins: anyone. PowerUsers: friends only. Not themselves, not an Admin, and not someone who already is one.
- `DELETE /api/admin/roles/{user_id}`: take PowerUser away (and PowerXtreme with it). Admins only.
- `POST /api/admin/roles/{user_id}/powerxtreme`: make a PowerUser a PowerXtreme. Admins only; 400 for someone who isn't a PowerUser now, 409 for someone who already is one.
- `DELETE /api/admin/roles/{user_id}/powerxtreme`: back to PowerUser. Admins only.
- `POST /api/admin/roles/reload`: reload the admin list. Admins only.
- The rest of `/api/admin/*` as in the table above.

Grants, revocations, and reloads are logged at info, with ids only.

## Tests

- **Unit:** role resolution (an Admin listed in settings beats a PowerUser grant), grant and revoke rules, aliases (stable per viewer, different between viewers, never containing the id).
- **Smoke** (`check_roles`): the full matrix, endpoint by endpoint, for a User, a PowerUser, a PowerXtreme, and an Admin. That includes no users table and no cost for PowerUsers, and no usernames or ids of non-friends anywhere in a PowerUser's graph responses.
- **Browser:** the System button for PowerUsers, their tabs, the Roles page (grant, revoke for Admins), and the anonymous graph.
