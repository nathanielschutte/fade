# Moving to napsack.io

Status: **done (2026-10-23).** Requested by Nate (I7 in [plan.md](../management/plan.md)). `napsack.io` (registered in Route 53, with its own zone) is the production address. Every old address redirects to it permanently.

## What changes

| | Before | After |
|---|---|---|
| The app | https://napsack.getattr.com | **https://napsack.io** |
| https://napsack.getattr.com/... | the app | 301 → https://napsack.io/... (same path; `#invite=` links keep working) |
| https://www.napsack.io, https://fade.getattr.com | –, 301 | 301 → https://napsack.io |
| DNS | hand-made records | `napsack.io` and `www.napsack.io` A records in Terraform (`infra/dns.tf`); the getattr.com records stay as they are, pointing at the same Elastic IP |

Nothing in the code names the domain. Scripts and the health monitor read it from `terraform output url`. `FADE_PUBLIC_URL` (the contact in push requests) follows from Terraform. The GitHub release workflow's `APP_URL` repository variable needs updating by hand: see "After", below.

## What people will notice

A new address is a new **origin** to a browser, and everything a browser keeps is per origin. So on napsack.io, everyone starts fresh on their device:

- **Sign in again** with their password. Their key comes back from the server, wrapped by the password (as on any new device), so **all messages and pics are still there**. A recovery key also works.
- **Notifications** need turning on again (the prompt shows up as usual).
- **A Home Screen app** of the old address opens the redirect. Adding napsack.io to the Home Screen again gives the proper app.
- **Friends' keys** are pinned afresh on first contact. Safety codes don't change, because they come from the keys, not the address.

Accounts, friends, chats, groups, and unopened pics are untouched: they live on the server, and the database doesn't move. A short note to friends ("napsack moved to napsack.io; sign in again there") covers it.

## How it was done

The server's boot script contains the domain (Caddy's config), and changing it replaces the server: the normal path in CLAUDE.md, with its Rule 1 checklist.

1. **DNS first:** create the `napsack.io` and `www` records (a targeted apply of `infra/dns.tf` only), and wait until they resolve to the Elastic IP, so Caddy can get certificates as soon as it starts.
2. **The health monitor to watch-only** (`health_act = false`), so it doesn't "fix" a server that's still booting.
3. **Rule 1 before:** snapshot the data volume and wait for it; record row counts (read-only).
4. **The switch:** `domain = "napsack.io"`, `redirect_domains = ["napsack.getattr.com", "fade.getattr.com", "www.napsack.io"]`. Read the plan: the instance replaced, the data volume unchanged, the settings parameter and the health monitor's address updated. Then apply.
5. **Rule 1 after:** the data volume mounted on the new server; row counts equal or higher; https://napsack.io serves the expected build; each old address answers 301 to the new one.
6. **The health monitor back on** (`health_act = true`).

## After

- **GitHub:** set the repository variable `APP_URL` to `https://napsack.io` (`terraform -chdir=infra output github_variables` lists them). The release workflow uses it to check a deploy.
- **The getattr.com records** (`napsack.getattr.com`, `fade.getattr.com`) stay pointing at the Elastic IP for as long as the redirects should work. Caddy needs them to renew those certificates.
