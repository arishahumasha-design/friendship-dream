# Historical import (Phase 7) — one time only

The Google Sheet history (June 2025 – October 2026) is moved into the ledger ONCE, on the new
production Supabase project, before the members start using the website.
Migrations: `011_historical_import.sql` (machinery) and `012_import_hardening.sql` (safety).

## The books are closed until the import
From migration 012 on, **nothing can be approved or entered** until a marker exists
(`import_done`, set by the import, or `go_live`): no approved deposit, no purchase / cost / sale / income /
expense. Members can still submit pending deposits; an admin can reject them.
**Do not approve any deposit before the import.** Pending deposits for a month up to October 2026 make the
import refuse; reject them first (they are already in the sheet).

On a project that already has (test) money and will never run the import — the current test project — set
the go-live marker right after running 012:
`insert into public.system_markers (key) values ('go_live');`

## What is imported
- 15 members, matched **only by SR NO**. The prepare step makes each member's `member_no` equal to the SR NO.
- Every month tab: 3,000 per member (17 months), kind `monthly`.
- December 2025 tab: the one-time "Yearly Amount" 67,000 per member, kind `yearly`.
- The first land, bought on **2025-12-09**: seller 1,125,000 + deed 113,500 + copy 2,000 + other 500
  = **1,241,000** cost basis, through the same purchase code as the website (`purchase_core`):
  `cost * free / sum(free)`, largest remainder; equal free money, so the 5 leftover cents go to SR NO 1–5.
- Every imported deposit gets the note `historical import`; transaction IDs (one repeated placeholder) are ignored.
- The February 2026 sheet note is NOT parsed and NOT put on any deposit. A reviewed summary of it is stored
  once on the import batch (admins only). Its member-by-member lines stay in the sheet: they name members and
  amounts, and the repository must not contain personal data.
- Phones, emails, notes and the Rules tab of the sheet are never read.

Expected result (checked automatically, the import fails loudly on any difference):
total deposits 1,770,000 · invested 1,241,000 · cash 529,000 · every member's capital 118,000 ·
15 participation rows summing to exactly 1,241,000 · `check_invariants()` all rules pass.

## Safety
- Only from the SQL Editor (no JWT, session user postgres); no website role can call any import function.
- A **confirm code** ties the run to the exact member map: `md5(sorted "sr:member_id" pairs | md5(payload))`.
  `run_verify.sql` prints it after you have checked every SR NO → name; dry run and real run must use it.
- Refuses forever after `import_done` or `go_live`; markers and batches are append-only.
- Only the import can mark rows as imported (`import_batch_id`); the SR → member map is kept on the batch.
- Payment rules (late fee, paid on time, suspension) must only use `counts_for_payment_rules(deposit)`,
  which leaves out historical, imported and back-month deposits.

## Files
| File | Committed? | What |
|---|---|---|
| `supabase/migrations/011_*.sql`, `012_*.sql` | yes | the machinery and its safety |
| `supabase/import/xlsx_mini.mjs` | yes | tiny .xlsx reader (no dependencies) |
| `supabase/import/build_import.mjs` | yes | sheet + map → SQL files |
| `supabase/import/member_map.example.csv` | yes | shape of the map (no real names) |
| `supabase/import/member_map.csv` | **no** (git-ignored) | SR NO, sheet name, login email |
| `Friendship Dream (FD).xlsx` | **no** (git-ignored) | the sheet export |
| `%USERPROFILE%\fd-import-out\run_*.sql` | outside the project | generated SQL with the emails — **delete after the run** |
| `supabase/dev/local/test_import.mjs` | yes | local test with 15 fake members |

## Steps for the real run (new production project)
1. Create the new Supabase project. SQL Editor: run `supabase/production_setup.sql` (last table: every rule
   `ok = true`), then `supabase/seed_policies.sql`. Set Authentication (confirm email, site URL, redirect URL) and
   put the new project's URL / publishable key / site URL in Vercel. Do NOT set the go_live marker.
2. Sign up yourself on the website and CONFIRM your email, then run the "super admin bootstrap" SQL from the top of
   `supabase/migrations/014_launch_hardening.sql` (it finds you by `auth.users` email + id and needs a confirmed
   email; it must say `UPDATE 1`). Do not use the older one-liner at the end of section 001.
3. Ask all 15 members to sign up with their own email and confirm it. Approve nothing.
4. Fill in `supabase/import/member_map.csv`: each member's login email in the third column, by SR NO.
   Every step below finds accounts by the LOGIN email in `auth.users` (not the profile) and only counts
   accounts whose email is CONFIRMED (`email_confirmed_at` set): unconfirmed members show up as a problem.
5. `node supabase/import/build_import.mjs` → writes `run_prepare.sql` and `run_verify.sql` to
   `%USERPROFILE%\fd-import-out`.
6. SQL Editor: run `run_prepare.sql` → 15 rows: `active`, `joined_on = 2025-06-01`, `member_no` = SR NO.
7. SQL Editor: run `run_verify.sql` → for each SR NO: the sheet name next to the account's full name, member no,
   status, joined_on, email confirmed, `problem = ok`. Check EVERY name. The last row is the CONFIRM CODE.
8. `node supabase/import/build_import.mjs --confirm <code>` → also writes `run_import_dry.sql` and `run_import_real.sql`.
9. SQL Editor: run `run_import_dry.sql` → the report (per member incl. free money at purchase, per month, plan,
   checks). Nothing is saved. If it says pending deposits exist, reject those deposits and run it again.
10. SQL Editor: run `run_import_real.sql` → the same report and a `DONE` line.
11. Check: `select * from public.check_invariants(false);` — every row `ok = true`. The home page must show
    total fund 1,770,000, invested 1,241,000, cash 529,000.
12. Delete the folder `%USERPROFILE%\fd-import-out` (it contains the emails).
13. The books are now open. When the site is opened to members you may also set the go_live marker.
