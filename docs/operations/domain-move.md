# Moving to napsack.io

Status: **done (2026-10-23).** Requested by Nate (I7 in [plan.md](../management/plan.md)). `napsack.io` (registered in Route 53, with its own zone) is the production address. Every old address redirects to it permanently.

## What changes

| | Before | After |
|---|---|---|
| The app | https://napsack.getattr.com | **https://napsack.io** |
| https://napsack.getattr.com/... | the app | 301 → https://napsack.io/... (same path; `#invite=` links keep working) |
| https://www.napsack.io, https://fade.getattr.com | –, 301 | 301 → https://napsack.io |
| DNS | hand-made records | `napsack.io` and `www.napsack.io` A records in Terraform (`infra/dns.tf`); the getattr.com records stay as they are, pointing at the same Elastic IP. Since 0.47.0 also `api.napsack.io`, the apps' name for the API ([api-host.md](../implementation/api-host.md)): a future move keeps it pointing at the server, so installed apps never notice |

Nothing in the code names the domain. Scripts and the health monitor read it from `terraform output url`. `FADE_PUBLIC_URL` (the contact in push requests) follows from Terraform. The GitHub release workflow's `APP_URL` repository variable needs updating by hand: see "After", below.

## What people will notice

A new address is a new **origin** to a browser, and everything a browser keeps is per origin. So on napsack.io, everyone starts fresh on their device:

- **Sign in again** with their password. Their key comes back from the server, wrapped by the password (as on any new device), so **all messages and pics are still there**. A recovery key also works.
- **Notifications** need turning on again (the prompt shows up as usual).
- **A Home Screen app** of the old address opens the redirect. Adding napsack.io to the Home Screen again gives the proper app.
- **Friends' keys** are pinned afresh on first contact. Safety codes don't change, because they come from the keys, not the address.

Accounts, friends, chats, groups, and unopened pics are untouched: they live on the server, and the database doesn't move. A short note to friends ("napsack moved to napsack.io; sign in again there") covers it.

## How it was done

The server's boot script contains the domain (Caddy's config), and changing it replaces the server: the normal path in CLAUDE.md, with its Rule 1 checklist (a snapshot and row counts before, the volume, the counts, and the build checked after). DNS came first, so Caddy could get certificates as soon as the new server started, and the health monitor watched only, so it wouldn't "fix" a server still booting. The step-by-step log is in the owner's private notes.

## After

- **GitHub:** the repository variable `APP_URL` was set to `https://napsack.io`. The release workflow uses it to check a deploy.
- **The getattr.com records** (`napsack.getattr.com`, `fade.getattr.com`) stay pointing at the Elastic IP for as long as the redirects should work. Caddy needs them to renew those certificates.
- **The iPhone app:** its links (Associated Domains) name the site: `NAPSACK_LINK_HOST` in `ios/Config/Release.xcconfig`. A new domain needs a new app build for links to open the app; until then they open the site. The app's API name (`api.napsack.io`) is meant to stay put ([api-host.md](../implementation/api-host.md)).
