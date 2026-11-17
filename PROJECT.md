# Friendship Dream (FD) — Samiti Management Website

Owner: Ibrahim (Bengali speaker; talk to him in Bengali, keep code and file names in English).
Brand: **Friendship Dream (FD)**. Logo: an FD monogram in an emerald circle with a small gold spark (emerald `#0B7A5A`, gold `#F5B83D`, ink `#10201A`, mist `#F3F7F5`; dark mode accent `#34D399`).
Design reference: the Claude design canvas "সমিতি হোম স্ক্রিন ডিজাইন" (https://claude.ai/artifact/9NF34WgG6fvtn1ryc761zx) has the approved home dashboard and logo. Match its look: modern, glass-style cards, rounded corners, count-up numbers, a ring of member photos slowly rotating around a "15 members" disc, light and dark mode.

## What this is
A private web app for a 15-member, interest-free (halal) savings and investment samiti. Each member pays 3,000 taka every month. The site keeps members, deposits, expenses, investments and policies, with admin approval for money.

## Tech
- Next.js (App Router) + TypeScript + Tailwind CSS
- Supabase: Auth (email + password), Postgres, private Storage. Database is already created.
- Deploy later on Vercel (free plan).
- UI language: English by default, switchable to Bengali (all UI strings in two dictionaries). Light and dark mode.
- Use `@supabase/ssr` for auth in Next.js. Only the publishable key is in the browser. NEVER put a secret / service_role key in code or the browser.

Env vars are in `.env.local` (`NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`).

## Database
Already designed in `supabase/schema.sql` (Ibrahim runs it once in the Supabase SQL Editor), then `supabase/seed_policies.sql`. Read both files before coding. Key facts:
- Row Level Security is ON everywhere; access rules live in the database. Do not weaken them to make something work. Fix the query instead.
- Roles: `member`, `admin`, `super_admin` (Ibrahim). Only super admin changes roles and settings. Status: `pending` (just signed up) → `active` (approved by admin) → `suspended` / `exited`.
- Approved/rejected deposits and approved expenses cannot be edited or deleted. Corrections = a new entry (deposits can be negative when entered by an admin) or "reverse" for expenses.
- Dashboard numbers come from RPC functions: `fund_summary()`, `member_totals()`, `deposit_ledger()`. Do not compute totals in the browser from raw rows.
- Files: private buckets `documents`, `receipts`, `avatars`. Path must start with the user id: `<user-id>/<filename>`. Show files with short-lived signed URLs.
- First super admin: after Ibrahim signs up, he runs the one-line SQL at the bottom of `schema.sql`.

## Money model (important)
- **Capital** = approved monthly + yearly + other deposits.
- **Late fees** are tracked separately and are NOT member capital.
- **Investments (land, shops) are assets, not expenses.** Buying land does not reduce the total fund.
- `total_fund = capital + late fees + investment income + realized profit − expenses`
- `invested = cost of investments still held`
- `cash_available = total_fund − invested`
- Home shows three big numbers: **Total fund**, **Invested**, **Cash in hand (bank/cash)**.
- Selling an investment: admin enters sale date and amount; profit or loss = sale − cost goes into the total fund; invested drops; cash rises.
- Shares: `floor(capital / share_value)`, share_value = 5,000 (setting).
- Money: show as `৳ 1,23,456` (en-IN grouping). Monthly amount 3,000. Deposit deadline: last day of every month.

## Roles and visibility
- Public (not logged in): landing page with a few short messages (`site_content`), About, Login/Sign up. No member photos, no money numbers.
- Logged-in active members: home dashboard, members list, own profile, own transaction history, deposits submit, expenses list, investments list, policies, notices.
- Members see other members' name, photo and deposit totals (setting `members_can_see_others`, default true). They NEVER see other members' NID, passport, phone, address, nominee or documents.
- Admin: approve/reject deposits, approve new members, enter expenses and investments, enter historical records, edit policies/notices/about text, view documents.
- Super admin: everything admin can, plus manage admins, change settings, view audit log.

## Pages
Public: `/` landing, `/about`, `/login`, `/signup`
Member: `/home` (dashboard), `/members`, `/members/[id]` (details + transaction history; documents only for owner/admin), `/deposits` (submit + own history), `/expenses`, `/investments`, `/policies`, `/notices`, `/profile`
Admin: `/admin/deposits` (pending queue), `/admin/members`, `/admin/expenses`, `/admin/investments`, `/admin/policies`, `/admin/notices`, `/admin/import`, `/admin/settings` (super admin), `/admin/audit` (super admin)

### Home dashboard (see design canvas)
Hero greeting, total fund / invested / cash card, rotating member-photo ring, KPI cards (total capital, collected this month vs target 45,000 with progress bar, spent this month, deposits waiting for approval), member cards (photo, name, capital, shares, Paid/Pending chip, click opens details), this month's expenses by category, latest activity.

### Signup
Email + password, full name; then a form for: name (English/Bengali), father and mother name, date of birth, phone, present/permanent address, photo, NID front/back, signature, passport (optional), nominee (name, relation, phone, address, NID number, photo, NID image). Account stays `pending` until an admin approves.

### Deposit submit
Amount, month, method (bank/bKash/Nagad/Rocket/cash), transaction ID, receipt image, note. Status pending → admin approves/rejects (with reason). Duplicate transaction IDs are blocked by the database.

## Samiti rules that affect features
Interest-free (no loans module). Late fee after the month-end deadline (amount is a setting, currently 0). Two months late in a row → warn; third month → admin is prompted to suspend (admin decides). No exit before 2 years. 3-year maturity with profit share. 5,000-taka shares with yearly share receipt (PDF). 6-monthly audit report (PDF). New members need existing members' consent (optional vote feature, later). The policies text is in `seed_policies.sql`.

## Build order (do one phase at a time, test, then continue)
1. Project setup, Tailwind, light/dark theme, English/Bengali switch, logo, Supabase client, auth (signup, login, logout), route protection by role/status.
2. Signup profile form and document uploads; admin approves members.
3. Deposits: submit, admin approval queue, member history; settings.
4. Home dashboard (RPC functions), members list and member detail page with transaction history.
5. Expenses, investments (buy, income, sell), the three-number fund display.
6. Policies, notices, about, public landing page, admin content editing.
7. Import old records: one-time import of the Google Sheet history (June 2025 – October 2026) into the ledger on the new production project. See docs/HISTORICAL_IMPORT.md (supersedes the old CSV-upload idea).
8. Reports: PDF/Excel export, share receipt PDF, 6-month audit report; late-fee and overdue warnings; admin 2-factor login.
9. Security review, then deploy to Vercel.

## Rules for working on this project
- Money records are never deleted. Every important change is audited (database triggers).
- Keep the UI simple for non-technical members; mobile first.
- Ask Ibrahim before changing anything about how money or visibility works.
- Do not commit `.env.local`. Never ask Ibrahim to paste secret keys into chat.

## Open questions (use settings or ask Ibrahim, do not guess)
- Late fee amount, and whether it goes to samiti income or charity.
- Yearly saving amount and month.
- Exact share rule for leftover amounts (default: whole shares only, remainder shown).
- Profit split: by capital or by shares (not decided).
- Policy rule 12 (new members / misconduct) text is incomplete.
- Google Sheet layout for the import (waiting for a sample).
- Are land purchases for resale or to hold/rent?
