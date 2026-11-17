-- =====================================================================
-- 014_launch_hardening.sql  (run AFTER 011, 012 and 013: it replaces the import functions from 012)
--
-- 1) profiles.email follows auth.users.email only:
--    - protect_profile_fields keeps the old email unless the change comes from the SQL Editor
--      (or from the auth.users sync trigger below);
--    - a trigger copies every email change on auth.users to profiles;
--    - one account per email: unique index on lower(email);
--    - the import (map, confirm code, verify) joins on auth.users.email and needs a CONFIRMED email.
-- 2) Length limits on every free-text column; storage uploads only for pending / active members
--    (receipts: active only), with a cap on the number of files per member per bucket.
-- 3) Strict file paths: <owner uuid>/<8-64 letters, digits, _ or ->.<jpg|jpeg|png|webp|pdf>
--    (this is what the app already writes: <uuid>.<ext>, <32 hex>.<ext>, <slot>-<time>.<ext>).
-- 4) audit_log is append-only for every role; anon has no rights on any core table
--    (only SELECT on site_content, where RLS shows the 3 public front-page messages).
-- A self-check at the end stops the migration if something is not as described. Safe to run twice.
--
-- SUPER ADMIN BOOTSTRAP (new project): sign up on the website, CONFIRM the email, then run this in the
-- SQL Editor with your own email. It uses the auth.users id, so a profile row can never be the key:
--
--   update public.profiles p
--      set role = 'super_admin', status = 'active', joined_on = current_date
--     from auth.users u
--    where p.id = u.id and lower(u.email) = lower('YOUR-EMAIL-HERE') and u.email_confirmed_at is not null;
--
-- It must say "UPDATE 1". "UPDATE 0" = wrong email or the email is not confirmed yet.
-- =====================================================================

-- ---------- 0) Stop early on data that the new rules would reject ----------
do $$
declare n bigint;
begin
  select count(*) into n from (select lower(email) from public.profiles where email is not null
                                group by 1 having count(*) > 1) d;
  if n > 0 then
    raise exception 'STOP: % email address(es) are used by more than one profile. Fix them first, nothing was changed.', n;
  end if;
end $$;

-- ---------- 1) Email ----------
-- 1a) bring every profile in line with auth.users (the SQL Editor may do this)
update public.profiles p set email = u.email
  from auth.users u
 where u.id = p.id and p.email is distinct from u.email;

-- 1b) the guard: same as 010, plus the email rule at the top
create or replace function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- email: only the auth.users sync trigger or the SQL Editor (no JWT, not an API role) may change it
  if new.email is distinct from old.email
     and coalesce(current_setting('fd.email_sync', true), '') <> 'on'
     and not (coalesce(current_setting('request.jwt.claims', true), '') = ''
              and coalesce(current_setting('role', true), 'none') not in ('anon', 'authenticated', 'service_role')) then
    new.email := old.email;
  end if;

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

-- 1c) auth.users -> profiles: copy every email change (Supabase changes auth.users.email only after confirmation)
create or replace function public.sync_profile_email() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.email is distinct from old.email then
    perform set_config('fd.email_sync', 'on', true);
    update public.profiles set email = new.email where id = new.id;
    perform set_config('fd.email_sync', 'off', true);
  end if;
  return new;
end $$;
revoke all on function public.sync_profile_email() from public, anon, authenticated, service_role;

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row execute function public.sync_profile_email();

-- 1d) one profile per email (case-insensitive)
create unique index if not exists profiles_email_lower_uniq on public.profiles (lower(email));

-- 1e) the import joins on auth.users.email and needs a confirmed email
create or replace function public.import_confirm_code(p jsonb) returns text
language sql stable security definer set search_path = '' as $$
  select md5(coalesce((select string_agg((m ->> 'sr_no') || ':' || pr.id::text, ',' order by (m ->> 'sr_no')::int)
                         from jsonb_array_elements(p -> 'members') m
                         join auth.users u on lower(u.email) = lower(btrim(m ->> 'email')) and u.email_confirmed_at is not null
                         join public.profiles pr on pr.id = u.id), '')
             || '|' || md5(p::text));
$$;

create or replace function public.import_verify(p jsonb)
returns table (sr_no integer, sheet_name text, full_name text, member_no integer, status text,
               joined_on date, email_confirmed boolean, problem text)
language plpgsql security definer set search_path = '' as $$
declare v_bad integer;
begin
  perform public.require_sql_editor();
  return query
    select (m ->> 'sr_no')::int, m ->> 'sheet_name', pr.full_name, pr.member_no, pr.status::text, pr.joined_on,
           (u.email_confirmed_at is not null),
           case when u.id is null then 'NO ACCOUNT with this email'
                when u.email_confirmed_at is null then 'email not confirmed yet'
                when pr.id is null then 'NO PROFILE for this account'
                when pr.status <> 'active' then 'not active (run the prepare step)'
                when pr.joined_on is distinct from (p ->> 'joined_on')::date then 'joined_on is not ' || (p ->> 'joined_on')
                when pr.member_no <> (m ->> 'sr_no')::int then 'member_no is not the SR NO (run the prepare step)'
                else 'ok' end
      from jsonb_array_elements(p -> 'members') m
      left join auth.users u on lower(u.email) = lower(btrim(m ->> 'email'))
      left join public.profiles pr on pr.id = u.id
     order by 1;
  select count(*) into v_bad
    from jsonb_array_elements(p -> 'members') m
    left join auth.users u on lower(u.email) = lower(btrim(m ->> 'email'))
    left join public.profiles pr on pr.id = u.id
   where u.id is null or u.email_confirmed_at is null or pr.id is null
      or pr.status <> 'active' or pr.joined_on is distinct from (p ->> 'joined_on')::date
      or pr.member_no <> (m ->> 'sr_no')::int;
  return query select null::int, 'CONFIRM CODE'::text,
                      case when v_bad = 0 then public.import_confirm_code(p) else 'fix the problems above first' end,
                      null::int, null::text, null::date, null::boolean,
                      case when v_bad = 0 then 'check every name above, then use this code' else v_bad || ' problem(s)' end;
end $$;

-- import_apply: identical to 012 except the member map, which now joins on CONFIRMED auth.users emails
create or replace function public.import_apply(p jsonb) returns text[]
language plpgsql security definer set search_path = '' as $$
declare
  rep       text[] := '{}';
  v_list    text;
  v_batch   uuid;
  v_joined  date := (p ->> 'joined_on')::date;
  v_pdate   date := (p #>> '{purchase,date}')::date;
  v_cost    numeric := (p #>> '{purchase,cost}')::numeric;
  v_last    date;
  v_cap     numeric;
  v_inv     uuid;
  v_req     uuid;
  v_n       numeric;
  v_m       numeric;
  v_c       integer;
  r         record;
  e         jsonb := p -> 'expect';
begin
  -- the same gates as import_history, so a direct call is never a shortcut
  perform public.require_sql_editor();
  if coalesce(current_setting('fd.import', true), '') <> 'on' then
    raise exception 'IMPORT: call public.import_history(...) instead.';
  end if;
  if exists (select 1 from public.system_markers where key in ('import_done', 'go_live'))
     or exists (select 1 from public.import_batches) then
    raise exception 'The historical import was already done (or the site is live). It can never run again.';
  end if;

  ---- checks on the payload and on the database
  if (select count(*) from jsonb_array_elements(p -> 'members')) <> (e ->> 'members')::int then
    raise exception 'IMPORT: the member map has % rows, expected %.', jsonb_array_length(p -> 'members'), e ->> 'members';
  end if;
  create temp table fd_import_map (sr_no int primary key, email text, member_id uuid) on commit drop;
  insert into pg_temp.fd_import_map (sr_no, email)
  select (m ->> 'sr_no')::int, lower(btrim(m ->> 'email')) from jsonb_array_elements(p -> 'members') m;
  if exists (select 1 from pg_temp.fd_import_map where email is null or email = '') then
    raise exception 'IMPORT: some members have no email in the map (fill member_map.csv).';
  end if;
  if (select count(distinct email) from pg_temp.fd_import_map) <> (select count(*) from pg_temp.fd_import_map) then
    raise exception 'IMPORT: the same email appears twice in the map.';
  end if;
  update pg_temp.fd_import_map f set member_id = pr.id
    from auth.users u join public.profiles pr on pr.id = u.id
   where lower(u.email) = f.email and u.email_confirmed_at is not null;
  select string_agg(sr_no::text, ', ' order by sr_no) into v_list from pg_temp.fd_import_map where member_id is null;
  if v_list is not null then
    raise exception 'IMPORT: no account with a CONFIRMED email for SR NO %. Every member must sign up and confirm first.', v_list;
  end if;
  select string_agg(f.sr_no::text, ', ' order by f.sr_no) into v_list
    from pg_temp.fd_import_map f join public.profiles pr on pr.id = f.member_id
   where pr.status <> 'active' or pr.joined_on is distinct from v_joined or pr.member_no <> f.sr_no;
  if v_list is not null then
    raise exception 'IMPORT: SR NO % must be ACTIVE with joined_on = % and member_no = SR NO (run the prepare step first).', v_list, v_joined;
  end if;
  if exists (select 1 from public.member_ledger) or exists (select 1 from public.fund_reserve)
     or exists (select 1 from public.investments) or exists (select 1 from public.expenses)
     or exists (select 1 from public.investment_income) then
    raise exception 'IMPORT: the books are not empty. The import only runs on a fresh project.';
  end if;

  create temp table fd_import_rows (sr_no int, month date, kind text, amount numeric, note text) on commit drop;
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
  select max(month) into v_last from pg_temp.fd_import_rows;
  select string_agg(format('No. %s %s', pr.member_no, to_char(d.period_month, 'YYYY-MM')), ', ' order by pr.member_no, d.period_month)
    into v_list
    from public.deposits d join public.profiles pr on pr.id = d.member_id
   where d.status = 'pending' and d.period_month <= v_last;
  if v_list is not null then
    raise exception 'IMPORT: pending deposits exist for months the import covers (%). Reject them first.', v_list;
  end if;

  ---- the batch (with the SR -> member map, admins only)
  insert into public.import_batches (label, source_note, sr_map, created_at)
  values (coalesce(p ->> 'label', 'historical import'), p ->> 'source_note',
          (select jsonb_agg(jsonb_build_object('sr_no', sr_no, 'member_id', member_id) order by sr_no) from pg_temp.fd_import_map),
          clock_timestamp())
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

  ---- marker (set_at = the same moment the deposits were submitted: now() of this transaction)
  insert into public.system_markers (key, value)
  values ('import_done', jsonb_build_object('batch', v_batch, 'label', p ->> 'label', 'at', clock_timestamp()));

  ---- report: per member, per month, purchase, totals
  for r in select f.sr_no, b.capital, b.free,
                  (select count(*) from public.deposits d where d.member_id = f.member_id and d.import_batch_id = v_batch) as n_dep,
                  ip.contribution_delta as contrib, ip.free_at_purchase as free_then
             from pg_temp.fd_import_map f
             join public.member_balances_internal() b on b.member_id = f.member_id
             left join public.investment_participation ip on ip.investment_id = v_inv and ip.member_id = f.member_id
            order by f.sr_no loop
    rep := rep || format('member|SR %s|capital %s, %s deposits, free money at purchase %s, land contribution %s, free now %s',
                         r.sr_no, r.capital, r.n_dep, r.free_then, r.contrib, r.free);
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

  perform public.check_invariants(true);
  select count(*) into v_c from public.check_invariants(false);
  rep := rep || format('check|check_invariants|all %s rules pass', v_c);
  return rep;
end $$;

-- ---------- 2) Length limits on free text ----------
do $$
declare
  r record;
  lim constant text[][] := array[
    -- table, column, max characters
    ['profiles', 'email', '320'], ['profiles', 'full_name', '200'], ['profiles', 'full_name_bn', '200'],
    ['profiles', 'father_name', '200'], ['profiles', 'mother_name', '200'], ['profiles', 'phone', '30'],
    ['profiles', 'address_present', '500'], ['profiles', 'address_permanent', '500'],
    ['nominees', 'name', '200'], ['nominees', 'relation', '100'], ['nominees', 'phone', '30'],
    ['nominees', 'address', '500'], ['nominees', 'nid_number', '30'],
    ['notices', 'title', '200'], ['notices', 'body', '5000'],
    ['policies', 'title', '200'], ['policies', 'body', '5000'],
    ['site_content', 'key', '64'], ['site_content', 'body_en', '2000'], ['site_content', 'body_bn', '2000'],
    ['deposits', 'note', '1000'], ['deposits', 'transaction_ref', '100'], ['deposits', 'reject_reason', '1000'],
    ['expenses', 'title', '200'], ['expenses', 'description', '1000'], ['expenses', 'spent_by', '200'],
    ['expenses', 'reversed_reason', '1000'],
    ['investments', 'title', '200'], ['investments', 'description', '2000'], ['investments', 'notes', '1000'],
    ['investment_income', 'note', '1000'],
    ['money_requests', 'title', '200'], ['money_requests', 'description', '2000'], ['money_requests', 'spent_by', '200'],
    ['money_requests', 'reject_reason', '1000'],
    ['expense_categories', 'name', '100'],
    ['import_batches', 'label', '200'], ['import_batches', 'source_note', '2000']];
  i int;
  v_bad text := '';
  n bigint;
begin
  for i in 1 .. array_length(lim, 1) loop
    execute format('select count(*) from public.%I where char_length(%I) > %s', lim[i][1], lim[i][2], lim[i][3]) into n;
    if n > 0 then v_bad := v_bad || format('%s.%s (%s rows over %s) ', lim[i][1], lim[i][2], n, lim[i][3]); end if;
  end loop;
  if v_bad <> '' then
    raise exception 'STOP: text longer than the new limit in: %. Shorten it first, nothing was changed.', v_bad;
  end if;
  for i in 1 .. array_length(lim, 1) loop
    execute format('alter table public.%I drop constraint if exists %I', lim[i][1], lim[i][1] || '_' || lim[i][2] || '_len');
    execute format('alter table public.%I add constraint %I check (char_length(%I) <= %s)',
                   lim[i][1], lim[i][1] || '_' || lim[i][2] || '_len', lim[i][2], lim[i][3]);
  end loop;
end $$;

-- ---------- 3) Strict file paths ----------
-- <owner uuid>/<8-64 of A-Z a-z 0-9 _ -> . jpg|jpeg|png|webp|pdf   (owner = the member, or the proposer)
do $$
declare v_bad text := ''; n bigint;
begin
  select count(*) into n from public.profiles
   where photo_path is not null and photo_path !~ ('^' || id::text || '/[A-Za-z0-9_-]{8,64}[.](jpg|jpeg|png|webp|pdf)$');
  if n > 0 then v_bad := v_bad || 'profiles.photo_path: ' || n || ' '; end if;
  select count(*) into n from public.member_documents
   where storage_path !~ ('^' || member_id::text || '/[A-Za-z0-9_-]{8,64}[.](jpg|jpeg|png|webp|pdf)$');
  if n > 0 then v_bad := v_bad || 'member_documents.storage_path: ' || n || ' '; end if;
  select count(*) into n from public.deposits
   where receipt_path is not null and receipt_path !~ ('^' || member_id::text || '/[A-Za-z0-9_-]{8,64}[.](jpg|jpeg|png|webp|pdf)$');
  if n > 0 then v_bad := v_bad || 'deposits.receipt_path: ' || n || ' '; end if;
  select count(*) into n from public.money_requests
   where receipt_path is not null and receipt_path !~ ('^' || proposed_by::text || '/[A-Za-z0-9_-]{8,64}[.](jpg|jpeg|png|webp|pdf)$');
  if n > 0 then v_bad := v_bad || 'money_requests.receipt_path: ' || n || ' '; end if;
  select count(*) into n from public.expenses
   where receipt_path is not null and receipt_path !~ ('^' || coalesce(created_by::text, '-') || '/[A-Za-z0-9_-]{8,64}[.](jpg|jpeg|png|webp|pdf)$');
  if n > 0 then v_bad := v_bad || 'expenses.receipt_path: ' || n || ' '; end if;
  if v_bad <> '' then
    raise exception 'STOP: file paths that do not match the strict pattern: %. Nothing was changed.', v_bad;
  end if;
end $$;

alter table public.profiles drop constraint if exists profiles_photo_path_strict;
alter table public.profiles add constraint profiles_photo_path_strict
  check (photo_path is null or photo_path ~ ('^' || id::text || '/[A-Za-z0-9_-]{8,64}[.](jpg|jpeg|png|webp|pdf)$'));
alter table public.member_documents drop constraint if exists member_documents_path_strict;
alter table public.member_documents add constraint member_documents_path_strict
  check (storage_path ~ ('^' || member_id::text || '/[A-Za-z0-9_-]{8,64}[.](jpg|jpeg|png|webp|pdf)$'));
alter table public.deposits drop constraint if exists deposits_receipt_path_strict;
alter table public.deposits add constraint deposits_receipt_path_strict
  check (receipt_path is null or receipt_path ~ ('^' || member_id::text || '/[A-Za-z0-9_-]{8,64}[.](jpg|jpeg|png|webp|pdf)$'));
alter table public.money_requests drop constraint if exists money_requests_receipt_path_strict;
alter table public.money_requests add constraint money_requests_receipt_path_strict
  check (receipt_path is null or receipt_path ~ ('^' || proposed_by::text || '/[A-Za-z0-9_-]{8,64}[.](jpg|jpeg|png|webp|pdf)$'));
alter table public.expenses drop constraint if exists expenses_receipt_path_strict;
alter table public.expenses add constraint expenses_receipt_path_strict
  check (receipt_path is null or receipt_path ~ ('^' || coalesce(created_by::text, '-') || '/[A-Za-z0-9_-]{8,64}[.](jpg|jpeg|png|webp|pdf)$'));

-- ---------- 4) Storage uploads ----------
-- One check for every upload policy: who may upload, where, which name, and how many files.
--   * the uploader is a pending or active member (receipts: active only);
--   * own folder <uid>/..., or an (active) admin uploading into an existing member's folder;
--   * strict file name; at most 20 avatars, 40 documents, 500 receipts per member folder.
-- p_replace = true for the avatars UPDATE policy (an existing file is overwritten, no new file counted).
create or replace function public.storage_upload_ok(p_bucket text, p_name text, p_replace boolean default false)
returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid    uuid := auth.uid();
  v_status text;
  v_folder text := split_part(coalesce(p_name, ''), '/', 1);
  v_cap    integer := case p_bucket when 'avatars' then 20 when 'documents' then 40 when 'receipts' then 500 end;
  v_n      bigint;
begin
  if v_uid is null or v_cap is null then return false; end if;
  select status::text into v_status from public.profiles where id = v_uid;
  if v_status is null then return false; end if;
  if p_bucket = 'receipts' and v_status <> 'active' then return false; end if;
  if v_status not in ('pending', 'active') then return false; end if;

  if coalesce(p_name, '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[A-Za-z0-9_-]{8,64}[.](jpg|jpeg|png|webp|pdf)$' then
    return false;
  end if;
  if v_folder <> v_uid::text then
    if not public.is_admin() then return false; end if;
    if not exists (select 1 from public.profiles where id = v_folder::uuid) then return false; end if;
  end if;

  if not p_replace then
    select count(*) into v_n from storage.objects o
     where o.bucket_id = p_bucket and split_part(o.name, '/', 1) = v_folder;
    if v_n >= v_cap then return false; end if;
  end if;
  return true;
end $$;
revoke all on function public.storage_upload_ok(text, text, boolean) from public, anon, service_role;
grant execute on function public.storage_upload_ok(text, text, boolean) to authenticated;   -- used by storage RLS policies

drop policy if exists "documents upload" on storage.objects;
create policy "documents upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and public.storage_upload_ok(bucket_id, name));
drop policy if exists "receipts upload" on storage.objects;
create policy "receipts upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts' and public.storage_upload_ok(bucket_id, name));
drop policy if exists "avatars upload" on storage.objects;
create policy "avatars upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and public.storage_upload_ok(bucket_id, name));
drop policy if exists "avatars replace" on storage.objects;
create policy "avatars replace" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and public.storage_upload_ok(bucket_id, name, true))
  with check (bucket_id = 'avatars' and public.storage_upload_ok(bucket_id, name, true));

-- ---------- 5) audit_log: append-only for every role ----------
create or replace function public.block_audit_changes() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'audit_log is append-only: rows can never be changed or deleted.' using errcode = '42501';
end $$;
revoke all on function public.block_audit_changes() from public, anon, authenticated, service_role;

drop trigger if exists audit_log_no_update_delete on public.audit_log;
create trigger audit_log_no_update_delete before update or delete on public.audit_log
  for each row execute function public.block_audit_changes();
drop trigger if exists audit_log_no_truncate on public.audit_log;
create trigger audit_log_no_truncate before truncate on public.audit_log
  for each statement execute function public.block_audit_changes();

revoke insert, update, delete, truncate, trigger, references on public.audit_log
  from public, anon, authenticated, service_role;

-- ---------- 6) anon: nothing on any core table ----------
do $$
declare r record;
begin
  for r in select c.relname, c.relkind from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'S') loop
    if r.relkind = 'S' then
      execute format('revoke all on sequence public.%I from anon', r.relname);
    else
      execute format('revoke all on public.%I from anon', r.relname);
    end if;
  end loop;
end $$;
grant select on public.site_content to anon;   -- RLS (013) shows anon only home_message_1..3
alter default privileges in schema public revoke all on tables    from anon;
alter default privileges in schema public revoke all on sequences from anon;

-- ---------- 7) Prove it ----------
do $$
declare v text;
begin
  if not exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'profiles_email_lower_uniq') then
    raise exception '014 check failed: unique email index missing';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'on_auth_user_email_changed' and not tgisinternal) then
    raise exception '014 check failed: email sync trigger missing';
  end if;
  if exists (select 1 from public.profiles p join auth.users u on u.id = p.id where p.email is distinct from u.email) then
    raise exception '014 check failed: a profile email differs from auth.users';
  end if;
  select string_agg(table_name || ':' || privilege_type, ', ') into v
    from information_schema.role_table_grants
   where table_schema = 'public' and grantee = 'anon'
     and not (table_name = 'site_content' and privilege_type = 'SELECT');
  if v is not null then raise exception '014 check failed: anon still has: %', v; end if;
  select string_agg(grantee || ':' || privilege_type, ', ') into v
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'audit_log'
     and grantee in ('PUBLIC', 'anon', 'authenticated', 'service_role') and privilege_type <> 'SELECT';
  if v is not null then raise exception '014 check failed: audit_log writable by: %', v; end if;
  select string_agg(t, ', ') into v
    from unnest(array['audit_log_no_update_delete', 'audit_log_no_truncate']) t
   where not exists (select 1 from pg_trigger where tgname = t and not tgisinternal);
  if v is not null then raise exception '014 check failed: missing triggers: %', v; end if;
  select string_agg(policyname, ', ') into v
    from pg_policies
   where schemaname = 'storage' and tablename = 'objects' and cmd in ('INSERT', 'UPDATE')
     and position('storage_upload_ok' in coalesce(with_check, '') || coalesce(qual, '')) = 0;
  if v is not null then raise exception '014 check failed: upload policies without the check: %', v; end if;
  raise notice '014 ok: launch hardening in place';
end $$;
