# A stable address for the apps: api.napsack.io

Status: proposed (Nate, 2026-10-29: "api.napsack.io is a good idea for mobile clients"). Not built. The infrastructure part is the owner's to apply.

## Why

An installed app keeps the server address it was built with, and old versions stay on phones for months ([mobile.md](mobile.md), Decisions still open). The web client is easy: it's served from the domain it talks to, so a domain move ([domain-move.md](../operations/domain-move.md)) takes it along. The apps aren't. If they talk to `napsack.io` and the site moves again, every installed app breaks unless `napsack.io` keeps working forever.

A name only for the apps fixes that. Wherever the web app lives, `api.napsack.io` keeps answering the API, so the website can move freely and the apps never notice. It's also a natural place for API versioning later.

## What it is

- **`api.napsack.io` answers the API and nothing else.** It serves `/api/*`, including the socket at `/api/ws`, from the same server as the site. The web client, `/admin`, and every other path return 404 there. The apps don't need them, and a host that only does the API has less to get wrong.
- **The same server and the same binary.** No new instance or certificate set-up by hand: Caddy gets a certificate for the extra name as it does for the site.
- **Staging gets the same:** `api.staging.napsack.io`. Development builds keep pointing wherever `Local.xcconfig` says.
- **The apps' default server becomes `https://api.napsack.io`** for release builds (TestFlight and the App Store). That goes in `Config/Base.xcconfig`, `NAPSACK_SERVER_URL`; development and staging builds keep theirs. Admins can still point a phone elsewhere (the Developer screen).
- **The path stays `/api/...`.** The apps build `https://api.napsack.io/api/config`, the same paths as today. A shorter `/config` would need the server to route two ways and every client to know which. Versioning stays as now: `api_version` in `/api/config`, the API only grows, and the `426` floor ([releasing.md](../operations/releasing.md)) retires apps that are too old. If an incompatible API is ever needed, it can live beside the old one (`/api/v2/...`) on the same name.

## Changes

1. **DNS** (`infra/dns.tf`): an `A` record for `api.<zone>` pointing at the Elastic IP, like `www`. On its own it changes nothing users see.
2. **Caddy** (`infra/user_data.sh.tftpl`): a site for `api.$DOMAIN` that proxies `/api/*` to the server and answers 404 for anything else, with the same headers and body limit as the main site.
   - This is the boot script, so applying it **replaces the instance**: production's and staging's (CLAUDE.md, Rule 1). That means the full checklist: snapshot, row counts, then checks after.
   - Do staging first. Better still, bundle it with the next change that replaces the instance anyway.
3. **The server**: nothing needed. It doesn't check `Host`, uses bearer tokens (no cookies, so nothing is tied to an origin), and logs `host` per request already, so the apps' traffic is visible on its own in the log viewer.
4. **The apps**: release builds default to `https://api.napsack.io`.
5. **Docs**: `operations.md` (the extra name), `domain-move.md` (a move keeps `api.` pointed at the server), `staging.md`, and this file moves to `docs/implementation/` once built.

## How it's checked

- `curl https://api.napsack.io/api/config` answers the same as the site's, and `curl https://api.napsack.io/` is a 404.
- The smoke test runs against the `api.` name too (a `SMOKE_API_URL`, or run it twice in `scripts/test-staging.sh` against staging).
- The iOS app's live tests pass against `https://api.staging.napsack.io`.

## Open

- **Links people share** (your add-me link, invite links) must use the site's address, not `api.`: the server returns a path (`/i/<token>`), and the apps put the server's address in front today. Before release builds switch, `/api/config` should say the site's address (it knows it: `FADE_PUBLIC_URL`) and the apps use that.

- **When to apply it:** Nate's call, since it replaces production's instance. It isn't urgent until the first TestFlight build, which is also waiting on the Developer Program.
