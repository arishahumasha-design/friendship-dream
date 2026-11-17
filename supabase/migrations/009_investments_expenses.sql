-- =====================================================================
-- Money model v2, sub-phase 6B-1: investments, sales, income and expenses ON THE LEDGER.
-- Database layer only (no website pages yet). See docs/MONEY_MODEL.md.
-- Run ONCE in Supabase Dashboard > SQL Editor (paste whole file > Run), after 008.
-- Safe to run again. Nothing existing is loosened; one CHECK is widened on purpose:
--   member_ledger may now hold 'income_reversal' rows (always negative).
--
-- Two-person rule everywhere: an admin PROPOSES (row in money_requests), a DIFFERENT admin
-- APPROVES. Nobody approves their own entry, not even the super admin.
-- Every function below: SECURITY DEFINER, search_path = '', fund lock taken FIRST
-- (public.take_fund_lock(): READ COMMITTED only), clock_timestamp() after the lock.
--
-- Sign conventions (amounts are the signed effect on member equity / reserve):
--   sale    : event_total = proceeds - (cost + capitalized costs)   (negative = loss)
--   income  : event_total = +amount (a reversal is a negative income row)
--   expense : event_total = -amount
-- Rounding: each member gets floor(|total| * weight / sum(weights)) to 0.01, the sign restored;
--   the remainder goes to fund_reserve (for a loss / expense the reserve absorbs the negative cents).
--
-- Deposit corrections (item 6): a negative correction is refused when it would push cash in hand
-- below zero, or the member's FREE money (equity - money in held investments) below zero.
-- Example: the money is already in land; the correction would take back money that is not there.
-- =====================================================================

-- ---------- 0) Columns and constraints ----------
alter table public.investments add column if not exists capitalized_costs numeric(14, 2) not null default 0;
alter table public.investments add column if not exists approved_by       uuid references public.profiles (id);
alter table public.investments add column if not exists sale_proposed_by  uuid references public.profiles (id);
alter table public.investments add column if not exists sale_approved_by  uuid references public.profiles (id);
do $$ begin
  alter table public.investments add constraint investments_capitalized_nonneg check (capitalized_costs >= 0);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.investments add constraint investments_two_people
    check (approved_by is null or approved_by is distinct from created_by);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.investments add constraint investments_sale_two_people
    check (sale_approved_by is null or sale_approved_by is distinct from sale_proposed_by);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.investments add constraint investments_sale_fields
    check ((status = 'sold') = (sale_date is not null and sale_amount is not null and sale_amount >= 0));
exception when duplicate_object then null; end $$;

alter table public.expenses add column if not exists investment_id uuid references public.investments (id);
do $$ begin
  alter table public.expenses add constraint expenses_two_people
    check (approved_by is null or approved_by is distinct from created_by);
exception when duplicate_object then null; end $$;

alter table public.investment_income add column if not exists approved_by        uuid references public.profiles (id);
alter table public.investment_income add column if not exists reverses_income_id uuid references public.investment_income (id);
do $$
declare c record;
begin
  -- replace the old "amount > 0" check: a reversal is a negative row that names the original
  for c in select conname from pg_constraint
            where conrelid = 'public.investment_income'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%amount > %(0)%'
  loop
    execute format('alter table public.investment_income drop constraint %I', c.conname);
  end loop;
end $$;
do $$ begin
  alter table public.investment_income add constraint investment_income_sign
    check (amount <> 0 and ((amount > 0) = (reverses_income_id is null)));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.investment_income add constraint investment_income_two_people
    check (approved_by is null or approved_by is distinct from created_by);
exception when duplicate_object then null; end $$;

-- member_ledger: allow 'income_reversal' (always negative). Re-create the CHECKs with names.
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.member_ledger'::regclass and contype = 'c'
              and conname not like 'member_ledger_ck_%'
  loop
    execute format('alter table public.member_ledger drop constraint %I', c.conname);
  end loop;
end $$;
do $$ begin
  alter table public.member_ledger add constraint member_ledger_ck_kind check (kind in (
    'capital_deposit', 'capital_transfer_in', 'capital_transfer_out',
    'profit', 'loss', 'income', 'income_reversal', 'expense',
    'result_transfer_in', 'result_transfer_out'));
  alter table public.member_ledger add constraint member_ledger_ck_nonzero check (amount <> 0);
  alter table public.member_ledger add constraint member_ledger_ck_source check (source_type in
    ('deposit', 'investment', 'expense', 'income', 'transfer', 'adjustment'));
  alter table public.member_ledger add constraint member_ledger_ck_positive
    check (kind not in ('capital_transfer_in', 'profit', 'income', 'result_transfer_in') or amount > 0);
  alter table public.member_ledger add constraint member_ledger_ck_negative
    check (kind not in ('capital_transfer_out', 'loss', 'income_reversal', 'expense', 'result_transfer_out') or amount < 0);
exception when duplicate_object then null; end $$;

-- investment_participation: one purchase row per member and investment, snapshots required.
-- (Partial on reason = 'purchase' so that a share transfer in 6D can add rows for a buyer.)
alter table public.investment_participation alter column capital_at_purchase set not null;
alter table public.investment_participation alter column shares_at_purchase  set not null;
create unique index if not exists investment_participation_one_purchase
  on public.investment_participation (investment_id, member_id) where reason = 'purchase';

-- ---------- 1) Requests (maker side of the two-person rule) ----------
create table if not exists public.money_requests (
  id                  uuid primary key default gen_random_uuid(),
  kind                text not null check (kind in ('purchase', 'investment_cost', 'sale', 'income', 'expense')),
  status              text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  title               text,
  investment_kind     text check (investment_kind in ('land', 'shop', 'other')),
  amount              numeric(14, 2) not null,
  event_date          date not null,
  description         text,
  category_id         integer references public.expense_categories (id),
  receipt_path        text,
  spent_by            text,
  investment_id       uuid references public.investments (id),
  purchase_request_id uuid references public.money_requests (id),
  reverses_income_id  uuid references public.investment_income (id),
  proposed_by         uuid not null references public.profiles (id),
  proposed_at         timestamptz not null,
  decided_by          uuid references public.profiles (id),
  decided_at          timestamptz,
  reject_reason       text,
  result_id           uuid,
  check (status <> 'approved' or decided_by is distinct from proposed_by),
  check ((status = 'pending') = (decided_at is null)),
  check (status <> 'rejected' or nullif(btrim(coalesce(reject_reason, '')), '') is not null),
  check (receipt_path is null or receipt_path like proposed_by::text || '/%')
);
create index if not exists money_requests_pending_idx on public.money_requests (status, kind);

alter table public.money_requests enable row level security;
drop policy if exists money_requests_select on public.money_requests;
create policy money_requests_select on public.money_requests for select to authenticated using (public.is_admin());
revoke all on public.money_requests from public, anon, authenticated, service_role;
grant select on public.money_requests to authenticated;

drop trigger if exists audit_money_requests on public.money_requests;
create trigger audit_money_requests after insert or update on public.money_requests
  for each row execute function public.audit_row();

-- ---------- 2) Immutability: every money table, every role ----------
-- Inserts only from the functions below (posting flag); no deletes; no truncate.
do $$
declare tb text;
begin
  foreach tb in array array['investments', 'expenses', 'investment_income', 'money_requests'] loop
    execute format('drop trigger if exists %I on public.%I', tb || '_insert_guard', tb);
    execute format('create trigger %I before insert on public.%I for each row execute function public.ledger_insert_guard()',
                   tb || '_insert_guard', tb);
  end loop;
  foreach tb in array array['investments', 'expenses', 'investment_income', 'money_requests', 'deposits'] loop
    execute format('drop trigger if exists %I on public.%I', tb || '_no_delete', tb);
    execute format('create trigger %I before delete on public.%I for each row execute function public.block_ledger_changes()',
                   tb || '_no_delete', tb);
    execute format('drop trigger if exists %I on public.%I', tb || '_no_truncate', tb);
    execute format('create trigger %I before truncate on public.%I for each statement execute function public.block_ledger_changes()',
                   tb || '_no_truncate', tb);
  end loop;
  foreach tb in array array['expenses', 'investment_income'] loop
    execute format('drop trigger if exists %I on public.%I', tb || '_no_update', tb);
    execute format('create trigger %I before update on public.%I for each row execute function public.block_ledger_changes()',
                   tb || '_no_update', tb);
  end loop;
  execute 'drop trigger if exists money_requests_fund_lock_first on public.money_requests';
  execute 'create trigger money_requests_fund_lock_first before insert or update on public.money_requests
             for each statement execute function public.lock_fund_before_write()';
end $$;

-- Investments: the ONLY change ever allowed is held -> sold, once, by approve_sale.
create or replace function public.investments_guard() returns trigger
language plpgsql set search_path = '' as $$
declare s text; d date; a numeric; pb uuid; ab uuid;
begin
  if coalesce(current_setting('fd.posting', true), '') <> 'on' then
    raise exception 'Investments can only change through approve_sale().';
  end if;
  if old.status <> 'held' or new.status <> 'sold' then
    raise exception 'A sold investment can never change. Name, cost and purchase date are frozen after approval.';
  end if;
  s := new.status; d := new.sale_date; a := new.sale_amount; pb := new.sale_proposed_by; ab := new.sale_approved_by;
  new := old;                                   -- freeze every column ...
  new.status := s; new.sale_date := d; new.sale_amount := a;
  new.sale_proposed_by := pb; new.sale_approved_by := ab;   -- ... except the sale fields
  return new;
end $$;
drop trigger if exists investments_guard_trg on public.investments;
create trigger investments_guard_trg before update on public.investments
  for each row execute function public.investments_guard();

-- Requests: only pending -> approved / rejected, once, by the functions below.
create or replace function public.money_requests_guard() returns trigger
language plpgsql set search_path = '' as $$
declare s text; db uuid; da timestamptz; rr text; ri uuid;
begin
  if coalesce(current_setting('fd.posting', true), '') <> 'on' then
    raise exception 'Requests can only change through the approve / reject functions.';
  end if;
  if old.status <> 'pending' or new.status not in ('approved', 'rejected') then
    raise exception 'A decided request can never change.';
  end if;
  s := new.status; db := new.decided_by; da := new.decided_at; rr := new.reject_reason; ri := new.result_id;
  new := old;
  new.status := s; new.decided_by := db; new.decided_at := da; new.reject_reason := rr; new.result_id := ri;
  return new;
end $$;
drop trigger if exists money_requests_guard_trg on public.money_requests;
create trigger money_requests_guard_trg before update on public.money_requests
  for each row execute function public.money_requests_guard();

-- Expenses: approved_by is the CHECKER (the signed-in approver), created_by the maker. Never changes.
create or replace function public.expenses_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then
      new.approved_by := auth.uid();
    end if;
    if new.created_by is null or new.approved_by is null or new.created_by = new.approved_by then
      raise exception 'An expense needs a maker and a different approver.';
    end if;
    new.status := 'approved';
    return new;
  end if;
  raise exception 'An approved expense cannot be changed. Enter a correcting entry instead.';
end $$;

-- ---------- 3) Balances ----------
create or replace function public.member_balances_internal()
returns table (member_id uuid, member_no integer, status public.member_status, joined_on date,
               capital numeric, net_result numeric, equity numeric, committed numeric, free numeric)
language sql stable security definer set search_path = '' as $$
  with l as (
    select ml.member_id as mid,
           coalesce(sum(ml.amount) filter (where ml.kind in ('capital_deposit', 'capital_transfer_in', 'capital_transfer_out')), 0) as cap,
           coalesce(sum(ml.amount) filter (where ml.kind not in ('capital_deposit', 'capital_transfer_in', 'capital_transfer_out')), 0) as net
      from public.member_ledger ml
     group by ml.member_id
  ),
  c as (
    select p.member_id as mid, sum(p.contribution_delta) as com
      from public.investment_participation p
      join public.investments i on i.id = p.investment_id
     where i.status = 'held'
     group by p.member_id
  )
  select pr.id, pr.member_no, pr.status, pr.joined_on,
         coalesce(l.cap, 0), coalesce(l.net, 0),
         coalesce(l.cap, 0) + coalesce(l.net, 0),
         coalesce(c.com, 0),
         coalesce(l.cap, 0) + coalesce(l.net, 0) - coalesce(c.com, 0)
    from public.profiles pr
    left join l on l.mid = pr.id
    left join c on c.mid = pr.id;
$$;

create or replace function public.fund_totals_internal()
returns table (capital numeric, late_fees numeric, reserve numeric, investment_income numeric,
               realized_profit numeric, expenses numeric, member_equity numeric,
               total_fund numeric, invested numeric, cash_available numeric)
language sql stable security definer set search_path = '' as $$
  with
  b as (select coalesce(sum(capital), 0) as cap, coalesce(sum(equity), 0) as eq
          from public.member_balances_internal()),
  l as (select
          coalesce(sum(amount) filter (where kind in ('income', 'income_reversal')), 0) as inc,
          coalesce(sum(amount) filter (where kind in ('profit', 'loss')), 0)            as prof,
          coalesce(-sum(amount) filter (where kind = 'expense'), 0)                     as exp
        from public.member_ledger),
  r as (select coalesce(sum(amount), 0) as total,
               coalesce(sum(amount) filter (where kind = 'late_fee'), 0) as lf
        from public.fund_reserve),
  i as (select coalesce(sum(cost + capitalized_costs), 0) as inv from public.investments where status = 'held')
  select b.cap, r.lf, r.total, l.inc, l.prof, l.exp, b.eq,
         b.eq + r.total, i.inv, b.eq + r.total - i.inv
  from b, l, r, i;
$$;

create or replace function public.assert_cash_nonnegative() returns void
language plpgsql security definer set search_path = '' as $$
declare cash numeric;
begin
  select cash_available into cash from public.fund_totals_internal();
  if cash < 0 then
    raise exception 'Cash in hand cannot go below zero (it would be %). Part of the money is already invested (for example in land). Nothing was saved.', cash;
  end if;
end $$;

create or replace function public.assert_free_nonnegative() returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  select b.member_no, b.free into r
    from public.member_balances_internal() b
   where b.free < 0
   order by b.member_no limit 1;
  if found then
    raise exception 'Member No. % would have % of free money (below zero): that money is already in investments. Nothing was saved.', r.member_no, r.free;
  end if;
end $$;

-- member_totals: capital from the balances (same columns as before)
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
    with paid as (
      select d.member_id as mid, sum(d.amount) as s
        from public.deposits d
       where d.status = 'approved' and d.kind = 'monthly' and d.period_month = mstart
       group by d.member_id
    )
    select p.id, p.member_no, p.full_name, p.photo_path, p.status,
           b.capital,
           floor(b.capital / share_val)::int,
           coalesce(paid.s, 0) >= month_amt
      from public.profiles p
      join public.member_balances_internal() b on b.member_id = p.id
      left join paid on paid.mid = p.id
     where p.status in ('active', 'suspended')
       and (vis or public.is_admin() or p.id = auth.uid())
     order by p.member_no;
end $$;

-- Deposits: also refuse a correction that takes back money that is already in investments.
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
  perform public.assert_free_nonnegative();
  return null;
end $$;

-- ---------- 4) Splitting an amount (allocations + ledger + reserve) ----------
-- p_members / p_weights: who shares and by what weight (contribution, equity or shares).
-- basis 'shares' rows are DISPLAY ONLY: written to allocations, never posted.
create or replace function public.post_allocation(
  p_event_type text, p_event_id uuid, p_total numeric,
  p_members uuid[], p_weights numeric[],
  p_kind_pos text, p_kind_neg text, p_source_type text, p_basis text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_sum  numeric;
  v_abs  numeric := abs(p_total);
  v_sign integer := case when p_total < 0 then -1 else 1 end;
  v_amt  numeric;
  v_used numeric := 0;
  v_rem  numeric;
  v_aid  bigint;
  i      integer;
begin
  if coalesce(array_length(p_members, 1), 0) = 0 then
    raise exception 'There is nobody to share this % with.', p_event_type;
  end if;
  if array_length(p_members, 1) <> array_length(p_weights, 1) then
    raise exception 'Internal error: members and weights do not match.';
  end if;
  select sum(w) into v_sum from unnest(p_weights) w;
  if v_sum is null or v_sum <= 0 then
    raise exception 'Cannot split: the total weight is zero (nobody has a share).';
  end if;

  perform set_config('fd.posting', 'on', true);
  for i in 1 .. array_length(p_members, 1) loop
    -- floor on the absolute value, to whole cents, with EXACT integer division (no rounding errors)
    v_amt := div(v_abs * 100 * p_weights[i], v_sum) / 100;
    v_used := v_used + v_amt;
    insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total, created_at)
    values (p_event_type, p_event_id, p_basis, p_members[i], v_sign * v_amt, p_total, clock_timestamp())
    returning id into v_aid;
    if p_basis = 'capital' and v_amt <> 0 then
      insert into public.member_ledger (member_id, kind, amount, source_type, source_id, allocation_id, created_at)
      values (p_members[i], case when v_sign > 0 then p_kind_pos else p_kind_neg end,
              v_sign * v_amt, p_source_type, p_event_id, v_aid, clock_timestamp());
    end if;
  end loop;

  v_rem := v_abs - v_used;                                         -- the cents nobody got
  insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total, created_at)
  values (p_event_type, p_event_id, p_basis, null, v_sign * v_rem, p_total, clock_timestamp())
  returning id into v_aid;
  if p_basis = 'capital' and v_rem <> 0 then
    insert into public.fund_reserve (kind, amount, source_type, source_id, allocation_id, created_at)
    values ('remainder', v_sign * v_rem, 'allocation', p_event_id, v_aid, clock_timestamp());
  end if;
  perform set_config('fd.posting', 'off', true);
end $$;

-- ---------- 5) Request helpers ----------
create or replace function public.require_admin() returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or not public.is_admin() then
    raise exception 'Only an active admin can do this.';
  end if;
  return v_uid;
end $$;

create or replace function public.new_request(
  p_kind text, p_title text, p_investment_kind text, p_amount numeric, p_date date, p_description text,
  p_category_id integer, p_receipt_path text, p_spent_by text,
  p_investment uuid, p_purchase_request uuid, p_reverses uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_uid uuid := auth.uid();
begin
  perform set_config('fd.posting', 'on', true);
  insert into public.money_requests (kind, title, investment_kind, amount, event_date, description, category_id,
                                     receipt_path, spent_by, investment_id, purchase_request_id, reverses_income_id,
                                     proposed_by, proposed_at)
  values (p_kind, nullif(btrim(p_title), ''), p_investment_kind, p_amount, p_date, nullif(btrim(p_description), ''),
          p_category_id, p_receipt_path, nullif(btrim(p_spent_by), ''), p_investment, p_purchase_request, p_reverses,
          v_uid, clock_timestamp())
  returning id into v_id;
  perform set_config('fd.posting', 'off', true);
  return v_id;
end $$;

-- Locks and returns a pending request of the given kind; the caller must not be its maker.
create or replace function public.pending_request(p_id uuid, p_kind text) returns public.money_requests
language plpgsql security definer set search_path = '' as $$
declare r public.money_requests;
begin
  select * into r from public.money_requests where id = p_id for update;
  if not found then raise exception 'Request not found.'; end if;
  if r.kind <> p_kind then raise exception 'This request is a %, not a %.', r.kind, p_kind; end if;
  if r.status <> 'pending' then raise exception 'This request was already %.', r.status; end if;
  if r.proposed_by = auth.uid() then
    raise exception 'You cannot approve your own entry. Another admin must approve it.';
  end if;
  return r;
end $$;

create or replace function public.close_request(p_id uuid, p_status text, p_result uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('fd.posting', 'on', true);
  update public.money_requests
     set status = p_status, decided_by = auth.uid(), decided_at = clock_timestamp(),
         result_id = p_result, reject_reason = p_reason
   where id = p_id;
  perform set_config('fd.posting', 'off', true);
end $$;

-- Charges an approved expense row to its sharers (by equity, or by contribution in one investment).
create or replace function public.charge_expense_internal(p_expense uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare e record; v_members uuid[]; v_weights numeric[];
begin
  select * into e from public.expenses where id = p_expense;
  if e.investment_id is null then
    select array_agg(b.member_id order by b.member_no), array_agg(b.equity order by b.member_no)
      into v_members, v_weights
      from public.member_balances_internal() b
     where b.status = 'active' and b.equity > 0;
  else
    select array_agg(p.member_id order by pr.member_no), array_agg(p.contribution_delta order by pr.member_no)
      into v_members, v_weights
      from public.investment_participation p join public.profiles pr on pr.id = p.member_id
     where p.investment_id = e.investment_id and p.reason = 'purchase';
  end if;
  perform public.post_allocation('expense', e.id, -e.amount, v_members, v_weights, null, 'expense', 'expense', 'capital');
end $$;

-- ---------- 6) RPCs ----------
-- 6a) Purchase
create or replace function public.propose_investment(
  p_title text, p_kind text, p_purchase_date date, p_cost numeric, p_description text default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform public.take_fund_lock();
  perform public.require_admin();
  if nullif(btrim(coalesce(p_title, '')), '') is null then raise exception 'Give the investment a name.'; end if;
  if p_kind is null or p_kind not in ('land', 'shop', 'other') then raise exception 'Choose land, shop or other.'; end if;
  if p_purchase_date is null then raise exception 'Give the purchase date.'; end if;
  if p_cost is null or p_cost <= 0 or p_cost <> round(p_cost, 2) or p_cost > 9999999999.99 then
    raise exception 'The cost must be more than 0, with at most 2 decimals.';
  end if;
  return public.new_request('purchase', p_title, p_kind, p_cost, p_purchase_date, p_description,
                            null, null, null, null, null, null);
end $$;

create or replace function public.approve_investment(p_request uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  r          public.money_requests;
  v_uid      uuid;
  v_cap      numeric;
  v_basis    numeric;
  v_free     numeric;
  v_inv      uuid;
  v_share    numeric;
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
  v_basis := r.amount + v_cap;

  -- who takes part: active NOW, joined on or before the purchase date, with free money
  create temp table if not exists pg_temp.fd_buyers (member_id uuid, member_no int, free numeric, capital numeric) on commit drop;
  truncate pg_temp.fd_buyers;
  insert into pg_temp.fd_buyers
  select b.member_id, b.member_no, b.free, b.capital
    from public.member_balances_internal() b
   where b.status = 'active' and b.joined_on is not null and b.joined_on <= r.event_date and b.free > 0;

  select coalesce(sum(free), 0) into v_free from pg_temp.fd_buyers;
  if v_free < v_basis then
    raise exception 'Not enough free money: this purchase needs %, the members who can take part have %.', v_basis, v_free;
  end if;

  perform set_config('fd.posting', 'on', true);
  insert into public.investments (title, kind, description, purchase_date, cost, capitalized_costs, status,
                                  created_by, approved_by, created_at)
  values (r.title, r.investment_kind, r.description, r.event_date, r.amount, v_cap, 'held',
          r.proposed_by, v_uid, clock_timestamp())
  returning id into v_inv;

  -- contribution_i = basis * free_i / sum(free), largest-remainder in cents so they add up exactly
  select coalesce((select (value #>> '{}')::numeric from public.app_settings where key = 'share_value'), 5000) into v_share;
  insert into public.investment_participation (investment_id, member_id, contribution_delta,
                                               capital_at_purchase, shares_at_purchase, reason, created_at)
  select v_inv, x.member_id, (x.fl + case when x.rn <= k.leftover then 1 else 0 end) / 100.0,
         x.capital, floor(x.capital / v_share)::int, 'purchase', clock_timestamp()
    from (select f.*, row_number() over (order by f.rest desc, f.member_no) as rn
            from (select b.member_id, b.member_no, b.capital,
                         div(v_basis * 100 * b.free, v_free) as fl,      -- exact whole cents (floor)
                         mod(v_basis * 100 * b.free, v_free) as rest     -- same denominator: exact ordering
                    from pg_temp.fd_buyers b) f) x,
         (select (v_basis * 100 - sum(div(v_basis * 100 * b.free, v_free)))::bigint as leftover
            from pg_temp.fd_buyers b) k
   where x.fl + case when x.rn <= k.leftover then 1 else 0 end > 0;
  perform set_config('fd.posting', 'off', true);

  perform public.close_request(r.id, 'approved', v_inv, null);
  perform public.assert_cash_nonnegative();
  perform public.assert_free_nonnegative();
  return v_inv;
end $$;

-- 6b) Extra costs: for a PENDING purchase they join its cost basis (when the purchase is approved);
--     for a HELD investment they are charged to its participants by contribution (an expense row).
create or replace function public.add_investment_cost(
  p_target uuid, p_amount numeric, p_title text, p_date date, p_description text default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform public.take_fund_lock();
  perform public.require_admin();
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) or p_amount > 9999999999.99 then
    raise exception 'The amount must be more than 0, with at most 2 decimals.';
  end if;
  if nullif(btrim(coalesce(p_title, '')), '') is null then raise exception 'Say what this cost is for.'; end if;
  if p_date is null then raise exception 'Give the date.'; end if;
  if exists (select 1 from public.money_requests where id = p_target and kind = 'purchase' and status = 'pending') then
    return public.new_request('investment_cost', p_title, null, p_amount, p_date, p_description,
                              null, null, null, null, p_target, null);
  elsif exists (select 1 from public.investments where id = p_target and status = 'held') then
    return public.new_request('investment_cost', p_title, null, p_amount, p_date, p_description,
                              null, null, null, p_target, null, null);
  end if;
  raise exception 'Choose a purchase that is still waiting, or an investment that is still held.';
end $$;

create or replace function public.approve_investment_cost(p_request uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.money_requests; v_uid uuid; v_exp uuid;
begin
  perform public.take_fund_lock();
  v_uid := public.require_admin();
  r := public.pending_request(p_request, 'investment_cost');

  if r.purchase_request_id is not null then
    if not exists (select 1 from public.money_requests where id = r.purchase_request_id and status = 'pending') then
      raise exception 'That purchase is no longer waiting; this cost cannot join its cost basis.';
    end if;
    perform public.close_request(r.id, 'approved', null, null);   -- counted when the purchase is approved
    return null;
  end if;

  if not exists (select 1 from public.investments where id = r.investment_id and status = 'held') then
    raise exception 'That investment is not held any more.';
  end if;
  perform set_config('fd.posting', 'on', true);
  insert into public.expenses (title, amount, spent_on, description, investment_id, created_by, approved_by, created_at)
  values (r.title, r.amount, r.event_date, r.description, r.investment_id, r.proposed_by, v_uid, clock_timestamp())
  returning id into v_exp;
  perform set_config('fd.posting', 'off', true);
  perform public.charge_expense_internal(v_exp);

  perform public.close_request(r.id, 'approved', v_exp, null);
  perform public.assert_cash_nonnegative();
  perform public.assert_free_nonnegative();
  return v_exp;
end $$;

-- 6c) Sale
create or replace function public.propose_sale(
  p_investment uuid, p_proceeds numeric, p_sale_date date, p_note text default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare i record;
begin
  perform public.take_fund_lock();
  perform public.require_admin();
  select * into i from public.investments where id = p_investment;
  if not found then raise exception 'Investment not found.'; end if;
  if i.status <> 'held' then raise exception 'This investment is already sold.'; end if;
  if exists (select 1 from public.money_requests where kind = 'sale' and investment_id = p_investment and status = 'pending') then
    raise exception 'A sale of this investment is already waiting for approval.';
  end if;
  if p_proceeds is null or p_proceeds < 0 or p_proceeds <> round(p_proceeds, 2) or p_proceeds > 9999999999.99 then
    raise exception 'The sale amount must be 0 or more, with at most 2 decimals.';
  end if;
  if p_sale_date is null or p_sale_date < i.purchase_date then
    raise exception 'The sale date must be on or after the purchase date.';
  end if;
  return public.new_request('sale', i.title, null, p_proceeds, p_sale_date, p_note,
                            null, null, null, p_investment, null, null);
end $$;

create or replace function public.approve_sale(p_request uuid) returns numeric
language plpgsql security definer set search_path = '' as $$
declare
  r         public.money_requests;
  v_uid     uuid;
  i         record;
  v_profit  numeric;
  v_members uuid[];
  v_contrib numeric[];
  v_shares  numeric[];
begin
  perform public.take_fund_lock();
  v_uid := public.require_admin();
  r := public.pending_request(p_request, 'sale');

  select * into i from public.investments where id = r.investment_id for update;
  if i.status <> 'held' then raise exception 'This investment is already sold.'; end if;
  v_profit := r.amount - (i.cost + i.capitalized_costs);

  perform set_config('fd.posting', 'on', true);
  update public.investments
     set status = 'sold', sale_date = r.event_date, sale_amount = r.amount,
         sale_proposed_by = r.proposed_by, sale_approved_by = v_uid
   where id = i.id;
  perform set_config('fd.posting', 'off', true);

  select array_agg(p.member_id order by pr.member_no),
         array_agg(p.contribution_delta order by pr.member_no),
         array_agg(p.shares_at_purchase::numeric order by pr.member_no)
    into v_members, v_contrib, v_shares
    from public.investment_participation p join public.profiles pr on pr.id = p.member_id
   where p.investment_id = i.id and p.reason = 'purchase';

  -- official view: by contribution (posted)
  perform public.post_allocation('sale', i.id, v_profit, v_members, v_contrib, 'profit', 'loss', 'investment', 'capital');
  -- illustrative view: by shares (display only), only if anyone has shares
  if (select coalesce(sum(s), 0) from unnest(v_shares) s) > 0 then
    perform public.post_allocation('sale', i.id, v_profit, v_members, v_shares, 'profit', 'loss', 'investment', 'shares');
  end if;

  perform public.close_request(r.id, 'approved', i.id, null);
  perform public.assert_cash_nonnegative();
  perform public.assert_free_nonnegative();
  return v_profit;
end $$;

-- 6d) Income (rent etc.) and its reversal (a negative row naming the original, never more than it)
create or replace function public.record_income(
  p_investment uuid, p_amount numeric, p_received_on date, p_note text default null, p_reverses uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare o record;
begin
  perform public.take_fund_lock();
  perform public.require_admin();
  if not exists (select 1 from public.investments where id = p_investment) then raise exception 'Investment not found.'; end if;
  if p_received_on is null then raise exception 'Give the date.'; end if;
  if p_amount is null or p_amount = 0 or p_amount <> round(p_amount, 2) or abs(p_amount) > 9999999999.99 then
    raise exception 'Give an amount (not 0), with at most 2 decimals.';
  end if;
  if p_reverses is null then
    if p_amount < 0 then raise exception 'Income must be more than 0. To undo income, reverse the original entry.'; end if;
  else
    select * into o from public.investment_income where id = p_reverses;
    if not found or o.investment_id <> p_investment or o.amount <= 0 then
      raise exception 'Choose the original income entry of this investment to reverse.';
    end if;
    if p_amount > 0 then raise exception 'A reversal must be a negative amount.'; end if;
  end if;
  return public.new_request('income', null, null, p_amount, p_received_on, p_note,
                            null, null, null, p_investment, null, p_reverses);
end $$;

create or replace function public.approve_income(p_request uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  r         public.money_requests;
  v_uid     uuid;
  v_orig    numeric;
  v_done    numeric;
  v_inc     uuid;
  v_members uuid[];
  v_contrib numeric[];
begin
  perform public.take_fund_lock();
  v_uid := public.require_admin();
  r := public.pending_request(p_request, 'income');

  if r.reverses_income_id is not null then
    select amount into v_orig from public.investment_income where id = r.reverses_income_id;
    select coalesce(sum(amount), 0) into v_done from public.investment_income where reverses_income_id = r.reverses_income_id;
    if v_orig + v_done + r.amount < 0 then
      raise exception 'A reversal cannot be more than the original income (left to reverse: %).', v_orig + v_done;
    end if;
  end if;

  perform set_config('fd.posting', 'on', true);
  insert into public.investment_income (investment_id, amount, received_on, note, created_by, approved_by,
                                        reverses_income_id, created_at)
  values (r.investment_id, r.amount, r.event_date, r.description, r.proposed_by, v_uid,
          r.reverses_income_id, clock_timestamp())
  returning id into v_inc;
  perform set_config('fd.posting', 'off', true);

  select array_agg(p.member_id order by pr.member_no), array_agg(p.contribution_delta order by pr.member_no)
    into v_members, v_contrib
    from public.investment_participation p join public.profiles pr on pr.id = p.member_id
   where p.investment_id = r.investment_id and p.reason = 'purchase';
  perform public.post_allocation('income', v_inc, r.amount, v_members, v_contrib, 'income', 'income_reversal', 'income', 'capital');

  perform public.close_request(r.id, 'approved', v_inc, null);
  perform public.assert_cash_nonnegative();
  perform public.assert_free_nonnegative();
  return v_inc;
end $$;

-- 6e) Expenses: general (all ACTIVE members by equity) or for one investment (its participants)
create or replace function public.propose_expense(
  p_title text, p_amount numeric, p_spent_on date,
  p_category_id integer default null, p_investment uuid default null, p_description text default null,
  p_receipt_path text default null, p_spent_by text default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid;
begin
  perform public.take_fund_lock();
  v_uid := public.require_admin();
  if nullif(btrim(coalesce(p_title, '')), '') is null then raise exception 'Say what the expense is for.'; end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) or p_amount > 9999999999.99 then
    raise exception 'The amount must be more than 0, with at most 2 decimals.';
  end if;
  if p_spent_on is null then raise exception 'Give the date.'; end if;
  if p_investment is not null and not exists (select 1 from public.investments where id = p_investment and status = 'held') then
    raise exception 'An investment expense needs an investment that is still held.';
  end if;
  if p_receipt_path is not null and p_receipt_path not like v_uid::text || '/%' then
    raise exception 'The receipt must be uploaded to your own folder.';
  end if;
  return public.new_request('expense', p_title, null, p_amount, p_spent_on, p_description,
                            p_category_id, p_receipt_path, p_spent_by, p_investment, null, null);
end $$;

create or replace function public.approve_expense(p_request uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.money_requests; v_uid uuid; v_exp uuid;
begin
  perform public.take_fund_lock();
  v_uid := public.require_admin();
  r := public.pending_request(p_request, 'expense');
  if r.investment_id is not null and not exists (select 1 from public.investments where id = r.investment_id and status = 'held') then
    raise exception 'That investment is not held any more.';
  end if;

  perform set_config('fd.posting', 'on', true);
  insert into public.expenses (category_id, title, amount, spent_on, description, receipt_path, spent_by,
                               investment_id, created_by, approved_by, created_at)
  values (r.category_id, r.title, r.amount, r.event_date, r.description, r.receipt_path, r.spent_by,
          r.investment_id, r.proposed_by, v_uid, clock_timestamp())
  returning id into v_exp;
  perform set_config('fd.posting', 'off', true);
  perform public.charge_expense_internal(v_exp);

  perform public.close_request(r.id, 'approved', v_exp, null);
  perform public.assert_cash_nonnegative();
  perform public.assert_free_nonnegative();
  return v_exp;
end $$;

-- 6f) Reject (any admin; the maker may withdraw their own request)
create or replace function public.reject_request(p_request uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  perform public.take_fund_lock();
  perform public.require_admin();
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason.'; end if;
  select * into r from public.money_requests where id = p_request for update;
  if not found then raise exception 'Request not found.'; end if;
  if r.status <> 'pending' then raise exception 'This request was already %.', r.status; end if;
  perform public.close_request(r.id, 'rejected', null, btrim(p_reason));
end $$;

-- ---------- 7) check_invariants(): 18 rules ----------
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

  -- 1) cash rebuilt independently from the source tables = cash from the ledger
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

  -- 3) total fund = sum(equity) + reserve, and the balances agree with the raw ledger
  select coalesce(sum(equity), 0) into n from public.member_balances_internal();
  select coalesce(sum(amount), 0) into m from public.member_ledger;
  select coalesce(sum(amount), 0) into k from public.fund_reserve;
  rule := 'total_fund = sum(equity) + reserve'; ok := t.total_fund = n + k and n = m;
  detail := format('total_fund %s, equity %s (raw ledger %s), reserve %s', t.total_fund, n, m, k); return next;

  -- 4) sum(committed) = invested
  select coalesce(sum(p.contribution_delta), 0) into n
    from public.investment_participation p join public.investments i on i.id = p.investment_id
   where i.status = 'held';
  rule := 'sum(committed) = invested'; ok := n = t.invested;
  detail := format('committed %s, invested %s', n, t.invested); return next;

  -- 5) every investment: contributions = cost basis (cost + capitalized costs)
  select count(*) into n from public.investments i
   where i.cost + i.capitalized_costs <> coalesce((select sum(p.contribution_delta) from public.investment_participation p
                                                    where p.investment_id = i.id), 0);
  rule := 'each investment: contributions = cost basis'; ok := n = 0;
  detail := format('%s investment(s) out of balance', n); return next;

  -- 6) every member: free >= 0
  select count(*) into n from public.member_balances_internal() where free < 0;
  rule := 'each member: free >= 0'; ok := n = 0;
  detail := format('%s member(s) below zero', n); return next;

  -- 7) every approved non-late-fee deposit is posted exactly once
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

  -- 8) every approved late fee is in the reserve exactly once
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

  -- 9) capital only ever comes from deposits (transfers come in 6D)
  select count(*) into n from public.member_ledger where kind = 'capital_deposit' and source_type <> 'deposit';
  rule := 'capital_deposit rows come from deposits'; ok := n = 0;
  detail := format('%s row(s) from elsewhere', n); return next;

  -- 10) (replaces the 6A-only rule) every non-deposit posting belongs to an allocation
  select count(*) into n from public.member_ledger where source_type <> 'deposit' and allocation_id is null;
  select count(*) into m from public.fund_reserve  where source_type <> 'deposit' and allocation_id is null;
  rule := 'non-deposit postings come from allocations'; ok := n = 0 and m = 0;
  detail := format('%s ledger row(s) and %s reserve row(s) without an allocation', n, m); return next;

  -- 11) no member has negative contributed capital
  select count(*) into n from public.member_balances_internal() where capital < 0;
  rule := 'no negative member capital'; ok := n = 0;
  detail := format('%s member(s) below zero', n); return next;

  -- 12) every allocation set adds up to its event_total
  select count(*) into n from (
    select 1 from public.allocations
     group by event_type, event_id, basis
    having count(distinct event_total) <> 1 or sum(amount) <> max(event_total)) x;
  rule := 'allocation sets sum to event_total'; ok := n = 0;
  detail := format('%s unbalanced set(s)', n); return next;

  -- 13) event_total equals the real event amount
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

  -- 14) capital-basis allocations are posted exactly once; shares-basis / zero rows never are
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

  -- 15) every posted row matches its allocation (member, amount, event, kind)
  select count(*) into n from public.member_ledger l join public.allocations a on a.id = l.allocation_id
   where a.basis <> 'capital' or a.member_id is distinct from l.member_id or a.amount <> l.amount
      or l.source_id <> a.event_id
      or not (   (a.event_type = 'sale'    and l.kind in ('profit', 'loss')            and l.source_type = 'investment')
              or (a.event_type = 'income'  and l.kind in ('income', 'income_reversal') and l.source_type = 'income')
              or (a.event_type = 'expense' and l.kind = 'expense'                      and l.source_type = 'expense'));
  select count(*) into m from public.fund_reserve r join public.allocations a on a.id = r.allocation_id
   where a.basis <> 'capital' or a.member_id is not null or a.amount <> r.amount or r.source_id <> a.event_id;
  rule := 'posted rows match their allocation'; ok := n = 0 and m = 0;
  detail := format('%s ledger row(s), %s reserve row(s) do not match', n, m); return next;

  -- 16) every approved event HAS its allocation set (sold investments, expenses, income)
  select count(*) into n from public.investments i
   where i.status = 'sold'
     and (not exists (select 1 from public.allocations a where a.event_type = 'sale' and a.event_id = i.id and a.basis = 'capital')
          or ((select coalesce(sum(p.shares_at_purchase), 0) from public.investment_participation p
                where p.investment_id = i.id and p.reason = 'purchase') > 0
              and not exists (select 1 from public.allocations a where a.event_type = 'sale' and a.event_id = i.id and a.basis = 'shares')));
  select count(*) into m from public.expenses x
   where x.status = 'approved'
     and not exists (select 1 from public.allocations a where a.event_type = 'expense' and a.event_id = x.id and a.basis = 'capital');
  select count(*) into k from public.investment_income ic
   where not exists (select 1 from public.allocations a where a.event_type = 'income' and a.event_id = ic.id and a.basis = 'capital');
  rule := 'every event has its allocation'; ok := n = 0 and m = 0 and k = 0;
  detail := format('%s sale(s), %s expense(s), %s income row(s) without allocation', n, m, k); return next;

  -- 17) two people for every money decision; approved requests produced their result
  select (select count(*) from public.investments where approved_by is null or approved_by = created_by)
       + (select count(*) from public.investments where status = 'sold' and (sale_approved_by is null or sale_approved_by = sale_proposed_by))
       + (select count(*) from public.expenses where approved_by is null or approved_by = created_by)
       + (select count(*) from public.investment_income where approved_by is null or approved_by = created_by)
       + (select count(*) from public.money_requests where status = 'approved' and decided_by = proposed_by)
    into n;
  select count(*) into m from public.money_requests q
   where q.status = 'approved'
     and case q.kind
           when 'purchase' then not exists (select 1 from public.investments i where i.id = q.result_id and i.created_by = q.proposed_by)
           when 'sale'     then not exists (select 1 from public.investments i where i.id = q.result_id and i.status = 'sold' and i.sale_amount = q.amount)
           when 'income'   then not exists (select 1 from public.investment_income ic where ic.id = q.result_id and ic.amount = q.amount)
           when 'expense'  then not exists (select 1 from public.expenses x where x.id = q.result_id and x.amount = q.amount)
           when 'investment_cost' then
             case when q.purchase_request_id is not null then false
                  else not exists (select 1 from public.expenses x where x.id = q.result_id and x.amount = q.amount) end
           else true
         end;
  rule := 'two people per decision, results exist'; ok := n = 0 and m = 0;
  detail := format('%s one-person decision(s), %s approved request(s) without their result', n, m); return next;

  -- 18) nobody took part in a purchase from before they joined
  select count(*) into n from public.investment_participation p
    join public.investments i on i.id = p.investment_id
    join public.profiles pr on pr.id = p.member_id
   where p.reason = 'purchase' and (pr.joined_on is null or pr.joined_on > i.purchase_date);
  rule := 'participants joined before the purchase'; ok := n = 0;
  detail := format('%s participation row(s) from later joiners', n); return next;

  if raise_on_fail then
    for t in select * from public.check_invariants(false) c where not c.ok loop
      bad := bad || t.rule || ' [' || t.detail || ']; ';
    end loop;
    if bad <> '' then
      raise exception 'INVARIANT FAILED: %', bad;
    end if;
  end if;
end $$;

-- ---------- 8) Permissions ----------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig
             from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('investments_guard', 'money_requests_guard', 'expenses_guard',
                                'member_balances_internal', 'fund_totals_internal', 'assert_cash_nonnegative',
                                'assert_free_nonnegative', 'member_totals', 'post_deposit_to_ledger', 'post_allocation',
                                'require_admin', 'new_request', 'pending_request', 'close_request', 'charge_expense_internal',
                                'propose_investment', 'approve_investment', 'add_investment_cost', 'approve_investment_cost',
                                'propose_sale', 'approve_sale', 'record_income', 'approve_income',
                                'propose_expense', 'approve_expense', 'reject_request', 'check_invariants')
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', f.sig);
  end loop;
end $$;

grant execute on function public.member_totals()                                                   to authenticated;
grant execute on function public.check_invariants(boolean)                                          to authenticated;
grant execute on function public.propose_investment(text, text, date, numeric, text)                to authenticated;
grant execute on function public.approve_investment(uuid)                                           to authenticated;
grant execute on function public.add_investment_cost(uuid, numeric, text, date, text)               to authenticated;
grant execute on function public.approve_investment_cost(uuid)                                      to authenticated;
grant execute on function public.propose_sale(uuid, numeric, date, text)                            to authenticated;
grant execute on function public.approve_sale(uuid)                                                 to authenticated;
grant execute on function public.record_income(uuid, numeric, date, text, uuid)                     to authenticated;
grant execute on function public.approve_income(uuid)                                               to authenticated;
grant execute on function public.propose_expense(text, numeric, date, integer, uuid, text, text, text) to authenticated;
grant execute on function public.approve_expense(uuid)                                              to authenticated;
grant execute on function public.reject_request(uuid, text)                                         to authenticated;

-- ---------- 9) Prove it ----------
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
