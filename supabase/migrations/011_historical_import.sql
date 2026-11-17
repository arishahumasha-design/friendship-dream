-- =====================================================================
-- Phase 7: one-time historical import (Google Sheet -> ledger). See docs/HISTORICAL_IMPORT.md.
-- Run ONCE in Supabase Dashboard > SQL Editor (paste whole file > Run), after 010.
-- Safe to run again. Adds the import machinery; it does NOT import anything by itself.
--
-- The import itself is public.import_history(payload, dry_run):
--   * only from the SQL Editor (no JWT, session user postgres); no API role can call it;
--   * refuses if an 'import_done' or 'go_live' marker exists, or any import batch exists;
--   * dry_run = true (default): does the whole import inside a sub-transaction, reports, rolls back;
--   * posts through the normal rules: deposits through the deposit triggers, the land purchase through
--     the SAME purchase code as approve_investment (purchase_core). The two-person rule is replaced
--     by an explicit import batch id on the purchase rows (and checked by check_invariants rule 27).
-- =====================================================================

-- ---------- 1) Markers and batches (append-only) ----------
create table if not exists public.system_markers (
  key     text primary key check (key in ('import_done', 'go_live')),
  value   jsonb not null default '{}'::jsonb,
  set_at  timestamptz not null default now()
);
create table if not exists public.import_batches (
  id          uuid primary key default gen_random_uuid(),
  label       text not null,
  source_note text,
  created_at  timestamptz not null default now()
);

do $$
declare tb text;
begin
  foreach tb in array array['system_markers', 'import_batches'] loop
    execute format('alter table public.%I enable row level security', tb);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', tb);
    execute format('drop trigger if exists %I on public.%I', tb || '_no_update_delete', tb);
    execute format('create trigger %I before update or delete on public.%I for each row execute function public.block_ledger_changes()',
                   tb || '_no_update_delete', tb);
    execute format('drop trigger if exists %I on public.%I', tb || '_no_truncate', tb);
    execute format('create trigger %I before truncate on public.%I for each statement execute function public.block_ledger_changes()',
                   tb || '_no_truncate', tb);
  end loop;
end $$;
grant select on public.system_markers, public.import_batches to authenticated;
drop policy if exists system_markers_select on public.system_markers;
create policy system_markers_select on public.system_markers for select to authenticated using (public.is_admin());
drop policy if exists import_batches_select on public.import_batches;
create policy import_batches_select on public.import_batches for select to authenticated using (public.is_admin());

-- ---------- 2) Rows can name the import batch they came from ----------
alter table public.deposits       add column if not exists import_batch_id uuid references public.import_batches (id);
alter table public.investments    add column if not exists import_batch_id uuid references public.import_batches (id);
alter table public.money_requests add column if not exists import_batch_id uuid references public.import_batches (id);

-- Imported purchase requests have no human maker/checker: the import batch takes their place.
alter table public.money_requests alter column proposed_by drop not null;
do $$ begin
  alter table public.money_requests add constraint money_requests_maker_ck
    check (proposed_by is not null or import_batch_id is not null);
exception when duplicate_object then null; end $$;
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.money_requests'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%decided_by IS DISTINCT FROM proposed_by%'
              and conname <> 'money_requests_two_people_ck'
  loop
    execute format('alter table public.money_requests drop constraint %I', c.conname);
  end loop;
end $$;
do $$ begin
  alter table public.money_requests add constraint money_requests_two_people_ck
    check (status <> 'approved' or import_batch_id is not null or decided_by is distinct from proposed_by);
exception when duplicate_object then null; end $$;

-- ---------- 3) One purchase code path for approve_investment AND the import ----------
create or replace function public.purchase_core(
  p_title text, p_kind text, p_description text, p_date date, p_cost numeric, p_cap numeric,
  p_created_by uuid, p_approved_by uuid, p_import_batch uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_basis numeric := p_cost + p_cap;
  v_free  numeric;
  v_inv   uuid;
  v_share numeric;
begin
  perform public.take_fund_lock();
  -- who takes part: active NOW, joined on or before the purchase date, with free money > 0
  select coalesce(sum(b.free), 0) into v_free
    from public.member_balances_internal() b
   where b.status = 'active' and b.joined_on is not null and b.joined_on <= p_date and b.free > 0;
  if v_free < v_basis then
    raise exception 'Not enough free money: this purchase needs %, the members who can take part have %.', v_basis, v_free;
  end if;

  perform set_config('fd.posting', 'on', true);
  insert into public.investments (title, kind, description, purchase_date, cost, capitalized_costs, status,
                                  created_by, approved_by, import_batch_id, created_at)
  values (p_title, p_kind, p_description, p_date, p_cost, p_cap, 'held',
          p_created_by, p_approved_by, p_import_batch, clock_timestamp())
  returning id into v_inv;

  -- contribution_i = basis * free_i / sum(free): exact whole cents, largest remainder, adds up exactly
  select coalesce((select (value #>> '{}')::numeric from public.app_settings where key = 'share_value'), 5000) into v_share;
  insert into public.investment_participation (investment_id, member_id, contribution_delta, capital_at_purchase,
                                               shares_at_purchase, free_at_purchase, reason, created_at)
  with b as (
    select m.member_id, m.member_no, m.capital, m.free,
           div(v_basis * 100 * m.free, v_free) as fl,
           mod(v_basis * 100 * m.free, v_free) as rest
      from public.member_balances_internal() m
     where m.status = 'active' and m.joined_on is not null and m.joined_on <= p_date and m.free > 0
  ),
  k as (select (v_basis * 100 - sum(fl))::bigint as leftover from b),
  x as (select b.*, row_number() over (order by b.rest desc, b.member_no) as rn from b)
  select v_inv, x.member_id, (x.fl + case when x.rn <= k.leftover then 1 else 0 end) / 100.0,
         x.capital, floor(x.capital / v_share)::int, x.free, 'purchase', clock_timestamp()
    from x, k
   where x.fl + case when x.rn <= k.leftover then 1 else 0 end > 0;
  perform set_config('fd.posting', 'off', true);

  perform public.assert_cash_nonnegative();
  return v_inv;
end $$;

create or replace function public.approve_investment(p_request uuid, p_expected_basis numeric) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  r       public.money_requests;
  v_uid   uuid;
  v_cap   numeric;
  v_inv   uuid;
begin
  perform public.take_fund_lock();
  v_uid := public.require_admin();
  r := public.pending_request(p_request, 'purchase');

  if exists (select 1 from public.money_requests
              where kind = 'investment_cost' and purchase_request_id = r.id and status = 'pending') then
    raise exception 'Approve or reject the pending cost items of this purchase first.';
  end if;
  select coalesce(sum(amount), 0) into v_cap from public.money_requests
   where kind = 'investment_cost' and purchase_request_id = r.id and status = 'approved';
  if p_expected_basis is distinct from r.amount + v_cap then
    raise exception 'The total cost is now % (you confirmed %). Check it and approve again.', r.amount + v_cap, p_expected_basis;
  end if;

  v_inv := public.purchase_core(r.title, r.investment_kind, r.description, r.event_date, r.amount, v_cap,
                                r.proposed_by, v_uid, null);
  perform public.close_request(r.id, 'approved', v_inv, null);
  return v_inv;
end $$;

-- ---------- 4) The import ----------
-- Payload (built by supabase/import/build_import.mjs from the sheet + member_map.csv):
-- { "label": text, "source_note": text, "joined_on": "2025-06-01",
--   "members":  [ { "sr_no": 1, "email": "..." }, ... ],
--   "deposits": [ { "sr_no": 1, "month": "2025-06-01", "kind": "monthly"|"yearly", "amount": 3000, "note": text }, ... ],
--   "purchase": { "title": text, "kind": "land", "date": "2025-12-09", "cost": 1125000, "description": text,
--                 "items": [ { "title": text, "amount": 113500 }, ... ] },
--   "expect":   { "members": 15, "total_deposits": 1770000, "invested": 1241000, "cash": 529000,
--                 "member_capital": 118000, "participants": 15 } }
create or replace function public.import_apply(p jsonb) returns text[]
language plpgsql security definer set search_path = '' as $$
declare
  rep       text[] := '{}';
  v_list    text;
  v_batch   uuid;
  v_joined  date := (p ->> 'joined_on')::date;
  v_pdate   date := (p #>> '{purchase,date}')::date;
  v_cost    numeric := (p #>> '{purchase,cost}')::numeric;
  v_cap     numeric;
  v_inv     uuid;
  v_req     uuid;
  v_n       numeric;
  v_m       numeric;
  v_c       integer;
  r         record;
  e         jsonb := p -> 'expect';
begin
  ---- checks on the payload and on the database
  if (select count(*) from jsonb_array_elements(p -> 'members')) <> (e ->> 'members')::int then
    raise exception 'IMPORT: the member map has % rows, expected %.', jsonb_array_length(p -> 'members'), e ->> 'members';
  end if;
  create temp table if not exists pg_temp.fd_import_map (sr_no int primary key, email text, member_id uuid) on commit drop;
  truncate pg_temp.fd_import_map;
  insert into pg_temp.fd_import_map (sr_no, email)
  select (m ->> 'sr_no')::int, lower(btrim(m ->> 'email')) from jsonb_array_elements(p -> 'members') m;
  if exists (select 1 from pg_temp.fd_import_map where email is null or email = '') then
    raise exception 'IMPORT: some members have no email in the map (fill member_map.csv).';
  end if;
  if (select count(distinct email) from pg_temp.fd_import_map) <> (select count(*) from pg_temp.fd_import_map) then
    raise exception 'IMPORT: the same email appears twice in the map.';
  end if;
  update pg_temp.fd_import_map f set member_id = pr.id from public.profiles pr where lower(pr.email) = f.email;
  select string_agg(sr_no::text, ', ' order by sr_no) into v_list from pg_temp.fd_import_map where member_id is null;
  if v_list is not null then
    raise exception 'IMPORT: no account found for SR NO %. Every member must sign up first.', v_list;
  end if;
  select string_agg(f.sr_no::text, ', ' order by f.sr_no) into v_list
    from pg_temp.fd_import_map f join public.profiles pr on pr.id = f.member_id
   where pr.status <> 'active' or pr.joined_on is distinct from v_joined;
  if v_list is not null then
    raise exception 'IMPORT: SR NO % must be ACTIVE with joined_on = % (run the prepare step first).', v_list, v_joined;
  end if;
  if exists (select 1 from public.member_ledger) or exists (select 1 from public.fund_reserve)
     or exists (select 1 from public.investments) or exists (select 1 from public.expenses)
     or exists (select 1 from public.investment_income) then
    raise exception 'IMPORT: the books are not empty. The import only runs on a fresh project.';
  end if;

  create temp table if not exists pg_temp.fd_import_rows (sr_no int, month date, kind text, amount numeric, note text) on commit drop;
  truncate pg_temp.fd_import_rows;
  insert into pg_temp.fd_import_rows
  select (d ->> 'sr_no')::int, (d ->> 'month')::date, d ->> 'kind', (d ->> 'amount')::numeric, d ->> 'note'
    from jsonb_array_elements(p -> 'deposits') d;
  if exists (select 1 from pg_temp.fd_import_rows x where not exists (select 1 from pg_temp.fd_import_map f where f.sr_no = x.sr_no)) then
    raise exception 'IMPORT: a deposit names an SR NO that is not in the map.';
  end if;
  if exists (select 1 from pg_temp.fd_import_rows where kind not in ('monthly', 'yearly') or amount is null or amount <= 0
               or month <> date_trunc('month', month)::date or month < v_joined) then
    raise exception 'IMPORT: a deposit row is invalid (kind, amount or month).';
  end if;
  if exists (select 1 from pg_temp.fd_import_rows group by sr_no, month, kind having count(*) > 1) then
    raise exception 'IMPORT: the same member, month and kind appears twice.';
  end if;

  ---- the batch
  insert into public.import_batches (label, source_note, created_at)
  values (coalesce(p ->> 'label', 'historical import'), p ->> 'source_note', clock_timestamp())
  returning id into v_batch;

  ---- (a) deposits up to and including the purchase month, through the normal deposit triggers
  insert into public.deposits (member_id, period_month, kind, amount, method, status, note, is_historical, import_batch_id)
  select f.member_id, x.month, x.kind::public.deposit_kind, x.amount, 'other', 'approved',
         x.note, true, v_batch
    from pg_temp.fd_import_rows x join pg_temp.fd_import_map f on f.sr_no = x.sr_no
   where x.month <= date_trunc('month', v_pdate)::date
   order by x.month, x.kind, x.sr_no;
  get diagnostics v_c = row_count;
  rep := rep || format('plan|(a) deposits before the purchase|%s rows', v_c);

  ---- (b) the land purchase: same code as approve_investment; cost items join the cost basis
  perform public.check_money_date(v_pdate, 'purchase date');
  select coalesce(sum((i ->> 'amount')::numeric), 0) into v_cap from jsonb_array_elements(p #> '{purchase,items}') i;
  v_inv := public.purchase_core(p #>> '{purchase,title}', coalesce(p #>> '{purchase,kind}', 'land'),
                                p #>> '{purchase,description}', v_pdate, v_cost, v_cap, null, null, v_batch);
  perform set_config('fd.posting', 'on', true);
  insert into public.money_requests (kind, status, title, investment_kind, amount, event_date, description,
                                     proposed_by, proposed_at, decided_by, decided_at, result_id, import_batch_id)
  values ('purchase', 'approved', p #>> '{purchase,title}', coalesce(p #>> '{purchase,kind}', 'land'), v_cost, v_pdate,
          p #>> '{purchase,description}', null, clock_timestamp(), null, clock_timestamp(), v_inv, v_batch)
  returning id into v_req;
  insert into public.money_requests (kind, status, title, amount, event_date, purchase_request_id,
                                     proposed_by, proposed_at, decided_by, decided_at, import_batch_id)
  select 'investment_cost', 'approved', i ->> 'title', (i ->> 'amount')::numeric, v_pdate, v_req,
         null, clock_timestamp(), null, clock_timestamp(), v_batch
    from jsonb_array_elements(p #> '{purchase,items}') i;
  perform set_config('fd.posting', 'off', true);
  select count(*), sum(contribution_delta) into v_c, v_n from public.investment_participation where investment_id = v_inv;
  rep := rep || format('plan|(b) land purchase %s: cost %s + costs %s = basis %s|%s participants, contributions sum %s',
                       v_pdate, v_cost, v_cap, v_cost + v_cap, v_c, v_n);

  ---- (c) deposits after the purchase month
  insert into public.deposits (member_id, period_month, kind, amount, method, status, note, is_historical, import_batch_id)
  select f.member_id, x.month, x.kind::public.deposit_kind, x.amount, 'other', 'approved',
         x.note, true, v_batch
    from pg_temp.fd_import_rows x join pg_temp.fd_import_map f on f.sr_no = x.sr_no
   where x.month > date_trunc('month', v_pdate)::date
   order by x.month, x.kind, x.sr_no;
  get diagnostics v_c = row_count;
  rep := rep || format('plan|(c) deposits after the purchase|%s rows', v_c);

  ---- marker
  insert into public.system_markers (key, value)
  values ('import_done', jsonb_build_object('batch', v_batch, 'label', p ->> 'label', 'at', clock_timestamp()));

  ---- report: per member, per month, purchase, totals
  for r in select f.sr_no, b.capital, b.equity, b.free,
                  (select count(*) from public.deposits d where d.member_id = f.member_id and d.import_batch_id = v_batch) as n_dep,
                  (select contribution_delta from public.investment_participation ip where ip.investment_id = v_inv and ip.member_id = f.member_id) as contrib
             from pg_temp.fd_import_map f join public.member_balances_internal() b on b.member_id = f.member_id
            order by f.sr_no loop
    rep := rep || format('member|SR %s|capital %s, %s deposits, land contribution %s, free %s', r.sr_no, r.capital, r.n_dep, r.contrib, r.free);
  end loop;
  for r in select d.period_month, d.kind, count(*) as n, sum(d.amount) as total
             from public.deposits d where d.import_batch_id = v_batch
            group by d.period_month, d.kind order by d.period_month, d.kind loop
    rep := rep || format('month|%s %s|%s rows, total %s', to_char(r.period_month, 'YYYY-MM'), r.kind, r.n, r.total);
  end loop;

  ---- reconciliation: fail loudly on any mismatch
  select coalesce(sum(amount), 0) into v_n from public.deposits where import_batch_id = v_batch;
  if v_n <> (e ->> 'total_deposits')::numeric then
    raise exception 'RECONCILIATION FAILED: total deposits % <> expected %', v_n, e ->> 'total_deposits';
  end if;
  rep := rep || format('check|total deposits|%s = expected %s', v_n, e ->> 'total_deposits');
  select invested, cash_available into v_n, v_m from public.fund_totals_internal();
  if v_n <> (e ->> 'invested')::numeric then
    raise exception 'RECONCILIATION FAILED: invested % <> expected %', v_n, e ->> 'invested';
  end if;
  if v_m <> (e ->> 'cash')::numeric then
    raise exception 'RECONCILIATION FAILED: cash % <> expected %', v_m, e ->> 'cash';
  end if;
  rep := rep || format('check|invested / cash|%s / %s = expected %s / %s', v_n, v_m, e ->> 'invested', e ->> 'cash');
  select count(*) into v_c from pg_temp.fd_import_map f join public.member_balances_internal() b on b.member_id = f.member_id
   where b.capital <> (e ->> 'member_capital')::numeric;
  if v_c > 0 then
    raise exception 'RECONCILIATION FAILED: % member(s) do not have capital %', v_c, e ->> 'member_capital';
  end if;
  rep := rep || format('check|every member capital|%s', e ->> 'member_capital');
  select count(*), coalesce(sum(contribution_delta), 0) into v_c, v_n from public.investment_participation where investment_id = v_inv;
  if v_c <> (e ->> 'participants')::int or v_n <> (e ->> 'invested')::numeric then
    raise exception 'RECONCILIATION FAILED: % participation rows summing to % (expected % rows, %)', v_c, v_n, e ->> 'participants', e ->> 'invested';
  end if;
  rep := rep || format('check|participation|%s rows, contributions sum %s', v_c, v_n);

  perform public.check_invariants(true);                     -- raises if any rule fails
  select count(*) into v_c from public.check_invariants(false);
  rep := rep || format('check|check_invariants|all %s rules pass', v_c);
  return rep;
end $$;

create or replace function public.import_history(p_payload jsonb, p_dry_run boolean default true)
returns table (section text, item text, value text)
language plpgsql security definer set search_path = '' as $$
declare rep text[];
begin
  if auth.uid() is not null or coalesce(current_setting('request.jwt.claims', true), '') <> ''
     or session_user not in ('postgres', 'supabase_admin') then
    raise exception 'The historical import can only be run from the Supabase SQL Editor.';
  end if;
  perform public.take_fund_lock();
  if exists (select 1 from public.system_markers where key in ('import_done', 'go_live'))
     or exists (select 1 from public.import_batches) then
    raise exception 'The historical import was already done (or the site is live). It can never run again.';
  end if;

  if p_dry_run then
    begin
      rep := public.import_apply(p_payload);
      raise exception using errcode = 'P0097', message = 'dry run: everything is rolled back';
    exception when sqlstate 'P0097' then
      null;                                   -- all writes of the dry run are undone here
    end;
    return query select 'DRY RUN ' || split_part(x, '|', 1), split_part(x, '|', 2), split_part(x, '|', 3)
                   from unnest(rep) x;
    return query select 'DRY RUN'::text, 'nothing was saved'::text, 'run run_import_real.sql (p_dry_run => false) to import'::text;
  else
    rep := public.import_apply(p_payload);
    return query select split_part(x, '|', 1), split_part(x, '|', 2), split_part(x, '|', 3) from unnest(rep) x;
    return query select 'DONE'::text, 'historical import saved'::text, 'marker import_done is set'::text;
  end if;
end $$;

-- ---------- 6) check_invariants: rule 18 knows the import batch; new rule 27 ----------
create or replace function public.check_invariants(raise_on_fail boolean default true)
returns table (rule text, ok boolean, detail text)
language plpgsql security definer set search_path = '' as $$
declare
  t   record;
  n   numeric;
  m   numeric;
  k   numeric;
  bad text := '';
begin
  if coalesce(current_setting('request.jwt.claims', true), '') <> '' and not public.is_admin() then
    raise exception 'Only admins can run check_invariants().';
  end if;
  perform pg_advisory_xact_lock_shared(public.fund_lock_key());
  select * into t from public.fund_totals_internal();

  -- 1) cash rebuilt from the source tables = cash from the ledger
  select coalesce(sum(amount), 0) into n from public.deposits where status = 'approved';
  n := n + (select coalesce(sum(amount), 0) from public.investment_income)
         + (select coalesce(sum(sale_amount), 0) from public.investments where status = 'sold')
         - (select coalesce(sum(cost + capitalized_costs), 0) from public.investments)
         - (select coalesce(sum(amount), 0) from public.expenses where status = 'approved');
  rule := 'cash: independent rebuild = ledger'; ok := n = t.cash_available;
  detail := format('rebuilt %s, ledger %s', n, t.cash_available); return next;

  -- 2) cash >= 0
  rule := 'cash >= 0'; ok := t.cash_available >= 0;
  detail := format('cash %s', t.cash_available); return next;

  -- 3) total fund = sum(equity) + reserve; balances agree with the raw ledger
  select coalesce(sum(equity), 0) into n from public.member_balances_internal();
  select coalesce(sum(amount), 0) into m from public.member_ledger;
  select coalesce(sum(amount), 0) into k from public.fund_reserve;
  rule := 'total_fund = sum(equity) + reserve'; ok := t.total_fund = n + k and n = m;
  detail := format('total_fund %s, equity %s (raw ledger %s), reserve %s', t.total_fund, n, m, k); return next;

  -- 4) the formula on the home page holds exactly (source tables)
  n := t.capital
       + (select coalesce(sum(amount), 0) from public.fund_reserve where kind = 'late_fee')
       + (select coalesce(sum(amount), 0) from public.investment_income)
       + (select coalesce(sum(sale_amount - (cost + capitalized_costs)), 0) from public.investments where status = 'sold')
       - (select coalesce(sum(amount), 0) from public.expenses where status = 'approved')
       + (select coalesce(sum(amount), 0) from public.fund_reserve where kind not in ('late_fee', 'remainder'));
  rule := 'formula: capital + late fees + income + profit - expenses (+ other reserve)'; ok := n = t.total_fund;
  detail := format('formula %s, total_fund %s', n, t.total_fund); return next;

  -- 5) sum(committed) = invested
  select coalesce(sum(p.contribution_delta), 0) into n
    from public.investment_participation p join public.investments i on i.id = p.investment_id
   where i.status = 'held';
  rule := 'sum(committed) = invested'; ok := n = t.invested;
  detail := format('committed %s, invested %s', n, t.invested); return next;

  -- 6) every investment: contributions (all reasons) = cost basis
  select count(*) into n from public.investments i
   where i.cost + i.capitalized_costs <> coalesce((select sum(p.contribution_delta) from public.investment_participation p
                                                    where p.investment_id = i.id), 0);
  rule := 'each investment: contributions = cost basis'; ok := n = 0;
  detail := format('%s investment(s) out of balance', n); return next;

  -- 7) purchase eligibility: contributions > 0 and never more than the free money at purchase
  select count(*) into n from public.investment_participation
   where reason = 'purchase' and (contribution_delta <= 0 or (free_at_purchase is not null and contribution_delta > free_at_purchase));
  rule := 'purchase: 0 < contribution <= free money then'; ok := n = 0;
  detail := format('%s participation row(s) break it', n); return next;

  -- 8) every approved non-late-fee deposit is posted exactly once
  select count(*) into n from public.deposits d
   where d.status = 'approved' and d.kind <> 'late_fee'
     and (select count(*) from public.member_ledger l
           where l.source_type = 'deposit' and l.source_id = d.id
             and l.member_id = d.member_id and l.amount = d.amount and l.kind = 'capital_deposit') <> 1;
  select count(*) into m from public.member_ledger l
   where l.source_type = 'deposit'
     and not exists (select 1 from public.deposits d
                      where d.id = l.source_id and d.status = 'approved' and d.kind <> 'late_fee');
  rule := 'ledger matches approved deposits'; ok := n = 0 and m = 0;
  detail := format('%s deposit(s) not posted correctly, %s ledger row(s) without an approved deposit', n, m); return next;

  -- 9) every approved late fee is in the reserve exactly once
  select count(*) into n from public.deposits d
   where d.status = 'approved' and d.kind = 'late_fee'
     and (select count(*) from public.fund_reserve r
           where r.source_type = 'deposit' and r.source_id = d.id and r.amount = d.amount) <> 1;
  select count(*) into m from public.fund_reserve r
   where r.source_type = 'deposit'
     and not exists (select 1 from public.deposits d
                      where d.id = r.source_id and d.status = 'approved' and d.kind = 'late_fee');
  rule := 'reserve matches approved late fees'; ok := n = 0 and m = 0;
  detail := format('%s late fee(s) not posted correctly, %s reserve row(s) without one', n, m); return next;

  -- 10) capital_deposit rows come from deposits
  select count(*) into n from public.member_ledger where kind = 'capital_deposit' and source_type <> 'deposit';
  rule := 'capital_deposit rows come from deposits'; ok := n = 0;
  detail := format('%s row(s) from elsewhere', n); return next;

  -- 11) non-deposit postings come from allocations (transfers and payouts get their own rules in 6D)
  select count(*) into n from public.member_ledger
   where source_type not in ('deposit', 'transfer') and allocation_id is null;
  select count(*) into m from public.fund_reserve
   where source_type <> 'deposit' and kind <> 'payout' and allocation_id is null;
  rule := 'non-deposit postings come from allocations'; ok := n = 0 and m = 0;
  detail := format('%s ledger row(s) and %s reserve row(s) without an allocation', n, m); return next;

  -- 12) no member has negative contributed capital
  select count(*) into n from public.member_balances_internal() where capital < 0;
  rule := 'no negative member capital'; ok := n = 0;
  detail := format('%s member(s) below zero', n); return next;

  -- 13) every allocation set adds up to its event_total
  select count(*) into n from (
    select 1 from public.allocations
     group by event_type, event_id, basis
    having count(distinct event_total) <> 1 or sum(amount) <> max(event_total)) x;
  rule := 'allocation sets sum to event_total'; ok := n = 0;
  detail := format('%s unbalanced set(s)', n); return next;

  -- 14) event_total equals the real event amount ('transfer' has no rule yet: flagged until 6D)
  select count(*) into n from (
    select distinct a.event_type, a.event_id, a.event_total from public.allocations a) e
   where case e.event_type
           when 'sale'    then e.event_total is distinct from
                                (select i.sale_amount - (i.cost + i.capitalized_costs) from public.investments i
                                  where i.id = e.event_id and i.status = 'sold')
           when 'expense' then e.event_total is distinct from
                                (select -x.amount from public.expenses x where x.id = e.event_id and x.status = 'approved')
           when 'income'  then e.event_total is distinct from
                                (select ic.amount from public.investment_income ic where ic.id = e.event_id)
           else true
         end;
  rule := 'event_total = real event amount'; ok := n = 0;
  detail := format('%s event(s) do not match their source', n); return next;

  -- 15) capital-basis allocations posted exactly once; shares-basis / zero rows never
  select count(*) into n from public.allocations a
   where a.basis = 'capital' and a.member_id is not null and a.amount <> 0
     and (select count(*) from public.member_ledger l
           where l.allocation_id = a.id and l.member_id = a.member_id and l.amount = a.amount) <> 1;
  select count(*) into m from public.allocations a
   where a.basis = 'capital' and a.member_id is null and a.amount <> 0
     and (select count(*) from public.fund_reserve r
           where r.allocation_id = a.id and r.kind = 'remainder' and r.amount = a.amount) <> 1;
  select count(*) into k from public.allocations a
   where (a.basis = 'shares' or a.amount = 0)
     and (exists (select 1 from public.member_ledger l where l.allocation_id = a.id)
          or exists (select 1 from public.fund_reserve r where r.allocation_id = a.id));
  rule := 'allocations posted correctly'; ok := n = 0 and m = 0 and k = 0;
  detail := format('%s member allocation(s) and %s remainder(s) not posted once, %s display-only row(s) posted', n, m, k); return next;

  -- 16) posted rows match their allocation (member, amount, event, kind)
  select count(*) into n from public.member_ledger l join public.allocations a on a.id = l.allocation_id
   where a.basis <> 'capital' or a.member_id is distinct from l.member_id or a.amount <> l.amount
      or l.source_id <> a.event_id
      or not (   (a.event_type = 'sale'    and l.kind in ('profit', 'loss')                 and l.source_type = 'investment')
              or (a.event_type = 'income'  and l.kind in ('income', 'income_reversal')      and l.source_type = 'income')
              or (a.event_type = 'expense' and l.kind in ('expense', 'expense_reversal')    and l.source_type = 'expense'));
  select count(*) into m from public.fund_reserve r join public.allocations a on a.id = r.allocation_id
   where a.basis <> 'capital' or a.member_id is not null or a.amount <> r.amount or r.source_id <> a.event_id;
  rule := 'posted rows match their allocation'; ok := n = 0 and m = 0;
  detail := format('%s ledger row(s), %s reserve row(s) do not match', n, m); return next;

  -- 17) every approved event HAS its allocation set
  select count(*) into n from public.investments i
   where i.status = 'sold'
     and (not exists (select 1 from public.allocations a where a.event_type = 'sale' and a.event_id = i.id and a.basis = 'capital')
          or ((select coalesce(sum(s.shares), 0) from public.investment_sharers(i.id) s) > 0
              and not exists (select 1 from public.allocations a where a.event_type = 'sale' and a.event_id = i.id and a.basis = 'shares')));
  select count(*) into m from public.expenses x
   where x.status = 'approved'
     and not exists (select 1 from public.allocations a where a.event_type = 'expense' and a.event_id = x.id and a.basis = 'capital');
  select count(*) into k from public.investment_income ic
   where not exists (select 1 from public.allocations a where a.event_type = 'income' and a.event_id = ic.id and a.basis = 'capital');
  rule := 'every event has its allocation'; ok := n = 0 and m = 0 and k = 0;
  detail := format('%s sale(s), %s expense(s), %s income row(s) without allocation', n, m, k); return next;

  -- 18) two people per decision; approved requests have a decider
  select (select count(*) from public.investments where import_batch_id is null and (approved_by is null or approved_by = created_by))
       + (select count(*) from public.investments where status = 'sold' and (sale_approved_by is null or sale_approved_by = sale_proposed_by))
       + (select count(*) from public.expenses where approved_by is null or approved_by = created_by)
       + (select count(*) from public.investment_income where approved_by is null or approved_by = created_by)
       + (select count(*) from public.money_requests where import_batch_id is null and status = 'approved' and (decided_by is null or decided_by = proposed_by))
       + (select count(*) from public.money_requests where import_batch_id is null and status <> 'pending' and decided_by is null)
    into n;
  rule := 'two people per decision (or the import batch)'; ok := n = 0;
  detail := format('%s one-person or undecided decision(s)', n); return next;

  -- 19) nobody took part in a purchase from before they joined
  select count(*) into n from public.investment_participation p
    join public.investments i on i.id = p.investment_id
    join public.profiles pr on pr.id = p.member_id
   where p.reason = 'purchase' and (pr.joined_on is null or pr.joined_on > i.purchase_date);
  rule := 'participants joined before the purchase'; ok := n = 0;
  detail := format('%s participation row(s) from later joiners', n); return next;

  -- 20) every split amount recomputes from its weight (rows since 010; mirrored reversal sets excluded)
  select count(*) into n from public.allocations a
   where a.member_id is not null and a.weight is not null
     and not exists (select 1 from public.investment_income ic where ic.id = a.event_id and ic.reverses_income_id is not null)
     and not exists (select 1 from public.expenses x where x.id = a.event_id and x.reverses_expense_id is not null)
     and a.amount <> sign(a.event_total)
                     * (div(abs(a.event_total) * 100 * a.weight, a.weight_sum)
                        + case when a.event_total < 0 and mod(abs(a.event_total) * 100 * a.weight, a.weight_sum) > 0 then 1 else 0 end) / 100;
  select count(*) into m from public.allocations a where a.member_id is not null and a.weight is null;
  rule := 'split amounts recompute from weights'; ok := n = 0;
  detail := format('%s wrong amount(s); %s legacy row(s) from before 010 not checked', n, m); return next;

  -- 21) the reserve leftover of a normal split is never negative (rows since 010)
  select count(*) into n from public.allocations a
   where a.member_id is null and a.weight_sum is not null and a.amount < 0
     and not exists (select 1 from public.investment_income ic where ic.id = a.event_id and ic.reverses_income_id is not null)
     and not exists (select 1 from public.expenses x where x.id = a.event_id and x.reverses_expense_id is not null);
  rule := 'reserve leftover >= 0'; ok := n = 0;
  detail := format('%s negative leftover(s)', n); return next;

  -- 22) a reversal is the exact mirror of its original (same rows, opposite amounts)
  select count(*) into n from (
    select o.event_id from (
      select ic.id as new_id, ic.reverses_income_id as orig_id, 'income' as et from public.investment_income ic where ic.reverses_income_id is not null
      union all
      select x.id, x.reverses_expense_id, 'expense' from public.expenses x where x.reverses_expense_id is not null) r
    cross join lateral (
      select coalesce(a.event_id, b.event_id) as event_id
        from (select * from public.allocations where event_type = r.et and event_id = r.orig_id) a
        full join (select * from public.allocations where event_type = r.et and event_id = r.new_id) b
          on a.basis = b.basis and a.member_id is not distinct from b.member_id
       where a.id is null or b.id is null or b.amount <> -a.amount) o) x;
  rule := 'reversals mirror the original exactly'; ok := n = 0;
  detail := format('%s row(s) differ', n); return next;

  -- 23) results of a plot (sale, income, plot expenses) only reach that plot's participants
  select count(*) into n from public.allocations a
   where a.member_id is not null
     and coalesce(
           case a.event_type
             when 'sale'    then a.event_id
             when 'income'  then (select ic.investment_id from public.investment_income ic where ic.id = a.event_id)
             when 'expense' then (select x.investment_id from public.expenses x where x.id = a.event_id)
           end, null) is not null
     and not exists (select 1 from public.investment_sharers(
                       case a.event_type
                         when 'sale'    then a.event_id
                         when 'income'  then (select ic.investment_id from public.investment_income ic where ic.id = a.event_id)
                         else (select x.investment_id from public.expenses x where x.id = a.event_id)
                       end) s where s.member_id = a.member_id);
  rule := 'plot results only reach its participants'; ok := n = 0;
  detail := format('%s allocation row(s) to outsiders', n); return next;

  -- 24) every investment / expense / income row has exactly one matching approved request
  select (select count(*) from public.investments i
           where (select count(*) from public.money_requests q
                   where q.status = 'approved' and q.kind = 'purchase' and q.result_id = i.id
                     and q.amount = i.cost and q.event_date = i.purchase_date) <> 1)
       + (select count(*) from public.investments i
           where i.status = 'sold'
             and (select count(*) from public.money_requests q
                   where q.status = 'approved' and q.kind = 'sale' and q.result_id = i.id and q.investment_id = i.id
                     and q.amount = i.sale_amount and q.event_date = i.sale_date) <> 1)
       + (select count(*) from public.expenses x
           where (select count(*) from public.money_requests q
                   where q.status = 'approved' and q.result_id = x.id
                     and q.event_date = x.spent_on and q.investment_id is not distinct from x.investment_id
                     and ((q.kind in ('expense', 'investment_cost') and x.reverses_expense_id is null and q.amount = x.amount)
                          or (q.kind = 'expense_reversal' and q.reverses_expense_id = x.reverses_expense_id and q.amount = -x.amount))) <> 1)
       + (select count(*) from public.investment_income ic
           where (select count(*) from public.money_requests q
                   where q.status = 'approved' and q.kind = 'income' and q.result_id = ic.id
                     and q.amount = ic.amount and q.event_date = ic.received_on and q.investment_id = ic.investment_id) <> 1)
    into n;
  select count(*) into m from public.money_requests q
   where q.status = 'approved'
     and case q.kind
           when 'purchase'         then not exists (select 1 from public.investments i where i.id = q.result_id)
           when 'sale'             then not exists (select 1 from public.investments i where i.id = q.result_id and i.status = 'sold')
           when 'income'           then not exists (select 1 from public.investment_income ic where ic.id = q.result_id)
           when 'expense'          then not exists (select 1 from public.expenses x where x.id = q.result_id)
           when 'expense_reversal' then not exists (select 1 from public.expenses x where x.id = q.result_id)
           when 'investment_cost'  then q.purchase_request_id is null
                                         and not exists (select 1 from public.expenses x where x.id = q.result_id)
           else true
         end;
  rule := 'each money row has exactly one approved request'; ok := n = 0 and m = 0;
  detail := format('%s row(s) without exactly one matching request, %s approved request(s) without their row', n, m); return next;

  -- 25) capitalized costs = approved cost items of that purchase; none left on a rejected purchase
  select count(*) into n from public.investments i
    join public.money_requests q on q.kind = 'purchase' and q.status = 'approved' and q.result_id = i.id
   where i.capitalized_costs <> (select coalesce(sum(c.amount), 0) from public.money_requests c
                                  where c.kind = 'investment_cost' and c.status = 'approved' and c.purchase_request_id = q.id);
  select count(*) into m from public.money_requests c join public.money_requests q on q.id = c.purchase_request_id
   where c.kind = 'investment_cost' and c.status = 'approved' and q.status = 'rejected';
  rule := 'capitalized costs = approved cost items'; ok := n = 0 and m = 0;
  detail := format('%s investment(s) differ, %s approved cost item(s) on a rejected purchase', n, m); return next;

  -- 26) money dates inside the samiti period
  select count(*) into n from (
    select purchase_date as d from public.investments
    union all select sale_date from public.investments where sale_date is not null
    union all select spent_on from public.expenses where reverses_expense_id is null
    union all select received_on from public.investment_income) x
   where x.d < coalesce((select (value #>> '{}')::date from public.app_settings where key = 'samiti_start'), date '2020-01-01');
  rule := 'money dates after the samiti start'; ok := n = 0;
  detail := format('%s date(s) before the start', n); return next;

  -- 27) imported rows: exactly one finished import, its marker set, deposits historical and approved
  select (select count(*) from public.import_batches) into k;
  select (select count(*) from public.deposits d where d.import_batch_id is not null and (not d.is_historical or d.status <> 'approved'))
       + (select count(*) from (
            select d.import_batch_id as b from public.deposits d where d.import_batch_id is not null
            union all select i.import_batch_id from public.investments i where i.import_batch_id is not null
            union all select q.import_batch_id from public.money_requests q where q.import_batch_id is not null) x
           where not exists (select 1 from public.system_markers s where s.key = 'import_done' and (s.value ->> 'batch')::uuid = x.b))
       + (select count(*) from public.money_requests q where q.import_batch_id is not null and (q.status <> 'approved' or q.kind not in ('purchase', 'investment_cost')))
    into n;
  rule := 'imported rows belong to the one finished import'; ok := n = 0 and k <= 1;
  detail := format('%s bad imported row(s), %s import batch(es)', n, k); return next;

  if raise_on_fail then
    for t in select * from public.check_invariants(false) c where not c.ok loop
      bad := bad || t.rule || ' [' || t.detail || ']; ';
    end loop;
    if bad <> '' then
      raise exception 'INVARIANT FAILED: %', bad;
    end if;
  end if;
end $$;

-- ---------- 5) Permissions: the import is for the SQL Editor only ----------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('purchase_core', 'import_apply', 'import_history', 'approve_investment', 'check_invariants')
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', f.sig);
  end loop;
end $$;
grant execute on function public.approve_investment(uuid, numeric) to authenticated;
grant execute on function public.check_invariants(boolean)        to authenticated;

do $$
declare names text;
begin
  select string_agg(p.proname, ', ') into names
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('service_role', p.oid, 'execute')
          or (p.proname in ('purchase_core', 'import_apply', 'import_history') and has_function_privilege('authenticated', p.oid, 'execute')));
  if names is not null then
    raise exception 'API roles can still execute: %', names;
  end if;
end $$;

select * from public.check_invariants(true);
