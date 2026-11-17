-- =====================================================================
-- Money model v2: hardening after the review of 009.
-- Run ONCE in Supabase Dashboard > SQL Editor (paste whole file > Run), after 009.
-- Safe to run again. See docs/MONEY_MODEL.md (updated) for the decisions behind it.
--
-- Changes in short
--  1. allocations remember weight and weight_sum -> every amount can be recomputed by check_invariants.
--     Rows written before 010 keep weight = NULL ("legacy") and are left out of the recompute rule:
--     allocations are append-only for every role, so they cannot be back-filled without switching that
--     protection off, which we do not do.
--  2. OWNER DECISION: expenses, investment costs and reversals only need cash >= 0. A member's FREE money
--     may go below zero there ("owes the pool"). Purchases still use only members with free money > 0.
--     A deposit CORRECTION still may not push that member's free money below zero (009 rule kept).
--  4. approve_investment(request, expected_basis): no temp table, the approver confirms the total basis.
--  5. Rounding: positive totals -> floor per member; negative totals -> ceil per member (on the absolute
--     value). So the reserve leftover is ALWAYS >= 0. fund_summary reads income / profit / expenses from
--     the source tables and shows the reserve per kind.
--     Exact identity: total_fund = capital + late fees + income + profit - expenses + other reserve.
--     (The rounding reserve is NOT added again: it is the part of those same events that went to the
--     reserve instead of to members.)
--  6. approve_sale waits for pending costs/expenses of that plot; expenses on SOLD plots are allowed.
--  7. profiles: joined_on frozen once the member has ledger rows; 'exited' only via finalize_transfer (6D).
--  8. Ready for 6D: contributions (and shares) are summed per member over ALL participation rows.
--  9. post_allocation refuses NULL / negative weights; dates must lie between the samiti start and
--     today (Dhaka) + 3 days; an income reversal is FULL and ONCE and mirrors the original rows exactly;
--     rejecting a purchase also rejects its cost items; service_role cannot call any of our functions.
-- 10. Expense reversal: a new negative expense row (once, full amount), approved by a second admin,
--     posts the exact opposite of the original allocation rows. Never blocked by cash or free checks.
-- =====================================================================

-- ---------- 0) Settings: samiti start date ----------
insert into public.app_settings (key, value) values ('samiti_start', '"2020-01-01"')
on conflict (key) do nothing;

-- ---------- 1) Columns ----------
alter table public.allocations add column if not exists weight     numeric;
alter table public.allocations add column if not exists weight_sum numeric;
comment on column public.allocations.weight is
  'Weight of this member (contribution, equity or shares) when the amount was split. NULL = remainder row, or a legacy row written before migration 010.';

alter table public.investment_participation add column if not exists free_at_purchase numeric(14, 2);
comment on column public.investment_participation.free_at_purchase is
  'The member''s free money when the purchase was approved (NULL for rows written before migration 010).';

alter table public.expenses add column if not exists reverses_expense_id uuid references public.expenses (id);
create unique index if not exists expenses_reversed_once on public.expenses (reverses_expense_id) where reverses_expense_id is not null;
create unique index if not exists investment_income_reversed_once on public.investment_income (reverses_income_id) where reverses_income_id is not null;

do $$
declare c record;
begin
  -- expenses: the old "amount > 0" check becomes "positive, or a negative reversal that names the original"
  for c in select conname from pg_constraint
            where conrelid = 'public.expenses'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%amount > %(0)%'
  loop
    execute format('alter table public.expenses drop constraint %I', c.conname);
  end loop;
end $$;
do $$ begin
  alter table public.expenses add constraint expenses_sign
    check (amount <> 0 and ((amount > 0) = (reverses_expense_id is null)));
exception when duplicate_object then null; end $$;

alter table public.money_requests add column if not exists reverses_expense_id uuid references public.expenses (id);
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.money_requests'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%investment_cost%'
              and conname <> 'money_requests_kind_ck'
  loop
    execute format('alter table public.money_requests drop constraint %I', c.conname);
  end loop;
end $$;
do $$ begin
  alter table public.money_requests add constraint money_requests_kind_ck
    check (kind in ('purchase', 'investment_cost', 'sale', 'income', 'expense', 'expense_reversal'));
exception when duplicate_object then null; end $$;

-- member_ledger: add 'expense_reversal' (always positive)
alter table public.member_ledger drop constraint if exists member_ledger_ck_kind;
alter table public.member_ledger drop constraint if exists member_ledger_ck_positive;
alter table public.member_ledger add constraint member_ledger_ck_kind check (kind in (
  'capital_deposit', 'capital_transfer_in', 'capital_transfer_out',
  'profit', 'loss', 'income', 'income_reversal', 'expense', 'expense_reversal',
  'result_transfer_in', 'result_transfer_out'));
alter table public.member_ledger add constraint member_ledger_ck_positive
  check (kind not in ('capital_transfer_in', 'profit', 'income', 'expense_reversal', 'result_transfer_in') or amount > 0);

-- ---------- 2) Guards ----------
-- Profiles: joined_on frozen once there is money on the ledger (every role); 'exited' only via 6D.
create or replace function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.joined_on is distinct from old.joined_on
     and exists (select 1 from public.member_ledger where member_id = old.id) then
    raise exception 'The joining date cannot change after the member has money in the books.';
  end if;
  if new.status = 'exited' and old.status <> 'exited' and auth.uid() is not null
     and coalesce(current_setting('fd.transfer', true), '') <> 'on' then
    raise exception 'A member can only leave through a completed share transfer (coming later).';
  end if;

  if auth.uid() is null then          -- SQL Editor / service use: allowed (used to create the first super admin)
    return new;
  end if;
  new.member_no := old.member_no;
  new.id := old.id;

  if not public.is_admin() then
    new.role        := old.role;
    new.status      := old.status;
    new.joined_on   := old.joined_on;
    new.review_note := old.review_note;
    return new;
  end if;

  if old.id = auth.uid() then
    new.role      := old.role;
    new.status    := old.status;
    new.joined_on := old.joined_on;
  end if;

  if not public.is_super_admin() then
    new.role      := old.role;
    new.joined_on := old.joined_on;
    if old.role in ('admin', 'super_admin') then
      new.status := old.status;
    end if;
    if new.status is distinct from old.status
       and not (old.status = 'active' and new.status = 'suspended') then
      raise exception 'Only the super admin can make this status change.';
    end if;
    if new.review_note is distinct from old.review_note and old.status <> 'pending' then
      raise exception 'Admins can only write a review note for a pending member.';
    end if;
  end if;

  if new.status = 'active' and old.status <> 'active' and not public.is_super_admin() then
    raise exception 'Only the super admin can activate a member.';
  end if;
  return new;
end $$;

-- ---------- 3) Helpers ----------
create or replace function public.check_money_date(p_date date, p_what text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_start date := coalesce((select (value #>> '{}')::date from public.app_settings where key = 'samiti_start'), date '2020-01-01');
  v_max   date := (now() at time zone 'Asia/Dhaka')::date + 3;
begin
  if p_date is null or p_date < v_start or p_date > v_max then
    raise exception 'The % must be between % and %.', p_what, v_start, v_max;
  end if;
end $$;

-- Only for deposit corrections: this member's free money may not go below zero.
create or replace function public.assert_member_free(p_member uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  select b.member_no, b.free into r from public.member_balances_internal() b where b.member_id = p_member;
  if found and r.free < 0 then
    raise exception 'Member No. % would have % of free money (below zero): that money is already in investments. Nothing was saved.', r.member_no, r.free;
  end if;
end $$;

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
  if new.amount < 0 and new.kind <> 'late_fee' then
    perform public.assert_member_free(new.member_id);
  end if;
  return null;
end $$;

drop function if exists public.assert_free_nonnegative();

create or replace function public.fund_totals_internal()
returns table (capital numeric, late_fees numeric, reserve numeric, investment_income numeric,
               realized_profit numeric, expenses numeric, member_equity numeric,
               total_fund numeric, invested numeric, cash_available numeric)
language sql stable security definer set search_path = '' as $$
  with
  b as (select coalesce(sum(capital), 0) as cap, coalesce(sum(equity), 0) as eq
          from public.member_balances_internal()),
  l as (select
          coalesce(sum(amount) filter (where kind in ('income', 'income_reversal')), 0)   as inc,
          coalesce(sum(amount) filter (where kind in ('profit', 'loss')), 0)              as prof,
          coalesce(-sum(amount) filter (where kind in ('expense', 'expense_reversal')), 0) as exp
        from public.member_ledger),
  r as (select coalesce(sum(amount), 0) as total,
               coalesce(sum(amount) filter (where kind = 'late_fee'), 0) as lf
        from public.fund_reserve),
  i as (select coalesce(sum(cost + capitalized_costs), 0) as inv from public.investments where status = 'held')
  select b.cap, r.lf, r.total, l.inc, l.prof, l.exp, b.eq,
         b.eq + r.total, i.inv, b.eq + r.total - i.inv
  from b, l, r, i;
$$;

-- Who shares an investment's results: every member whose contributions (all reasons) add up to > 0.
create or replace function public.investment_sharers(p_investment uuid)
returns table (member_id uuid, member_no integer, contribution numeric, shares numeric)
language sql stable security definer set search_path = '' as $$
  select p.member_id, pr.member_no, sum(p.contribution_delta), sum(p.shares_at_purchase)::numeric
    from public.investment_participation p join public.profiles pr on pr.id = p.member_id
   where p.investment_id = p_investment
   group by p.member_id, pr.member_no
  having sum(p.contribution_delta) > 0
   order by pr.member_no;
$$;

-- ---------- 4) Splitting ----------
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
  v_x    numeric;
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
  if exists (select 1 from unnest(p_weights) w where w is null or w < 0) then
    raise exception 'Cannot split: a weight is missing or negative.';
  end if;
  select sum(w) into v_sum from unnest(p_weights) w;
  if v_sum is null or v_sum <= 0 then
    raise exception 'Cannot split: the total weight is zero (nobody has a share).';
  end if;

  perform set_config('fd.posting', 'on', true);
  for i in 1 .. array_length(p_members, 1) loop
    -- whole cents with EXACT integer division: floor for a positive total, ceil for a negative one,
    -- so the reserve leftover is always >= 0
    v_x := v_abs * 100 * p_weights[i];
    v_amt := (div(v_x, v_sum) + case when p_total < 0 and mod(v_x, v_sum) > 0 then 1 else 0 end) / 100;
    v_used := v_used + v_amt;
    insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total, weight, weight_sum, created_at)
    values (p_event_type, p_event_id, p_basis, p_members[i], v_sign * v_amt, p_total, p_weights[i], v_sum, clock_timestamp())
    returning id into v_aid;
    if p_basis = 'capital' and v_amt <> 0 then
      insert into public.member_ledger (member_id, kind, amount, source_type, source_id, allocation_id, created_at)
      values (p_members[i], case when v_sign > 0 then p_kind_pos else p_kind_neg end,
              v_sign * v_amt, p_source_type, p_event_id, v_aid, clock_timestamp());
    end if;
  end loop;

  v_rem := p_total - v_sign * v_used;                              -- what the members did not get / pay
  insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total, weight, weight_sum, created_at)
  values (p_event_type, p_event_id, p_basis, null, v_rem, p_total, null, v_sum, clock_timestamp())
  returning id into v_aid;
  if p_basis = 'capital' and v_rem <> 0 then
    insert into public.fund_reserve (kind, amount, source_type, source_id, allocation_id, created_at)
    values ('remainder', v_rem, 'allocation', p_event_id, v_aid, clock_timestamp());
  end if;
  perform set_config('fd.posting', 'off', true);
end $$;

-- The exact opposite of an earlier allocation (all bases), posted for the capital basis.
create or replace function public.mirror_allocation(
  p_event_type text, p_original uuid, p_new uuid, p_kind_pos text, p_kind_neg text, p_source_type text)
returns void
language plpgsql security definer set search_path = '' as $$
declare a record; v_aid bigint;
begin
  if not exists (select 1 from public.allocations where event_type = p_event_type and event_id = p_original) then
    raise exception 'The original entry has no allocation to reverse.';
  end if;
  perform set_config('fd.posting', 'on', true);
  for a in select * from public.allocations where event_type = p_event_type and event_id = p_original order by id loop
    insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total, weight, weight_sum, created_at)
    values (p_event_type, p_new, a.basis, a.member_id, -a.amount, -a.event_total, a.weight, a.weight_sum, clock_timestamp())
    returning id into v_aid;
    if a.basis = 'capital' and a.amount <> 0 then
      if a.member_id is null then
        insert into public.fund_reserve (kind, amount, source_type, source_id, allocation_id, created_at)
        values ('remainder', -a.amount, 'allocation', p_new, v_aid, clock_timestamp());
      else
        insert into public.member_ledger (member_id, kind, amount, source_type, source_id, allocation_id, created_at)
        values (a.member_id, case when -a.amount > 0 then p_kind_pos else p_kind_neg end, -a.amount,
                p_source_type, p_new, v_aid, clock_timestamp());
      end if;
    end if;
  end loop;
  perform set_config('fd.posting', 'off', true);
end $$;

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
    select array_agg(s.member_id order by s.member_no), array_agg(s.contribution order by s.member_no)
      into v_members, v_weights
      from public.investment_sharers(e.investment_id) s;
  end if;
  perform public.post_allocation('expense', e.id, -e.amount, v_members, v_weights, 'expense_reversal', 'expense', 'expense', 'capital');
end $$;

-- ---------- 5) RPCs ----------
create or replace function public.propose_investment(
  p_title text, p_kind text, p_purchase_date date, p_cost numeric, p_description text default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform public.take_fund_lock();
  perform public.require_admin();
  if nullif(btrim(coalesce(p_title, '')), '') is null then raise exception 'Give the investment a name.'; end if;
  if p_kind is null or p_kind not in ('land', 'shop', 'other') then raise exception 'Choose land, shop or other.'; end if;
  perform public.check_money_date(p_purchase_date, 'purchase date');
  if p_cost is null or p_cost <= 0 or p_cost <> round(p_cost, 2) or p_cost > 9999999999.99 then
    raise exception 'The cost must be more than 0, with at most 2 decimals.';
  end if;
  return public.new_request('purchase', p_title, p_kind, p_cost, p_purchase_date, p_description,
                            null, null, null, null, null, null);
end $$;

drop function if exists public.approve_investment(uuid);
create or replace function public.approve_investment(p_request uuid, p_expected_basis numeric) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  r       public.money_requests;
  v_uid   uuid;
  v_cap   numeric;
  v_basis numeric;
  v_free  numeric;
  v_inv   uuid;
  v_share numeric;
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
  if p_expected_basis is distinct from v_basis then
    raise exception 'The total cost is now % (you confirmed %). Check it and approve again.', v_basis, p_expected_basis;
  end if;

  -- who takes part: active NOW, joined on or before the purchase date, with free money > 0
  select coalesce(sum(b.free), 0) into v_free
    from public.member_balances_internal() b
   where b.status = 'active' and b.joined_on is not null and b.joined_on <= r.event_date and b.free > 0;
  if v_free < v_basis then
    raise exception 'Not enough free money: this purchase needs %, the members who can take part have %.', v_basis, v_free;
  end if;

  perform set_config('fd.posting', 'on', true);
  insert into public.investments (title, kind, description, purchase_date, cost, capitalized_costs, status,
                                  created_by, approved_by, created_at)
  values (r.title, r.investment_kind, r.description, r.event_date, r.amount, v_cap, 'held',
          r.proposed_by, v_uid, clock_timestamp())
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
     where m.status = 'active' and m.joined_on is not null and m.joined_on <= r.event_date and m.free > 0
  ),
  k as (select (v_basis * 100 - sum(fl))::bigint as leftover from b),
  x as (select b.*, row_number() over (order by b.rest desc, b.member_no) as rn from b)
  select v_inv, x.member_id, (x.fl + case when x.rn <= k.leftover then 1 else 0 end) / 100.0,
         x.capital, floor(x.capital / v_share)::int, x.free, 'purchase', clock_timestamp()
    from x, k
   where x.fl + case when x.rn <= k.leftover then 1 else 0 end > 0;
  perform set_config('fd.posting', 'off', true);

  perform public.close_request(r.id, 'approved', v_inv, null);
  perform public.assert_cash_nonnegative();
  return v_inv;
end $$;

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
  perform public.check_money_date(p_date, 'cost date');
  if exists (select 1 from public.money_requests where id = p_target and kind = 'purchase' and status = 'pending') then
    return public.new_request('investment_cost', p_title, null, p_amount, p_date, p_description,
                              null, null, null, null, p_target, null);
  elsif exists (select 1 from public.investments where id = p_target) then
    return public.new_request('investment_cost', p_title, null, p_amount, p_date, p_description,
                              null, null, null, p_target, null, null);
  end if;
  raise exception 'Choose a purchase that is still waiting, or an existing investment.';
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

  perform set_config('fd.posting', 'on', true);
  insert into public.expenses (title, amount, spent_on, description, investment_id, created_by, approved_by, created_at)
  values (r.title, r.amount, r.event_date, r.description, r.investment_id, r.proposed_by, v_uid, clock_timestamp())
  returning id into v_exp;
  perform set_config('fd.posting', 'off', true);
  perform public.charge_expense_internal(v_exp);

  perform public.close_request(r.id, 'approved', v_exp, null);
  perform public.assert_cash_nonnegative();          -- members may now owe the pool; cash may not go negative
  return v_exp;
end $$;

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
  perform public.check_money_date(p_sale_date, 'sale date');
  if p_sale_date < i.purchase_date then
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

  if exists (select 1 from public.money_requests
              where status = 'pending' and investment_id = r.investment_id and kind in ('investment_cost', 'expense')) then
    raise exception 'Approve or reject the waiting costs / expenses of this investment first.';
  end if;
  select * into i from public.investments where id = r.investment_id for update;
  if i.status <> 'held' then raise exception 'This investment is already sold.'; end if;
  v_profit := r.amount - (i.cost + i.capitalized_costs);

  perform set_config('fd.posting', 'on', true);
  update public.investments
     set status = 'sold', sale_date = r.event_date, sale_amount = r.amount,
         sale_proposed_by = r.proposed_by, sale_approved_by = v_uid
   where id = i.id;
  perform set_config('fd.posting', 'off', true);

  select array_agg(s.member_id order by s.member_no), array_agg(s.contribution order by s.member_no),
         array_agg(s.shares order by s.member_no)
    into v_members, v_contrib, v_shares
    from public.investment_sharers(i.id) s;

  perform public.post_allocation('sale', i.id, v_profit, v_members, v_contrib, 'profit', 'loss', 'investment', 'capital');
  if (select coalesce(sum(s), 0) from unnest(v_shares) s) > 0 then
    perform public.post_allocation('sale', i.id, v_profit, v_members, v_shares, 'profit', 'loss', 'investment', 'shares');
  end if;

  perform public.close_request(r.id, 'approved', i.id, null);
  perform public.assert_cash_nonnegative();
  return v_profit;
end $$;

create or replace function public.record_income(
  p_investment uuid, p_amount numeric, p_received_on date, p_note text default null, p_reverses uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare o record;
begin
  perform public.take_fund_lock();
  perform public.require_admin();
  if not exists (select 1 from public.investments where id = p_investment) then raise exception 'Investment not found.'; end if;
  perform public.check_money_date(p_received_on, 'date');
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
    if p_amount <> -o.amount then
      raise exception 'A reversal undoes the whole entry: the amount must be %.', -o.amount;
    end if;
    if exists (select 1 from public.investment_income where reverses_income_id = p_reverses)
       or exists (select 1 from public.money_requests where kind = 'income' and reverses_income_id = p_reverses and status = 'pending') then
      raise exception 'This income entry is already reversed (or a reversal is waiting).';
    end if;
  end if;
  return public.new_request('income', null, null, p_amount, p_received_on, p_note,
                            null, null, null, p_investment, null, p_reverses);
end $$;

create or replace function public.approve_income(p_request uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  r         public.money_requests;
  v_uid     uuid;
  v_inc     uuid;
  v_members uuid[];
  v_contrib numeric[];
begin
  perform public.take_fund_lock();
  v_uid := public.require_admin();
  r := public.pending_request(p_request, 'income');
  if r.reverses_income_id is not null
     and exists (select 1 from public.investment_income where reverses_income_id = r.reverses_income_id) then
    raise exception 'This income entry is already reversed.';
  end if;

  perform set_config('fd.posting', 'on', true);
  insert into public.investment_income (investment_id, amount, received_on, note, created_by, approved_by,
                                        reverses_income_id, created_at)
  values (r.investment_id, r.amount, r.event_date, r.description, r.proposed_by, v_uid,
          r.reverses_income_id, clock_timestamp())
  returning id into v_inc;
  perform set_config('fd.posting', 'off', true);

  if r.reverses_income_id is null then
    select array_agg(s.member_id order by s.member_no), array_agg(s.contribution order by s.member_no)
      into v_members, v_contrib
      from public.investment_sharers(r.investment_id) s;
    perform public.post_allocation('income', v_inc, r.amount, v_members, v_contrib, 'income', 'income_reversal', 'income', 'capital');
  else
    perform public.mirror_allocation('income', r.reverses_income_id, v_inc, 'income', 'income_reversal', 'income');
  end if;

  perform public.close_request(r.id, 'approved', v_inc, null);
  perform public.assert_cash_nonnegative();
  return v_inc;
end $$;

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
  perform public.check_money_date(p_spent_on, 'expense date');
  if p_investment is not null and not exists (select 1 from public.investments where id = p_investment) then
    raise exception 'Investment not found.';
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

  perform set_config('fd.posting', 'on', true);
  insert into public.expenses (category_id, title, amount, spent_on, description, receipt_path, spent_by,
                               investment_id, created_by, approved_by, created_at)
  values (r.category_id, r.title, r.amount, r.event_date, r.description, r.receipt_path, r.spent_by,
          r.investment_id, r.proposed_by, v_uid, clock_timestamp())
  returning id into v_exp;
  perform set_config('fd.posting', 'off', true);
  perform public.charge_expense_internal(v_exp);

  perform public.close_request(r.id, 'approved', v_exp, null);
  perform public.assert_cash_nonnegative();          -- members may now owe the pool; cash may not go negative
  return v_exp;
end $$;

-- Expense reversal (once, full amount); never blocked by cash or free checks (it gives money back).
create or replace function public.propose_expense_reversal(p_expense uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare e record; v_id uuid;
begin
  perform public.take_fund_lock();
  perform public.require_admin();
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason for the reversal.'; end if;
  select * into e from public.expenses where id = p_expense;
  if not found or e.status <> 'approved' or e.reverses_expense_id is not null then
    raise exception 'Choose an approved expense to reverse.';
  end if;
  if exists (select 1 from public.expenses where reverses_expense_id = p_expense)
     or exists (select 1 from public.money_requests where kind = 'expense_reversal' and reverses_expense_id = p_expense and status = 'pending') then
    raise exception 'This expense is already reversed (or a reversal is waiting).';
  end if;
  v_id := public.new_request('expense_reversal', 'Reversal: ' || e.title, null, e.amount,
                             (now() at time zone 'Asia/Dhaka')::date, p_reason,
                             e.category_id, null, null, e.investment_id, null, null);
  perform set_config('fd.posting', 'on', true);
  update public.money_requests set reverses_expense_id = p_expense where id = v_id and status = 'pending';
  perform set_config('fd.posting', 'off', true);
  return v_id;
end $$;

create or replace function public.approve_expense_reversal(p_request uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.money_requests; v_uid uuid; e record; v_exp uuid;
begin
  perform public.take_fund_lock();
  v_uid := public.require_admin();
  r := public.pending_request(p_request, 'expense_reversal');
  select * into e from public.expenses where id = r.reverses_expense_id;
  if not found then raise exception 'The original expense was not found.'; end if;
  if exists (select 1 from public.expenses where reverses_expense_id = e.id) then
    raise exception 'This expense is already reversed.';
  end if;

  perform set_config('fd.posting', 'on', true);
  insert into public.expenses (category_id, title, amount, spent_on, description, investment_id,
                               reverses_expense_id, created_by, approved_by, created_at)
  values (e.category_id, r.title, -e.amount, r.event_date, r.description, e.investment_id,
          e.id, r.proposed_by, v_uid, clock_timestamp())
  returning id into v_exp;
  perform set_config('fd.posting', 'off', true);
  perform public.mirror_allocation('expense', e.id, v_exp, 'expense_reversal', 'expense', 'expense');

  perform public.close_request(r.id, 'approved', v_exp, null);
  return v_exp;
end $$;

-- money_requests_guard freezes everything except the decision; the reversal link is written while
-- the request is still pending, so allow that one column on a pending -> pending update.
create or replace function public.money_requests_guard() returns trigger
language plpgsql set search_path = '' as $$
declare s text; db uuid; da timestamptz; rr text; ri uuid; re uuid;
begin
  if coalesce(current_setting('fd.posting', true), '') <> 'on' then
    raise exception 'Requests can only change through the approve / reject functions.';
  end if;
  if old.status = 'pending' and new.status = 'pending' then
    if old.kind <> 'expense_reversal' or old.reverses_expense_id is not null then
      raise exception 'A waiting request can not be edited.';
    end if;
    re := new.reverses_expense_id;
    new := old;
    new.reverses_expense_id := re;
    return new;
  end if;
  if not (   (old.status = 'pending' and new.status in ('approved', 'rejected'))
          or (old.status = 'approved' and new.status = 'rejected' and old.kind = 'investment_cost'
              and old.purchase_request_id is not null
              and coalesce(current_setting('fd.cascade', true), '') = 'on')) then
    raise exception 'A decided request can never change.';
  end if;
  s := new.status; db := new.decided_by; da := new.decided_at; rr := new.reject_reason; ri := new.result_id;
  new := old;
  new.status := s; new.decided_by := db; new.decided_at := da; new.reject_reason := rr; new.result_id := ri;
  return new;
end $$;

-- Reject: a rejected purchase takes its cost items (waiting or approved) with it.
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
  if r.kind = 'purchase' then
    perform set_config('fd.posting', 'on', true);
    perform set_config('fd.cascade', 'on', true);
    update public.money_requests
       set status = 'rejected', decided_by = auth.uid(), decided_at = clock_timestamp(),
           reject_reason = 'The purchase was rejected.'
     where kind = 'investment_cost' and purchase_request_id = r.id and status in ('pending', 'approved');
    perform set_config('fd.cascade', 'off', true);
    perform set_config('fd.posting', 'off', true);
  end if;
end $$;

-- ---------- 6) fund_summary: source-table totals and the reserve per kind ----------
drop function if exists public.fund_summary();
create function public.fund_summary()
returns table (capital numeric, late_fees numeric, investment_income numeric, realized_profit numeric,
               expenses numeric, total_fund numeric, invested numeric, cash_available numeric,
               member_count integer, monthly_amount numeric, reserve numeric,
               reserve_late_fees numeric, reserve_rounding numeric, reserve_other numeric)
language sql stable security definer set search_path = '' as $$
  select t.capital,
         t.late_fees,
         (select coalesce(sum(amount), 0) from public.investment_income),
         (select coalesce(sum(sale_amount - (cost + capitalized_costs)), 0) from public.investments where status = 'sold'),
         (select coalesce(sum(amount), 0) from public.expenses where status = 'approved'),
         t.total_fund, t.invested, t.cash_available,
         (select count(*)::int from public.profiles where status = 'active'),
         coalesce((select (value #>> '{}')::numeric from public.app_settings where key = 'monthly_amount'), 3000),
         t.reserve,
         (select coalesce(sum(amount), 0) from public.fund_reserve where kind = 'late_fee'),
         (select coalesce(sum(amount), 0) from public.fund_reserve where kind = 'remainder'),
         (select coalesce(sum(amount), 0) from public.fund_reserve where kind not in ('late_fee', 'remainder'))
  from public.fund_totals_internal() t
  where public.is_active_member();
$$;

-- ---------- 7) check_invariants(): 26 rules ----------
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
  select (select count(*) from public.investments where approved_by is null or approved_by = created_by)
       + (select count(*) from public.investments where status = 'sold' and (sale_approved_by is null or sale_approved_by = sale_proposed_by))
       + (select count(*) from public.expenses where approved_by is null or approved_by = created_by)
       + (select count(*) from public.investment_income where approved_by is null or approved_by = created_by)
       + (select count(*) from public.money_requests where status = 'approved' and (decided_by is null or decided_by = proposed_by))
       + (select count(*) from public.money_requests where status <> 'pending' and decided_by is null)
    into n;
  rule := 'two people per decision'; ok := n = 0;
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

  if raise_on_fail then
    for t in select * from public.check_invariants(false) c where not c.ok loop
      bad := bad || t.rule || ' [' || t.detail || ']; ';
    end loop;
    if bad <> '' then
      raise exception 'INVARIANT FAILED: %', bad;
    end if;
  end if;
end $$;

-- ---------- 8) Permissions: nothing for PUBLIC / anon / service_role; RPCs for authenticated ----------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig
             from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke all on function %s from public, anon, service_role', f.sig);
  end loop;
end $$;
alter default privileges for role postgres in schema public revoke execute on functions from service_role;

do $$
declare f record;
begin
  -- internal helpers: not callable by logged-in users either
  for f in select p.oid::regprocedure as sig
             from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('check_money_date', 'assert_member_free', 'fund_totals_internal', 'investment_sharers',
                                'post_allocation', 'mirror_allocation', 'charge_expense_internal', 'money_requests_guard',
                                'protect_profile_fields', 'post_deposit_to_ledger', 'fund_summary',
                                'propose_investment', 'approve_investment', 'add_investment_cost', 'approve_investment_cost',
                                'propose_sale', 'approve_sale', 'record_income', 'approve_income', 'propose_expense',
                                'approve_expense', 'propose_expense_reversal', 'approve_expense_reversal', 'reject_request',
                                'check_invariants')
  loop
    execute format('revoke all on function %s from authenticated', f.sig);
  end loop;
end $$;

grant execute on function public.fund_summary()                                                     to authenticated;
grant execute on function public.check_invariants(boolean)                                          to authenticated;
grant execute on function public.propose_investment(text, text, date, numeric, text)                to authenticated;
grant execute on function public.approve_investment(uuid, numeric)                                  to authenticated;
grant execute on function public.add_investment_cost(uuid, numeric, text, date, text)               to authenticated;
grant execute on function public.approve_investment_cost(uuid)                                      to authenticated;
grant execute on function public.propose_sale(uuid, numeric, date, text)                            to authenticated;
grant execute on function public.approve_sale(uuid)                                                 to authenticated;
grant execute on function public.record_income(uuid, numeric, date, text, uuid)                     to authenticated;
grant execute on function public.approve_income(uuid)                                               to authenticated;
grant execute on function public.propose_expense(text, numeric, date, integer, uuid, text, text, text) to authenticated;
grant execute on function public.approve_expense(uuid)                                              to authenticated;
grant execute on function public.propose_expense_reversal(uuid, text)                               to authenticated;
grant execute on function public.approve_expense_reversal(uuid)                                     to authenticated;
grant execute on function public.reject_request(uuid, text)                                         to authenticated;

-- ---------- 9) Prove it ----------
do $$
declare names text;
begin
  select string_agg(p.proname, ', ') into names
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('service_role', p.oid, 'execute'));
  if names is not null then
    raise exception 'anon / service_role can still execute: %', names;
  end if;
end $$;

select * from public.check_invariants(true);
