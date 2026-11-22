# Kosár

Shop management for small greengrocer chains: suppliers and orders, receiving goods with invoice photos, a shared warehouse, per-shop stock and cash, daily close with wages, partner profit shares, reports. Arabic and Hungarian.

## Files

| File | What it is |
|---|---|
| `index.html` | The whole web app. With `CFG` empty it runs as a demo and keeps data in the browser. |
| `sw.js` | Lets the page open with no connection. Must sit next to `index.html`. |
| `schema.sql` | Database tables and access rules for Supabase. Run once on a new project. |
| `storage.sql` | Private storage for invoice photos. Run after `schema.sql`, as a separate query. |
| `ai-function.ts` | Supabase Edge Function named `ai`: reads invoices and answers questions about the numbers. |

## Setup

1. Create a Supabase project in an EU region.
2. SQL Editor: run `schema.sql`, then `storage.sql`.
3. Edge Functions: create a function named `ai`, paste `ai-function.ts`, add the secret `ANTHROPIC_API_KEY`.
4. Project Settings > API: copy the project URL and the anon key into `index.html`, in the line `const CFG={url:'',key:''}`.
5. Authentication: set the Site URL to where the page is hosted, keep "Confirm email" on, and connect an SMTP service before inviting a team.
6. Host `index.html` and `sw.js` together over HTTPS.
7. The first person to sign up creates the company and becomes its owner. Shares, team, workers and prices are set under Settings.

The anon key is public by design. Access is enforced by the row-level security rules in `schema.sql`.

## Roles

- **owner**: everything
- **partner**: reads the shops they hold a share in, the warehouse, their own withdrawals
- **staff**: one shop: daily close and evening stock count
- **warehouse**: orders, receiving, sending goods to shops

## Status

The accounting logic and the access rules are covered by automated tests against a local Postgres. Nothing has been run against a live Supabase project or checked in a browser yet: logins, e-mails, photo upload, the AI function and offline mode all need a first real test.
