# Email on napsack.io

Planning only ([I9](plan.md#i9-email-on-napsackio)). Goal: a real mailbox for `nate@napsack.io` that works on a computer and a phone, for as little money and upkeep as possible. Nothing here is built yet.

## Recommendation: iCloud+ custom domain

If you already pay for iCloud+ (any tier, from $0.99 a month for 50 GB), this costs **nothing extra**. Otherwise it's $0.99 a month.

- **Phone:** the built-in Mail app on iPhone, with no setup beyond signing in to iCloud.
- **Computer:** Mail on a Mac; on Windows, icloud.com/mail in a browser, or any IMAP client (Outlook, Thunderbird) with an app-specific password.
- **Sending** works from the same address in all of those. Apple handles spam filtering, SPF, and DKIM.
- **Limits:** a handful of custom domains per account and a few addresses per domain (Apple has been raising these; check the current numbers when setting it up). That's plenty for `nate@`, and maybe `hello@` or `support@` later.
- **Requirements:** an Apple Account with two-factor authentication, and iCloud Mail turned on (it needs an `@icloud.com` address to exist first).

### What it takes

All DNS stays in Route 53 and goes in Terraform (`infra/dns.tf`), so it's reviewed in a plan like everything else. Apple's setup screen (Settings → Apple Account → iCloud → Mail → Custom Email Domain, or icloud.com) shows the exact values. They are, in shape:

| Record | Name | Value |
|---|---|---|
| TXT | `napsack.io` | `apple-domain=<code from Apple>` |
| MX | `napsack.io` | `10 mx01.mail.icloud.com.`, `10 mx02.mail.icloud.com.` |
| TXT | `napsack.io` | `v=spf1 include:icloud.com ~all` |
| CNAME | `sig1._domainkey.napsack.io` | `sig1.dkim.napsack.io.at.icloud.com.` |
| TXT | `_dmarc.napsack.io` | `v=DMARC1; p=quarantine; rua=mailto:nate@napsack.io` (start with `p=none` for a couple of weeks) |

The two TXT records at the apex go in one Route 53 record set (Route 53 holds all TXT values for a name together). Extra cost: none; the zone is already paid for, and queries for these records are fractions of a cent.

Steps, about 20 minutes:
1. Start the custom domain in iCloud settings; choose "use your own domain" and enter `napsack.io`.
2. Add the records above to `infra/dns.tf` (a `mail` section, behind a variable such as `email_provider = "icloud"`), `terraform plan -target`, read it, and apply.
3. Back in iCloud, verify; create `nate@napsack.io`.
4. Send a test both ways; check that the headers show `spf=pass` and `dkim=pass` (Gmail: "Show original").

## Other options considered

| Option | Cost | Desktop | Phone | Why not first |
|---|---|---|---|---|
| **iCloud+ custom domain** | $0 extra if already on iCloud+, else $0.99/mo | Mac Mail, IMAP, web | iPhone Mail | Recommended |
| Zoho Mail Free | $0 (up to 5 users, 5 GB) | Web only | Zoho Mail app only | No IMAP, so no Apple Mail or Outlook; one more app to check |
| Zoho Mail Lite | ~$1–1.25/user/mo, annual | IMAP, web | Any client | Fine choice if you don't use iCloud; another account to keep |
| Fastmail | ~$5/user/mo | Excellent | Excellent | Best mail service here, five times the price |
| Proton Mail (paid) | ~$4–7/mo | Bridge app needed for IMAP | Proton app | End-to-end encrypted, but awkward with other clients |
| Google Workspace | ~$7/user/mo | Gmail | Gmail | Most expensive; nothing needed beyond iCloud |
| Amazon WorkMail | n/a | | | No new customers since April 30, 2026; shuts down March 31, 2027 |
| Forward-only (e.g. SES receiving into S3, or a registrar's forwarding) + send-as from Gmail | ~$0 | Gmail | Gmail | Two systems to keep working, worse deliverability, and SES receiving doesn't give you a mailbox. Too fiddly for a personal address |
| Our own mail server on the EC2 instance | ~$0 | | | No: port 25 is throttled on EC2, IP reputation is poor, and it puts mail next to user data on a t4g.nano. Never |

Prices are from comparison sites in October 2026 and vary with discounts and prepay terms. Check the provider's own page, and its renewal price, before paying.

## Later: napsack sending email itself

Separate from a mailbox. If napsack ever sends mail (password reset links, say), use Amazon SES for sending only, from a subdomain such as `mail.napsack.io`. That keeps its SPF and DKIM apart from the mailbox's, and a sending problem can't hurt `nate@`'s reputation. Not needed now: account recovery uses recovery keys and admin reset codes.

## Decision for Nate

- Are you on iCloud+ already? If yes, it's free; go with iCloud. If you'd rather not tie it to your Apple account, Zoho Mail Lite at about $1 a month is the runner-up.
- When you're ready, I can add the DNS records to Terraform once Apple shows you the verification code.
