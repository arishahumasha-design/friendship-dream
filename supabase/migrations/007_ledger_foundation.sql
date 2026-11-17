-- =====================================================================
-- Money model v2, sub-phase 6A: ledger foundation  (see docs/MONEY_MODEL.md)
-- Run ONCE in Supabase Dashboard > SQL Editor (paste whole file > Run), after 006.
-- Safe to run again (idempotent). Does not loosen any existing rule.
--
-- What it adds
--   member_ledger            per-member money lines (single source of truth for balances)
--   fund_reserve             samiti reserve (late fees, rounding remainders, later payouts)
--   allocations              how an event amount was split (written at event time)
--   investment_participation who is in which investment and for how much (used from 6B)
--   deposits.is_back_month   back months of a new member (exempt from late/suspension rules)
--   every approved deposit is posted to the ledger automatically (also backfilled)
--   fund_summary() / member_totals() now read from the ledger
--   check_invariants()       fails loudly when the books do not add up
--
-- Sign convention: every amount is its signed effect on the member's equity (or on the reserve).
--   capital_deposit +/-, capital_transfer_in +, capital_transfer_out -, profit +, loss -,
--   income +, expense -, result_transfer_in +, result_transfer_out -.
-- =====================================================================

-- ---------- 0) One fund-wide lock for every money write ----------
create or replace function public.fund_lock_key() returns bigint
language sql immutable set search_path = '' as $$ select 7319001::bigint $$;

-- ---------- 1) Tables ----------
create table if not exists public.member_ledger (
  id           bigint generated always as identity primary key,
  member_id    uuid not null references public.profiles (id),
  kind         text not null check (kind in (
                 'capital_deposit', 'capital_transfer_in', 'capital_transfer_out',
                 'profit', 'loss', 'income', 'expense',
                 'result_transfer_in', 'result_transfer_out')),
  amount       numeric(14, 2) not null check (amount <> 0),
  source_type  text not null check (source_type in ('deposit', 'investment', 'expense', 'income', 'transfer', 'adjustment')),
  source_id    uuid not null,
  created_at   timestamptz not null default now(),
  -- direction must match the kind
  check (kind not in ('capital_transfer_in', 'profit', 'income', 'result_transfer_in') or amount > 0),
  check (kind not in ('capital_transfer_out', 'loss', 'expense', 'result_transfer_out') or amount < 0)
);
create index if not exists member_ledger_member_idx on public.member_ledger (member_id, kind);
-- a deposit is posted at most once
create unique index if not exists member_ledger_deposit_once
  on public.member_ledger (source_id) where source_type = 'deposit';

create table if not exists public.fund_reserve (
  id           bigint generated always as identity primary key,
  kind         text not null check (kind in ('late_fee', 'remainder', 'payout', 'other')),
  amount       numeric(14, 2) not null check (amount <> 0),
  source_type  text not null check (source_type in ('deposit', 'allocation', 'investment', 'expense', 'adjustment')),
  source_id    uuid,
  created_at   timestamptz not null default now()
);
create unique index if not exists fund_reserve_deposit_once
  on public.fund_reserve (source_id) where source_type = 'deposit';

create table if not exists public.allocations (
  id           bigint generated always as identity primary key,
  event_type   text not null check (event_type in ('sale', 'expense', 'income', 'loss', 'transfer')),
  event_id     uuid not null,
  basis        text not null check (basis in ('capital', 'shares')),
  member_id    uuid references public.profiles (id),        -- null = rounding remainder (goes to the reserve)
  amount       numeric(14, 2) not null,
  event_total  numeric(14, 2) not null,                      -- the amount that was split; every row of a set repeats it
  created_at   timestamptz not null default now()
);
create index if not exists allocations_event_idx on public.allocations (event_type, event_id, basis);

create table if not exists public.investment_participation (
  id                  bigint generated always as identity primary key,
  investment_id       uuid not null references public.investments (id),
  member_id           uuid not null references public.profiles (id),
  contribution_delta  numeric(14, 2) not null check (contribution_delta <> 0),
  capital_at_purchase numeric(14, 2),
  shares_at_purchase  integer,
  reason              text not null check (reason in ('purchase', 'transfer')),
  transfer_id         uuid,
  created_at          timestamptz not null default now()
);
create index if not exists investment_participation_idx on public.investment_participation (investment_id, member_id);

-- ---------- 2) Append-only for EVERY role (also the SQL Editor) ----------
create or replace function public.block_ledger_changes() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'Table % is append-only: rows can never be changed or deleted. Add a new reversing row instead.', tg_table_name;
end $$;

do $$
declare tb text;
begin
  foreach tb in array array['member_ledger', 'fund_reserve', 'allocations', 'investment_participation'] loop
    execute format('drop trigger if exists %I on public.%I', tb || '_no_update_delete', tb);
    execute format('create trigger %I before update or delete on public.%I for each row execute function public.block_ledger_changes()',
                   tb || '_no_update_delete', tb);
    execute format('drop trigger if exists %I on public.%I', tb || '_no_truncate', tb);
    execute format('create trigger %I before truncate on public.%I for each statement execute function public.block_ledger_changes()',
                   tb || '_no_truncate', tb);
  end loop;
end $$;

-- ---------- 3) Row Level Security: read only; rows are written only by the database functions below ----------
alter table public.member_ledger            enable row level security;
alter table public.fund_reserve             enable row level security;
alter table public.allocations              enable row level security;
alter table public.investment_participation enable row level security;

drop policy if exists member_ledger_select on public.member_ledger;
create policy member_ledger_select on public.member_ledger for select to authenticated
  using (member_id = auth.uid() or public.is_admin());
drop policy if exists fund_reserve_select on public.fund_reserve;
create policy fund_reserve_select on public.fund_reserve for select to authenticated
  using (public.is_admin());
drop policy if exists allocations_select on public.allocations;
create policy allocations_select on public.allocations for select to authenticated
  using (member_id = auth.uid() or public.is_admin());
drop policy if exists investment_participation_select on public.investment_participation;
create policy investment_participation_select on public.investment_participation for select to authenticated
  using (member_id = auth.uid() or public.is_admin());

revoke all on public.member_ledger, public.fund_reserve, public.allocations, public.investment_participation
  from public, anon, authenticated;
grant select on public.member_ledger, public.fund_reserve, public.allocations, public.investment_participation
  to authenticated;

-- Until 6B moves investments / expenses / income onto the ledger (through locked RPCs), nobody may
-- write those tables from the website: a row there would change "invested" without the ledger knowing.
revoke insert, update, delete on public.investments, public.investment_income, public.expenses from authenticated;

-- ---------- 4) Back months of a new member ----------
alter table public.deposits add column if not exists is_back_month boolean not null default false;
comment on column public.deposits.is_back_month is
  'Deposit for a month before the member joined (R1). Exempt from late fees and late/suspension rules. Set by the database.';

create or replace function public.deposits_set_back_month() returns trigger
language plpgsql security definer set search_path = '' as $$
declare joined date;
begin
  select joined_on into joined from public.profiles where id = new.member_id;
  new.is_back_month := joined is not null and new.period_month < date_trunc('month', joined)::date;
  return new;
end $$;

drop trigger if exists deposits_set_back_month_trg on public.deposits;
create trigger deposits_set_back_month_trg              -- runs after deposits_guard_trg (alphabetical)
  before insert on public.deposits
  for each row execute function public.deposits_set_back_month();
-- (On UPDATE, deposits_guard copies the whole old row, so the flag can never be changed later.)
-- Rows that already exist keep is_back_month = false: deposits_guard freezes them, and they are
-- all test data. The flag only matters for late/suspension rules, which are not built yet.

-- ---------- 5) Totals (internal, no permission check: used by RPCs and check_invariants) ----------
create or replace function public.fund_totals_internal()
returns table (capital numeric, late_fees numeric, reserve numeric, investment_income numeric,
               realized_profit numeric, expenses numeric, member_equity numeric,
               total_fund numeric, invested numeric, cash_available numeric)
language sql stable security definer set search_path = '' as $$
  with
  l as (select
          coalesce(sum(amount) filter (where kind in ('capital_deposit', 'capital_transfer_in', 'capital_transfer_out')), 0) as cap,
          coalesce(sum(amount) filter (where kind = 'income'), 0)                   as inc,
          coalesce(sum(amount) filter (where kind in ('profit', 'loss')), 0)        as prof,
          coalesce(-sum(amount) filter (where kind = 'expense'), 0)                 as exp,
          coalesce(sum(amount), 0)                                                  as eq
        from public.member_ledger),
  r as (select coalesce(sum(amount), 0) as total,
               coalesce(sum(amount) filter (where kind = 'late_fee'), 0) as lf
        from public.fund_reserve),
  i as (select coalesce(sum(cost), 0) as inv from public.investments where status = 'held')
  select l.cap, r.lf, r.total, l.inc, l.prof, l.exp, l.eq,
         l.eq + r.total, i.inv, l.eq + r.total - i.inv
  from l, r, i;
$$;
revoke all on function public.fund_totals_internal() from public, anon, authenticated;

create or replace function public.assert_cash_nonnegative() returns void
language plpgsql security definer set search_path = '' as $$
declare cash numeric;
begin
  select cash_available into cash from public.fund_totals_internal();
  if cash < 0 then
    raise exception 'Cash in hand cannot go below zero (it would be %).', cash;
  end if;
end $$;
revoke all on function public.assert_cash_nonnegative() from public, anon, authenticated;

-- ---------- 6) Post every approved deposit (approve, manual entry, correction) ----------
create or replace function public.post_deposit_to_ledger() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status <> 'approved' or (tg_op = 'UPDATE' and old.status = 'approved') then
    return null;
  end if;
  perform pg_advisory_xact_lock(public.fund_lock_key());

  if new.kind = 'late_fee' then
    insert into public.fund_reserve (kind, amount, source_type, source_id)
    values ('late_fee', new.amount, 'deposit', new.id);
  else
    insert into public.member_ledger (member_id, kind, amount, source_type, source_id)
    values (new.member_id, 'capital_deposit', new.amount, 'deposit', new.id);
  end if;

  perform public.assert_cash_nonnegative();
  return null;
end $$;
revoke all on function public.post_deposit_to_ledger() from public, anon, authenticated;

drop trigger if exists deposits_post_ledger_trg on public.deposits;
create trigger deposits_post_ledger_trg
  after insert or update of status on public.deposits
  for each row execute function public.post_deposit_to_ledger();

-- Cash may not go below zero because of an investment either (also blocks the SQL Editor path).
create or replace function public.investments_cash_check() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(public.fund_lock_key());
  perform public.assert_cash_nonnegative();
  return null;
end $$;
revoke all on function public.investments_cash_check() from public, anon, authenticated;
drop trigger if exists investments_cash_check_trg on public.investments;
create trigger investments_cash_check_trg
  after insert or update on public.investments
  for each row execute function public.investments_cash_check();

-- ---------- 7) Backfill: post every approved deposit that is not posted yet (approval time kept) ----------
do $$
begin
  perform pg_advisory_xact_lock(public.fund_lock_key());

  insert into public.member_ledger (member_id, kind, amount, source_type, source_id, created_at)
  select d.member_id, 'capital_deposit', d.amount, 'deposit', d.id, coalesce(d.reviewed_at, d.submitted_at)
    from public.deposits d
   where d.status = 'approved' and d.kind <> 'late_fee'
     and not exists (select 1 from public.member_ledger l where l.source_type = 'deposit' and l.source_id = d.id);

  insert into public.fund_reserve (kind, amount, source_type, source_id, created_at)
  select 'late_fee', d.amount, 'deposit', d.id, coalesce(d.reviewed_at, d.submitted_at)
    from public.deposits d
   where d.status = 'approved' and d.kind = 'late_fee'
     and not exists (select 1 from public.fund_reserve r where r.source_type = 'deposit' and r.source_id = d.id);
end $$;

-- ---------- 8) Dashboard RPCs now read from the ledger (same columns as before + reserve) ----------
drop function if exists public.fund_summary();
create function public.fund_summary()
returns table (capital numeric, late_fees numeric, investment_income numeric, realized_profit numeric,
               expenses numeric, total_fund numeric, invested numeric, cash_available numeric,
               member_count integer, monthly_amount numeric, reserve numeric)
language sql stable security definer set search_path = '' as $$
  select t.capital, t.late_fees, t.investment_income, t.realized_profit, t.expenses,
         t.total_fund, t.invested, t.cash_available,
         (select count(*)::int from public.profiles where status = 'active'),
         coalesce((select (value #>> '{}')::numeric from public.app_settings where key = 'monthly_amount'), 3000),
         t.reserve
  from public.fund_totals_internal() t
  where public.is_active_member();
$$;
grant execute on function public.fund_summary() to authenticated;

create or replace function public.member_totals()
returns table (member_id uuid, member_no integer, full_name text, photo_path text,
               status public.member_status, capital numeric, shares integer, paid_this_month boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  vis        boolean;
  share_val  numeric;
  month_amt  numeric;
  mstart     date := date_trunc('month', now() at time zone 'Asia/Dhaka')::date;
begin
  if not public.is_active_member() then return; end if;
  select coalesce((select (value #>> '{}')::boolean from public.app_settings where key = 'members_can_see_others'), true) into vis;
  select coalesce((select (value #>> '{}')::numeric from public.app_settings where key = 'share_value'), 5000) into share_val;
  select coalesce((select (value #>> '{}')::numeric from public.app_settings where key = 'monthly_amount'), 3000) into month_amt;
  return query
    with cap as (
      select l.member_id as mid, sum(l.amount) as c
        from public.member_ledger l
       where l.kind in ('capital_deposit', 'capital_transfer_in', 'capital_transfer_out')
       group by l.member_id
    ),
    paid as (
      select d.member_id as mid, sum(d.amount) as s
        from public.deposits d
       where d.status = 'approved' and d.kind = 'monthly' and d.period_month = mstart
       group by d.member_id
    )
    select p.id, p.member_no, p.full_name, p.photo_path, p.status,
           coalesce(cap.c, 0),
           floor(coalesce(cap.c, 0) / share_val)::int,
           coalesce(paid.s, 0) >= month_amt
      from public.profiles p
      left join cap  on cap.mid  = p.id
      left join paid on paid.mid = p.id
     where p.status in ('active', 'suspended')
       and (vis or public.is_admin() or p.id = auth.uid())
     order by p.member_no;
end $$;
grant execute on function public.member_totals() to authenticated;

-- ---------- 9) check_invariants(): fails loudly ----------
create or replace function public.check_invariants(raise_on_fail boolean default true)
returns table (rule text, ok boolean, detail text)
language plpgsql security definer set search_path = '' as $$
declare
  t record;
  n numeric;
  m numeric;
  bad text := '';
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'Only admins can run check_invariants().';
  end if;
  perform pg_advisory_xact_lock_shared(public.fund_lock_key());   -- consistent picture, no writer in between
  select * into t from public.fund_totals_internal();

  -- 1) total fund = sum(member equity) + reserve
  select coalesce(sum(amount), 0) into n from public.member_ledger;
  select coalesce(sum(amount), 0) into m from public.fund_reserve;
  rule := 'total_fund = sum(equity) + reserve'; ok := t.total_fund = n + m;
  detail := format('total_fund %s, equity %s, reserve %s', t.total_fund, n, m); return next;

  -- 2) sum(committed) = invested
  select coalesce(sum(p.contribution_delta), 0) into n
    from public.investment_participation p join public.investments i on i.id = p.investment_id
   where i.status = 'held';
  rule := 'sum(committed) = invested'; ok := n = t.invested;
  detail := format('committed %s, invested %s', n, t.invested); return next;

  -- 3) cash >= 0
  rule := 'cash >= 0'; ok := t.cash_available >= 0;
  detail := format('cash %s', t.cash_available); return next;

  -- 4) every allocation set adds up to its event amount
  select count(*) into n from (
    select 1 from public.allocations
     group by event_type, event_id, basis
    having count(distinct event_total) <> 1 or sum(amount) <> max(event_total)) x;
  rule := 'allocation sets sum to their event'; ok := n = 0;
  detail := format('%s unbalanced set(s)', n); return next;

  -- 5) every approved non-late-fee deposit is posted exactly once with the same member and amount
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

  -- 6) every approved late fee is in the reserve exactly once
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

  -- 7) no member has negative contributed capital
  select count(*) into n from (
    select member_id from public.member_ledger
     where kind in ('capital_deposit', 'capital_transfer_in', 'capital_transfer_out')
     group by member_id having sum(amount) < 0) x;
  rule := 'no negative member capital'; ok := n = 0;
  detail := format('%s member(s) below zero', n); return next;

  if raise_on_fail then
    for t in select * from public.check_invariants(false) c where not c.ok loop
      bad := bad || t.rule || ' [' || t.detail || ']; ';
    end loop;
    if bad <> '' then
      raise exception 'INVARIANT FAILED: %', bad;
    end if;
  end if;
end $$;
grant execute on function public.check_invariants(boolean) to authenticated;

-- Run once now: the backfill must leave the books balanced (this raises if not).
select * from public.check_invariants(true);
