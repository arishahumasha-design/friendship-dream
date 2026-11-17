-- =====================================================================
-- Money model v2, sub-phase 6A hardening (Opus review of 007).
-- Run ONCE in Supabase Dashboard > SQL Editor (paste whole file > Run), after 007.
-- Safe to run again. It only makes rules STRICTER; nothing is deleted or loosened.
-- =====================================================================

-- ---------- 0) 6A assumes there are no investments / expenses / income yet ----------
do $$
declare n bigint;
begin
  select (select count(*) from public.investments)
       + (select count(*) from public.expenses)
       + (select count(*) from public.investment_income) into n;
  if n > 0 then
    raise exception 'STOP: money model v2 (6A) expects the tables investments, expenses and investment_income to be EMPTY, but they hold % row(s). Those must be moved onto the ledger with the 6B functions first. Nothing was changed.', n;
  end if;
end $$;

-- ---------- 1) One lock helper: READ COMMITTED only, fund lock taken first ----------
create or replace function public.take_fund_lock() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'Money writes must run with READ COMMITTED isolation (this transaction uses %).',
      current_setting('transaction_isolation');
  end if;
  perform pg_advisory_xact_lock(public.fund_lock_key());
end $$;

-- Statement-level BEFORE trigger: the fund lock is always taken BEFORE any row lock,
-- so two writers can never wait for each other in the opposite order.
create or replace function public.lock_fund_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.take_fund_lock();
  return null;
end $$;

do $$
declare tb text;
begin
  foreach tb in array array['deposits', 'investments', 'expenses', 'investment_income'] loop
    execute format('drop trigger if exists %I on public.%I', tb || '_fund_lock_first', tb);
    execute format('create trigger %I before insert or update on public.%I for each statement execute function public.lock_fund_before_write()',
                   tb || '_fund_lock_first', tb);
  end loop;
end $$;

-- ---------- 2) Ledger rows can only be written by the posting functions ----------
-- The posting functions switch a transaction-local flag on right before they insert and off right after.
create or replace function public.ledger_insert_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if coalesce(current_setting('fd.posting', true), '') <> 'on' then
    raise exception 'Rows in % can only be written by the database posting functions.', tg_table_name;
  end if;
  return new;
end $$;

do $$
declare tb text;
begin
  foreach tb in array array['member_ledger', 'fund_reserve', 'allocations', 'investment_participation'] loop
    execute format('drop trigger if exists %I on public.%I', tb || '_insert_guard', tb);
    execute format('create trigger %I before insert on public.%I for each row execute function public.ledger_insert_guard()',
                   tb || '_insert_guard', tb);
  end loop;
end $$;

-- ---------- 3) Table privileges ----------
-- Ledger tables: nobody but the owner writes; members/admins only read (RLS decides which rows).
revoke all on public.member_ledger, public.fund_reserve, public.allocations, public.investment_participation
  from public, anon, authenticated, service_role;
grant select on public.member_ledger, public.fund_reserve, public.allocations, public.investment_participation
  to authenticated;

-- Investments / expenses / income: no writes from any API role until the 6B functions exist.
revoke insert, update, delete, truncate, trigger, references
  on public.investments, public.expenses, public.investment_income
  from public, anon, authenticated, service_role;
revoke all on public.investments, public.expenses, public.investment_income from anon;

-- Deposits: nobody deletes or truncates money records.
revoke delete, truncate, trigger, references on public.deposits from public, anon, authenticated, service_role;
revoke all on public.deposits from anon;

-- ---------- 4) Allocations tied to the rows they produced ----------
alter table public.member_ledger add column if not exists allocation_id bigint references public.allocations (id);
alter table public.fund_reserve  add column if not exists allocation_id bigint references public.allocations (id);
create unique index if not exists member_ledger_allocation_once on public.member_ledger (allocation_id) where allocation_id is not null;
create unique index if not exists fund_reserve_allocation_once  on public.fund_reserve  (allocation_id) where allocation_id is not null;
-- one row per member (and one remainder row) per event and basis
create unique index if not exists allocations_one_per_member
  on public.allocations (event_type, event_id, basis, member_id) nulls not distinct;
comment on column public.allocations.event_total is
  'Signed total the event adds to member equity + reserve: sale = sale_amount - cost (negative = loss), expense = -amount, income = +amount.';

-- ---------- 5) Posting: fund lock first, flag on only while inserting, real clock time ----------
create or replace function public.post_deposit_to_ledger() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status <> 'approved' or (tg_op = 'UPDATE' and old.status = 'approved') then
    return null;
  end if;
  perform public.take_fund_lock();

  perform set_config('fd.posting', 'on', true);
  if new.kind = 'late_fee' then
    insert into public.fund_reserve (kind, amount, source_type, source_id, created_at)
    values ('late_fee', new.amount, 'deposit', new.id, clock_timestamp());
  else
    insert into public.member_ledger (member_id, kind, amount, source_type, source_id, created_at)
    values (new.member_id, 'capital_deposit', new.amount, 'deposit', new.id, clock_timestamp());
  end if;
  perform set_config('fd.posting', 'off', true);

  perform public.assert_cash_nonnegative();
  return null;
end $$;

create or replace function public.investments_cash_check() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.take_fund_lock();
  perform public.assert_cash_nonnegative();
  return null;
end $$;

-- ---------- 6) check_invariants(): stricter and independent ----------
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
  -- Any request that comes through the API carries a JWT: only admins may run this.
  -- (The SQL Editor has no JWT.)
  if coalesce(current_setting('request.jwt.claims', true), '') <> '' and not public.is_admin() then
    raise exception 'Only admins can run check_invariants().';
  end if;
  perform pg_advisory_xact_lock_shared(public.fund_lock_key());
  select * into t from public.fund_totals_internal();

  -- 1) cash rebuilt independently from the source tables = cash from the ledger
  select coalesce(sum(amount), 0) into n from public.deposits where status = 'approved';
  n := n + (select coalesce(sum(amount), 0) from public.investment_income)
         + (select coalesce(sum(sale_amount), 0) from public.investments where status = 'sold')
         - (select coalesce(sum(cost), 0) from public.investments)
         - (select coalesce(sum(amount), 0) from public.expenses where status = 'approved');
  rule := 'cash: independent rebuild = ledger'; ok := n = t.cash_available;
  detail := format('rebuilt %s, ledger %s', n, t.cash_available); return next;

  -- 2) cash >= 0
  rule := 'cash >= 0'; ok := t.cash_available >= 0;
  detail := format('cash %s', t.cash_available); return next;

  -- 3) sum(committed) = invested
  select coalesce(sum(p.contribution_delta), 0) into n
    from public.investment_participation p join public.investments i on i.id = p.investment_id
   where i.status = 'held';
  rule := 'sum(committed) = invested'; ok := n = t.invested;
  detail := format('committed %s, invested %s', n, t.invested); return next;

  -- 4) every investment: contributions add up exactly to its cost basis
  select count(*) into n from public.investments i
   where i.cost <> coalesce((select sum(p.contribution_delta) from public.investment_participation p
                              where p.investment_id = i.id), 0);
  rule := 'each investment: contributions = cost'; ok := n = 0;
  detail := format('%s investment(s) out of balance', n); return next;

  -- 5) every member: free = equity - committed >= 0
  select count(*) into n from (
    select pr.id
      from public.profiles pr
     where coalesce((select sum(l.amount) from public.member_ledger l where l.member_id = pr.id), 0)
         - coalesce((select sum(p.contribution_delta)
                       from public.investment_participation p join public.investments i on i.id = p.investment_id
                      where p.member_id = pr.id and i.status = 'held'), 0) < 0) x;
  rule := 'each member: free >= 0'; ok := n = 0;
  detail := format('%s member(s) below zero', n); return next;

  -- 6) every approved non-late-fee deposit is posted exactly once (same member, amount)
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

  -- 7) every approved late fee is in the reserve exactly once
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

  -- 8) capital only ever comes from deposits (transfers come in 6D)
  select count(*) into n from public.member_ledger where kind = 'capital_deposit' and source_type <> 'deposit';
  rule := 'capital_deposit rows come from deposits'; ok := n = 0;
  detail := format('%s row(s) from elsewhere', n); return next;

  -- 9) 6A ONLY (relax in 6B): no ledger or reserve row exists except deposit postings
  select count(*) into n from public.member_ledger where source_type <> 'deposit';
  select count(*) into m from public.fund_reserve  where source_type <> 'deposit';
  rule := '6A: only deposit postings exist'; ok := n = 0 and m = 0;
  detail := format('%s ledger row(s) and %s reserve row(s) not from deposits', n, m); return next;

  -- 10) no member has negative contributed capital
  select count(*) into n from (
    select member_id from public.member_ledger
     where kind in ('capital_deposit', 'capital_transfer_in', 'capital_transfer_out')
     group by member_id having sum(amount) < 0) x;
  rule := 'no negative member capital'; ok := n = 0;
  detail := format('%s member(s) below zero', n); return next;

  -- 11) every allocation set adds up to its event_total (one event_total per set)
  select count(*) into n from (
    select 1 from public.allocations
     group by event_type, event_id, basis
    having count(distinct event_total) <> 1 or sum(amount) <> max(event_total)) x;
  rule := 'allocation sets sum to event_total'; ok := n = 0;
  detail := format('%s unbalanced set(s)', n); return next;

  -- 12) event_total equals the real event amount
  select count(*) into n from (
    select distinct a.event_type, a.event_id, a.event_total from public.allocations a) e
   where case e.event_type
           when 'sale'    then e.event_total is distinct from
                                (select i.sale_amount - i.cost from public.investments i
                                  where i.id = e.event_id and i.status = 'sold')
           when 'expense' then e.event_total is distinct from
                                (select -x.amount from public.expenses x where x.id = e.event_id and x.status = 'approved')
           when 'income'  then e.event_total is distinct from
                                (select ic.amount from public.investment_income ic where ic.id = e.event_id)
           else true      -- no rule yet for this event type: refuse until it is defined (6B/6D)
         end;
  rule := 'event_total = real event amount'; ok := n = 0;
  detail := format('%s event(s) do not match their source', n); return next;

  -- 13) capital-basis allocations are posted exactly once; shares-basis rows never are
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

  -- 14) every ledger / reserve row that names an allocation matches it
  select count(*) into n from public.member_ledger l join public.allocations a on a.id = l.allocation_id
   where a.basis <> 'capital' or a.member_id is distinct from l.member_id or a.amount <> l.amount;
  select count(*) into m from public.fund_reserve r join public.allocations a on a.id = r.allocation_id
   where a.basis <> 'capital' or a.member_id is not null or a.amount <> r.amount;
  rule := 'posted rows match their allocation'; ok := n = 0 and m = 0;
  detail := format('%s ledger row(s), %s reserve row(s) do not match', n, m); return next;

  if raise_on_fail then
    for t in select * from public.check_invariants(false) c where not c.ok loop
      bad := bad || t.rule || ' [' || t.detail || ']; ';
    end loop;
    if bad <> '' then
      raise exception 'INVARIANT FAILED: %', bad;
    end if;
  end if;
end $$;

-- ---------- 7) Function permissions: nothing for PUBLIC / anon, only what the app needs ----------
-- Future functions: no automatic EXECUTE for PUBLIC (all schemas) and none for anon in public.
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated;

-- Existing functions, one by one by their full signature.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig
             from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')  -- skip extension functions
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

-- What the website (logged-in users) needs:
grant execute on function public.is_active_member()          to authenticated;   -- used by RLS policies
grant execute on function public.is_admin()                  to authenticated;   -- used by RLS policies
grant execute on function public.is_super_admin()            to authenticated;   -- used by RLS policies
grant execute on function public.valid_setting(text, jsonb)  to authenticated;   -- used by a CHECK constraint
grant execute on function public.fund_summary()              to authenticated;
grant execute on function public.member_totals()             to authenticated;
grant execute on function public.deposit_ledger()            to authenticated;
grant execute on function public.check_invariants(boolean)   to authenticated;   -- admins only (checked inside)

-- ---------- 8) Prove it ----------
do $$
declare names text;
begin
  select string_agg(p.proname, ', ') into names
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     and has_function_privilege('anon', p.oid, 'execute');
  if names is not null then
    raise exception 'anon can still execute: %', names;
  end if;
end $$;

select * from public.check_invariants(true);
