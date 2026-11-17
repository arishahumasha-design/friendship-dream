-- =====================================================================
-- Friendship Dream — COMPLETE database setup for a BRAND NEW Supabase project.
-- Generated from: supabase/schema.sql (001) and every file in supabase/migrations, in number order.
-- Do NOT edit by hand: change the migration files and run: node supabase/dev/build_production_setup.js
--
-- HOW TO USE (only once, on an EMPTY new Supabase project, e.g. the real production one):
-- Create the project, open Dashboard > SQL Editor > New query, paste this whole file and Run.
-- It creates every table, rule, trigger, storage bucket and function exactly as the test
-- project has them after the last migration. Then run supabase/seed_policies.sql the same way.
-- Then: set "Confirm email" and the site URL / redirect URLs in Authentication settings,
-- put the new project's URL and publishable key in Vercel, sign up yourself on the website,
-- CONFIRM your email, and run the "SUPER ADMIN BOOTSTRAP" SQL printed at the top of section 014
-- (it uses the auth.users id; ignore the older one-liner at the end of section 001).
-- Never run this file on a project that already has data: it is not meant for upgrades
-- (use the numbered migration files for that).
-- =====================================================================


-- #####################################################################
-- ### 001 (schema.sql): schema.sql
-- #####################################################################

-- =====================================================================
-- Friendship Dream (FD) samiti — database schema for Supabase (Postgres)
-- Run this ONCE in Supabase Dashboard > SQL Editor (paste whole file > Run).
-- Safe design: every table has Row Level Security (RLS) ON, and nothing is
-- readable unless a policy below allows it.
-- =====================================================================

-- ---------- Types ----------
create type public.user_role     as enum ('member', 'admin', 'super_admin');
create type public.member_status as enum ('pending', 'active', 'suspended', 'exited');
create type public.review_status as enum ('pending', 'approved', 'rejected');
create type public.pay_method    as enum ('bank', 'bkash', 'nagad', 'rocket', 'cash', 'other');
create type public.deposit_kind  as enum ('monthly', 'yearly', 'late_fee', 'other');
create type public.doc_kind      as enum ('nid_front', 'nid_back', 'signature', 'passport',
                                          'nominee_photo', 'nominee_nid', 'other');

-- ---------- Tables ----------
create table public.profiles (
  id                 uuid primary key references auth.users (id) on delete cascade,
  member_no          integer generated always as identity,
  email              text,
  full_name          text not null default '',
  full_name_bn       text,
  father_name        text,
  mother_name        text,
  dob                date,
  phone              text,
  address_present    text,
  address_permanent  text,
  photo_path         text,                       -- storage path in 'avatars' bucket
  role               public.user_role     not null default 'member',
  status             public.member_status not null default 'pending',
  joined_on          date,
  created_at         timestamptz not null default now()
);

create table public.nominees (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null unique references public.profiles (id) on delete cascade,
  name        text not null,
  relation    text,
  phone       text,
  address     text,
  nid_number  text,
  created_at  timestamptz not null default now()
);

create table public.member_documents (
  id            uuid primary key default gen_random_uuid(),
  member_id     uuid not null references public.profiles (id) on delete cascade,
  kind          public.doc_kind not null,
  storage_path  text not null,                   -- path in 'documents' bucket
  uploaded_at   timestamptz not null default now()
);

create table public.app_settings (
  key         text primary key,
  value       jsonb not null,
  updated_by  uuid,
  updated_at  timestamptz not null default now()
);

create table public.deposits (
  id               uuid primary key default gen_random_uuid(),
  member_id        uuid not null references public.profiles (id),
  period_month     date not null,                -- always the 1st day of the month it is for
  kind             public.deposit_kind not null default 'monthly',
  amount           numeric(12, 2) not null check (amount <> 0),   -- negative only for admin corrections
  method           public.pay_method not null default 'bkash',
  transaction_ref  text,
  receipt_path     text,
  note             text,
  status           public.review_status not null default 'pending',
  submitted_at     timestamptz not null default now(),
  reviewed_by      uuid references public.profiles (id),
  reviewed_at      timestamptz,
  reject_reason    text,
  is_historical    boolean not null default false,
  check (period_month = date_trunc('month', period_month)::date)
);
-- the same transaction ID cannot be used twice (rejected ones may be re-submitted)
create unique index deposits_txn_unique
  on public.deposits (lower(transaction_ref))
  where transaction_ref is not null and status <> 'rejected';
create index deposits_member_idx on public.deposits (member_id, period_month);

create table public.expense_categories (
  id    serial primary key,
  name  text not null unique
);

create table public.expenses (
  id              uuid primary key default gen_random_uuid(),
  category_id     integer references public.expense_categories (id),
  title           text not null,
  amount          numeric(12, 2) not null check (amount > 0),
  spent_on        date not null,
  description     text,
  receipt_path    text,
  spent_by        text,
  created_by      uuid default auth.uid() references public.profiles (id),
  approved_by     uuid references public.profiles (id),
  status          text not null default 'approved' check (status in ('approved', 'reversed')),
  reversed_reason text,
  is_historical   boolean not null default false,
  created_at      timestamptz not null default now()
);

-- Investments (land, shops...) are ASSETS, not expenses.
create table public.investments (
  id             uuid primary key default gen_random_uuid(),
  title          text not null,
  kind           text not null default 'land' check (kind in ('land', 'shop', 'other')),
  description    text,
  purchase_date  date not null,
  cost           numeric(14, 2) not null check (cost > 0),
  status         text not null default 'held' check (status in ('held', 'sold')),
  sale_date      date,
  sale_amount    numeric(14, 2),
  notes          text,
  is_historical  boolean not null default false,
  created_by     uuid default auth.uid() references public.profiles (id),
  created_at     timestamptz not null default now(),
  check (status = 'held' or (sale_date is not null and sale_amount is not null))
);

create table public.investment_income (   -- rent or any other income from an investment
  id             uuid primary key default gen_random_uuid(),
  investment_id  uuid not null references public.investments (id),
  amount         numeric(12, 2) not null check (amount > 0),
  received_on    date not null,
  note           text,
  created_by     uuid default auth.uid() references public.profiles (id),
  created_at     timestamptz not null default now()
);

create table public.notices (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  body        text not null,
  created_by  uuid default auth.uid() references public.profiles (id),
  created_at  timestamptz not null default now()
);

create table public.policies (
  id              uuid primary key default gen_random_uuid(),
  sort_order      integer not null default 0,
  title           text not null,
  body            text not null,
  effective_from  date not null default current_date,
  is_current      boolean not null default true,   -- old versions stay, flagged false
  created_by      uuid default auth.uid() references public.profiles (id),
  created_at      timestamptz not null default now()
);

create table public.site_content (       -- public home page messages, About page text
  key         text primary key,
  body_en     text,
  body_bn     text,
  updated_at  timestamptz not null default now()
);

create table public.audit_log (
  id          bigint generated always as identity primary key,
  actor_id    uuid,
  action      text not null,
  table_name  text not null,
  record_id   text,
  old_data    jsonb,
  new_data    jsonb,
  created_at  timestamptz not null default now()
);

-- ---------- Helper functions (who is calling?) ----------
create function public.is_active_member() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'active');
$$;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and status = 'active' and role in ('admin', 'super_admin'));
$$;

create function public.is_super_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and status = 'active' and role = 'super_admin');
$$;

-- ---------- Triggers ----------
-- 1) a profile is created automatically when someone signs up
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'full_name', ''));
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 2) members cannot change their own role/status; only super admin changes roles
create function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then          -- SQL Editor / service use: allowed (used to create the first super admin)
    return new;
  end if;
  new.member_no := old.member_no;
  if not public.is_admin() then
    new.role := old.role;
    new.status := old.status;
    new.joined_on := old.joined_on;
  elsif not public.is_super_admin() then
    new.role := old.role;
  end if;
  return new;
end $$;

create trigger profiles_protect
  before update on public.profiles
  for each row execute function public.protect_profile_fields();

-- 3) deposits: reviewed deposits are frozen; only admins review
create function public.deposits_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.status in ('approved', 'rejected') then
      new.reviewed_by := auth.uid();
      new.reviewed_at := now();
    end if;
    return new;
  end if;

  if old.status <> 'pending' then
    raise exception 'A reviewed deposit cannot be changed. Add a correction entry instead.';
  end if;
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'Only admins can review deposits.';
  end if;
  new.member_id       := old.member_id;
  new.period_month    := old.period_month;
  new.kind            := old.kind;
  new.amount          := old.amount;
  new.transaction_ref := old.transaction_ref;
  new.method          := old.method;
  if new.status in ('approved', 'rejected') then
    new.reviewed_by := auth.uid();
    new.reviewed_at := now();
  end if;
  return new;
end $$;

create trigger deposits_guard_trg
  before insert or update on public.deposits
  for each row execute function public.deposits_guard();

-- 4) expenses: approved ones can only be reversed (not edited)
create function public.expenses_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.approved_by := coalesce(new.approved_by, auth.uid());
    return new;
  end if;
  if old.status = 'reversed' or new.status <> 'reversed' then
    raise exception 'An approved expense cannot be edited. Reverse it and enter a new one.';
  end if;
  new.category_id   := old.category_id;
  new.title         := old.title;
  new.amount        := old.amount;
  new.spent_on      := old.spent_on;
  new.description   := old.description;
  new.receipt_path  := old.receipt_path;
  new.spent_by      := old.spent_by;
  new.is_historical := old.is_historical;
  return new;
end $$;

create trigger expenses_guard_trg
  before insert or update on public.expenses
  for each row execute function public.expenses_guard();

-- 5) audit trail: who changed what, when
create function public.audit_row() returns trigger
language plpgsql security definer set search_path = '' as $$
declare j_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
        j_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
begin
  insert into public.audit_log (actor_id, action, table_name, record_id, old_data, new_data)
  values (auth.uid(), tg_op, tg_table_name,
          coalesce(j_new ->> 'id', j_new ->> 'key', j_old ->> 'id', j_old ->> 'key'),
          j_old, j_new);
  return coalesce(new, old);
end $$;

create trigger audit_profiles    after insert or update or delete on public.profiles    for each row execute function public.audit_row();
create trigger audit_deposits    after insert or update or delete on public.deposits    for each row execute function public.audit_row();
create trigger audit_expenses    after insert or update or delete on public.expenses    for each row execute function public.audit_row();
create trigger audit_investments after insert or update or delete on public.investments for each row execute function public.audit_row();
create trigger audit_inv_income  after insert or update or delete on public.investment_income for each row execute function public.audit_row();
create trigger audit_policies    after insert or update or delete on public.policies    for each row execute function public.audit_row();
create trigger audit_settings    after insert or update or delete on public.app_settings for each row execute function public.audit_row();

-- ---------- Summary functions used by the dashboard ----------
-- Fund model:
--   capital        = approved monthly + yearly + other deposits
--   total_fund     = capital + late fees + investment income + realized profit - expenses
--   invested       = cost of investments still held (land bought, not yet sold)
--   cash_available = total_fund - invested
create function public.fund_summary()
returns table (capital numeric, late_fees numeric, investment_income numeric, realized_profit numeric,
               expenses numeric, total_fund numeric, invested numeric, cash_available numeric,
               member_count integer, monthly_amount numeric)
language sql stable security definer set search_path = '' as $$
  with
  d as (select coalesce(sum(amount) filter (where kind <> 'late_fee'), 0) as cap,
               coalesce(sum(amount) filter (where kind =  'late_fee'), 0) as lf
        from public.deposits where status = 'approved'),
  e as (select coalesce(sum(amount), 0) as exp from public.expenses where status = 'approved'),
  i as (select coalesce(sum(cost) filter (where status = 'held'), 0) as inv,
               coalesce(sum(sale_amount - cost) filter (where status = 'sold'), 0) as profit
        from public.investments),
  r as (select coalesce(sum(amount), 0) as inc from public.investment_income),
  m as (select count(*)::int as n from public.profiles where status = 'active'),
  s as (select coalesce((select (value #>> '{}')::numeric from public.app_settings where key = 'monthly_amount'), 3000) as amt)
  select d.cap, d.lf, r.inc, i.profit, e.exp,
         d.cap + d.lf + r.inc + i.profit - e.exp,
         i.inv,
         d.cap + d.lf + r.inc + i.profit - e.exp - i.inv,
         m.n, s.amt
  from d, e, i, r, m, s
  where public.is_active_member();
$$;

-- Per-member totals. Honors the setting 'members_can_see_others'.
create function public.member_totals()
returns table (member_id uuid, member_no integer, full_name text, photo_path text,
               status public.member_status, capital numeric, shares integer, paid_this_month boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  vis        boolean;
  share_val  numeric;
  mstart     date := date_trunc('month', now())::date;
begin
  if not public.is_active_member() then return; end if;
  select coalesce((select (value #>> '{}')::boolean from public.app_settings where key = 'members_can_see_others'), true) into vis;
  select coalesce((select (value #>> '{}')::numeric from public.app_settings where key = 'share_value'), 5000) into share_val;
  return query
    select p.id, p.member_no, p.full_name, p.photo_path, p.status,
           coalesce(sum(d.amount) filter (where d.kind <> 'late_fee'), 0),
           floor(coalesce(sum(d.amount) filter (where d.kind <> 'late_fee'), 0) / share_val)::int,
           coalesce(bool_or(d.kind = 'monthly' and d.period_month = mstart), false)
    from public.profiles p
    left join public.deposits d on d.member_id = p.id and d.status = 'approved'
    where p.status in ('active', 'suspended')
      and (vis or public.is_admin() or p.id = auth.uid())
    group by p.id, p.member_no, p.full_name, p.photo_path, p.status
    order by p.member_no;
end $$;

-- Approved deposits for the month-by-month grid (no transaction IDs or receipts).
create function public.deposit_ledger()
returns table (member_id uuid, period_month date, kind public.deposit_kind, amount numeric)
language plpgsql stable security definer set search_path = '' as $$
declare vis boolean;
begin
  if not public.is_active_member() then return; end if;
  select coalesce((select (value #>> '{}')::boolean from public.app_settings where key = 'members_can_see_others'), true) into vis;
  return query
    select d.member_id, d.period_month, d.kind, d.amount
    from public.deposits d
    where d.status = 'approved'
      and (vis or public.is_admin() or d.member_id = auth.uid())
    order by d.period_month, d.member_id;
end $$;

-- ---------- Row Level Security ----------
alter table public.profiles           enable row level security;
alter table public.nominees           enable row level security;
alter table public.member_documents   enable row level security;
alter table public.app_settings       enable row level security;
alter table public.deposits           enable row level security;
alter table public.expense_categories enable row level security;
alter table public.expenses           enable row level security;
alter table public.investments        enable row level security;
alter table public.investment_income  enable row level security;
alter table public.notices            enable row level security;
alter table public.policies           enable row level security;
alter table public.site_content       enable row level security;
alter table public.audit_log          enable row level security;

-- profiles: own row or admin. (Other members only see name/photo through member_totals().)
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid() or public.is_admin())
  with check (id = auth.uid() or public.is_admin());

-- nominees + documents: owner or admin (so NID/passport stay private)
create policy nominees_select on public.nominees for select to authenticated
  using (member_id = auth.uid() or public.is_admin());
create policy nominees_insert on public.nominees for insert to authenticated
  with check (member_id = auth.uid() or public.is_admin());
create policy nominees_update on public.nominees for update to authenticated
  using (member_id = auth.uid() or public.is_admin())
  with check (member_id = auth.uid() or public.is_admin());

create policy docs_select on public.member_documents for select to authenticated
  using (member_id = auth.uid() or public.is_admin());
create policy docs_insert on public.member_documents for insert to authenticated
  with check (member_id = auth.uid() or public.is_admin());
create policy docs_delete on public.member_documents for delete to authenticated
  using (public.is_admin());

-- deposits
create policy deposits_select on public.deposits for select to authenticated
  using (member_id = auth.uid() or public.is_admin());
create policy deposits_insert_member on public.deposits for insert to authenticated
  with check (member_id = auth.uid() and status = 'pending' and amount > 0
              and not is_historical and public.is_active_member());
create policy deposits_insert_admin on public.deposits for insert to authenticated
  with check (public.is_admin());
create policy deposits_update_admin on public.deposits for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
-- (no delete policy anywhere: nobody can delete money records)

-- expenses, categories, investments, income, notices, policies: active members read, admins write
create policy exp_cat_select on public.expense_categories for select to authenticated using (public.is_active_member());
create policy exp_cat_write  on public.expense_categories for all    to authenticated using (public.is_admin()) with check (public.is_admin());

create policy expenses_select on public.expenses for select to authenticated using (public.is_active_member());
create policy expenses_insert on public.expenses for insert to authenticated with check (public.is_admin());
create policy expenses_update on public.expenses for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy inv_select on public.investments for select to authenticated using (public.is_active_member());
create policy inv_insert on public.investments for insert to authenticated with check (public.is_admin());
create policy inv_update on public.investments for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy inv_inc_select on public.investment_income for select to authenticated using (public.is_active_member());
create policy inv_inc_insert on public.investment_income for insert to authenticated with check (public.is_admin());

create policy notices_select on public.notices for select to authenticated using (public.is_active_member());
create policy notices_insert on public.notices for insert to authenticated with check (public.is_admin());
create policy notices_update on public.notices for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy notices_delete on public.notices for delete to authenticated using (public.is_admin());

create policy policies_select on public.policies for select to authenticated using (public.is_active_member());
create policy policies_insert on public.policies for insert to authenticated with check (public.is_admin());
create policy policies_update on public.policies for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- settings: members read, only super admin changes
create policy settings_select on public.app_settings for select to authenticated using (public.is_active_member());
create policy settings_update on public.app_settings for update to authenticated using (public.is_super_admin()) with check (public.is_super_admin());

-- public page text: anyone can read, admins edit
create policy content_select on public.site_content for select to anon, authenticated using (true);
create policy content_insert on public.site_content for insert to authenticated with check (public.is_admin());
create policy content_update on public.site_content for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- audit log: super admin reads; rows are written only by triggers
create policy audit_select on public.audit_log for select to authenticated using (public.is_super_admin());

-- ---------- Grants (needed because "auto-expose new tables" is OFF) ----------
grant usage on schema public to anon, authenticated;

grant select, update                 on public.profiles           to authenticated;
grant select, insert, update         on public.nominees           to authenticated;
grant select, insert, delete         on public.member_documents   to authenticated;
grant select, update                 on public.app_settings       to authenticated;
grant select, insert, update         on public.deposits           to authenticated;
grant select, insert, update, delete on public.expense_categories to authenticated;
grant select, insert, update         on public.expenses           to authenticated;
grant select, insert, update         on public.investments        to authenticated;
grant select, insert                 on public.investment_income  to authenticated;
grant select, insert, update, delete on public.notices            to authenticated;
grant select, insert, update         on public.policies           to authenticated;
grant select                         on public.site_content       to anon;
grant select, insert, update         on public.site_content       to authenticated;
grant select                         on public.audit_log          to authenticated;
grant usage, select on all sequences in schema public to authenticated;

revoke execute on all functions in schema public from public, anon;
grant  execute on function public.is_active_member(), public.is_admin(), public.is_super_admin(),
                           public.fund_summary(), public.member_totals(), public.deposit_ledger()
  to authenticated;

-- ---------- Starter data ----------
insert into public.app_settings (key, value) values
  ('monthly_amount',         '3000'),
  ('yearly_saving',          '0'),
  ('late_fee',               '0'),
  ('share_value',            '5000'),
  ('members_can_see_others', 'true'),
  ('deposit_deadline',       '"month_end"')
on conflict (key) do nothing;

insert into public.expense_categories (name) values
  ('Office'), ('Travel'), ('Meeting'), ('Legal and documents'), ('Other')
on conflict (name) do nothing;

insert into public.site_content (key, body_en, body_bn) values
  ('home_message_1', 'Save together. Grow together.', 'একসাথে সঞ্চয়, একসাথে এগিয়ে চলা।'),
  ('home_message_2', 'Interest-free and halal, with full transparency.', 'সুদমুক্ত, হালাল ও সম্পূর্ণ স্বচ্ছ।'),
  ('about', 'Friendship Dream (FD) is a 15-member interest-free savings and investment samiti.',
           'ফ্রেন্ডশিপ ড্রিম (এফডি) ১৫ সদস্যের একটি সুদমুক্ত সঞ্চয় ও বিনিয়োগ সমিতি।')
on conflict (key) do nothing;

-- ---------- Private file storage ----------
insert into storage.buckets (id, name, public) values
  ('documents', 'documents', false),   -- NID, passport, signature, nominee files
  ('receipts',  'receipts',  false),   -- bank/bKash receipts
  ('avatars',   'avatars',   false)    -- member photos (shown to logged-in members)
on conflict (id) do nothing;

-- File paths must start with the member's user id:  <user-id>/<filename>
create policy "documents read"   on storage.objects for select to authenticated
  using (bucket_id = 'documents' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
create policy "documents upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
create policy "documents admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and public.is_admin());

create policy "receipts read"    on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
create policy "receipts upload"  on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

create policy "avatars read"     on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and (public.is_active_member() or (storage.foldername(name))[1] = auth.uid()::text));
create policy "avatars upload"   on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
create policy "avatars replace"  on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- =====================================================================
-- AFTER you sign up on the website for the first time, run this ONE line
-- in the SQL Editor (put YOUR email) to become the super admin:
--
--   update public.profiles
--      set role = 'super_admin', status = 'active', joined_on = current_date
--    where email = 'YOUR-EMAIL-HERE';
-- =====================================================================


-- #####################################################################
-- ### 002: migrations/002_member_profiles.sql
-- #####################################################################

-- =====================================================================
-- Phase 2: member profile, documents, admin approval.
-- Run ONCE in Supabase Dashboard > SQL Editor (paste whole file > Run),
-- after schema.sql. Safe to run again.
-- This file only ADDS rules; it does not loosen any Row Level Security.
-- =====================================================================

-- 1) Admin's note to a member ("information incomplete: please upload ...").
alter table public.profiles add column if not exists review_note text;

do $$ begin
  alter table public.profiles
    add constraint profiles_review_note_len check (review_note is null or char_length(review_note) <= 1000);
exception when duplicate_object then null; end $$;

-- 2) A stored file path must sit inside the owner's own folder: <user-id>/<file>.
do $$ begin
  alter table public.profiles
    add constraint profiles_photo_path_owner check (photo_path is null or photo_path like id::text || '/%');
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.member_documents
    add constraint member_documents_path_owner check (storage_path like member_id::text || '/%');
exception when duplicate_object then null; end $$;

create index if not exists member_documents_member_idx
  on public.member_documents (member_id, kind, uploaded_at desc);

-- 3) Stricter profile protection.
--    - members cannot change role, status, joined_on or the admin's note
--    - only super admin changes roles
--    - only super admin changes the status of another admin / super admin
--    - nobody changes their OWN role or status from the website (no self-lockout)
create or replace function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
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

  if not public.is_super_admin() then
    new.role := old.role;
    if old.role in ('admin', 'super_admin') then
      new.status    := old.status;
      new.joined_on := old.joined_on;
    end if;
  end if;

  if old.id = auth.uid() then
    new.role      := old.role;
    new.status    := old.status;
    new.joined_on := old.joined_on;
  end if;
  return new;
end $$;

-- 4) File type and size limits enforced by Storage itself (max 5 MB).
update storage.buckets
   set file_size_limit = 5242880,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
 where id = 'avatars';

update storage.buckets
   set file_size_limit = 5242880,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
 where id = 'documents';


-- #####################################################################
-- ### 003: migrations/003_deposit_hardening.sql
-- #####################################################################

-- =====================================================================
-- Phase 3 preparation: hardening found by an independent security/logic review.
-- Run ONCE in Supabase Dashboard > SQL Editor (paste whole file > Run),
-- after 002. Safe to run again. It only ADDS rules; nothing is loosened.
-- =====================================================================

-- 1) New functions must never be callable by anonymous (logged-out) visitors.
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon;

-- 2) Extra deposit columns: who entered a row, and which deposit a correction refers to.
alter table public.deposits add column if not exists entered_by uuid references public.profiles (id);
alter table public.deposits add column if not exists corrects_deposit_id uuid references public.deposits (id);

-- 3) Data rules on deposits.
alter table public.deposits drop constraint if exists deposits_txn_ref_not_blank;
alter table public.deposits add constraint deposits_txn_ref_not_blank
  check (transaction_ref is null or btrim(transaction_ref) <> '');

alter table public.deposits drop constraint if exists deposits_receipt_path_owner;
alter table public.deposits add constraint deposits_receipt_path_owner
  check (receipt_path is null or receipt_path like member_id::text || '/%');

alter table public.deposits drop constraint if exists deposits_negative_needs_ref;
alter table public.deposits add constraint deposits_negative_needs_ref
  check (amount > 0 or corrects_deposit_id is not null);

alter table public.deposits drop constraint if exists deposits_reject_needs_reason;
alter table public.deposits add constraint deposits_reject_needs_reason
  check (status <> 'rejected' or nullif(btrim(coalesce(reject_reason, '')), '') is not null);

alter table public.deposits drop constraint if exists deposits_sane_values;
alter table public.deposits add constraint deposits_sane_values
  check (abs(amount) <= 10000000 and period_month between date '2020-01-01' and date '2100-01-01');

-- Transaction IDs: ignore case and spaces, so " ab12", "AB12 " and "AB 12" count as the same ID.
drop index if exists public.deposits_txn_unique;
create unique index deposits_txn_unique
  on public.deposits (upper(regexp_replace(transaction_ref, '\s', '', 'g')))
  where transaction_ref is not null and status <> 'rejected';

-- One receipt file can only back one live deposit.
create unique index if not exists deposits_receipt_unique
  on public.deposits (receipt_path)
  where receipt_path is not null and status <> 'rejected';

-- 4) Members may submit only monthly / yearly / other deposits, and must give a
--    transaction ID and a receipt unless they paid cash.
drop policy if exists deposits_insert_member on public.deposits;
create policy deposits_insert_member on public.deposits for insert to authenticated
  with check (
    member_id = auth.uid()
    and status = 'pending'
    and amount > 0
    and not is_historical
    and kind in ('monthly', 'yearly', 'other')
    and public.is_active_member()
    and (method = 'cash' or (transaction_ref is not null and receipt_path is not null))
  );

-- 5) Deposit guard: no forged reviewer names; two-person rule for normal admins.
--    - A member's pending deposit always starts with no reviewer.
--    - Rows that are saved directly as approved/rejected (manual entry, historical,
--      corrections) can only be made by the SUPER ADMIN, and need a note.
--    - A normal admin cannot approve a deposit that is their own or that they entered.
create or replace function public.deposits_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if tg_op = 'INSERT' then
    new.submitted_at := now();
    new.entered_by   := uid;
    if new.status = 'pending' then
      new.reviewed_by   := null;
      new.reviewed_at   := null;
      new.reject_reason := null;
    else
      if uid is not null then
        if not public.is_super_admin() then
          raise exception 'Only the super admin can enter deposits directly. Admins approve deposits that members submitted.';
        end if;
        if nullif(btrim(coalesce(new.note, '')), '') is null then
          raise exception 'A note is required for admin-entered deposits.';
        end if;
      end if;
      new.reviewed_by := uid;
      new.reviewed_at := now();
    end if;
    return new;
  end if;

  -- UPDATE
  if old.status <> 'pending' then
    raise exception 'A reviewed deposit cannot be changed. Add a correction entry instead.';
  end if;
  if uid is not null and not public.is_admin() then
    raise exception 'Only admins can review deposits.';
  end if;
  if new.status = 'approved' and uid is not null
     and (old.member_id = uid or old.entered_by = uid)
     and not public.is_super_admin() then
    raise exception 'You cannot approve your own deposit or one you entered. Another admin must approve it.';
  end if;

  new.member_id           := old.member_id;
  new.period_month       := old.period_month;
  new.kind               := old.kind;
  new.amount             := old.amount;
  new.transaction_ref    := old.transaction_ref;
  new.method             := old.method;
  new.receipt_path       := old.receipt_path;
  new.submitted_at       := old.submitted_at;
  new.entered_by         := old.entered_by;
  new.is_historical      := old.is_historical;
  new.corrects_deposit_id := old.corrects_deposit_id;

  if new.status in ('approved', 'rejected') then
    new.reviewed_by := uid;
    new.reviewed_at := now();
  else
    new.reviewed_by := null;
    new.reviewed_at := null;
  end if;
  return new;
end $$;

-- 6) Expense guard: creator/approver names cannot be forged from the browser.
create or replace function public.expenses_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then
      new.created_by  := auth.uid();
      new.approved_by := auth.uid();
    end if;
    return new;
  end if;
  if old.status = 'reversed' or new.status <> 'reversed' then
    raise exception 'An approved expense cannot be edited. Reverse it and enter a new one.';
  end if;
  new.category_id   := old.category_id;
  new.title         := old.title;
  new.amount        := old.amount;
  new.spent_on      := old.spent_on;
  new.description   := old.description;
  new.receipt_path  := old.receipt_path;
  new.spent_by      := old.spent_by;
  new.is_historical := old.is_historical;
  new.created_by    := old.created_by;
  new.approved_by   := old.approved_by;
  return new;
end $$;

-- 7) Settings must have sane values (a bad value must not break every dashboard).
create or replace function public.valid_setting(p_key text, p_value jsonb) returns boolean
language plpgsql immutable set search_path = '' as $$
begin
  if p_key in ('share_value', 'monthly_amount') then
    return jsonb_typeof(p_value) = 'number' and (p_value #>> '{}')::numeric > 0;
  elsif p_key in ('yearly_saving', 'late_fee') then
    return jsonb_typeof(p_value) = 'number' and (p_value #>> '{}')::numeric >= 0;
  elsif p_key = 'members_can_see_others' then
    return jsonb_typeof(p_value) = 'boolean';
  end if;
  return true;
exception when others then
  return false;
end $$;

alter table public.app_settings drop constraint if exists app_settings_valid;
alter table public.app_settings add constraint app_settings_valid
  check (public.valid_setting(key, value));

-- 8) "Paid this month" = approved monthly deposits for this month (Dhaka time)
--    reach the monthly amount. Part payments and corrections no longer count as fully paid.
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
    select p.id, p.member_no, p.full_name, p.photo_path, p.status,
           coalesce(sum(d.amount) filter (where d.kind <> 'late_fee'), 0),
           floor(coalesce(sum(d.amount) filter (where d.kind <> 'late_fee'), 0) / share_val)::int,
           coalesce(sum(d.amount) filter (where d.kind = 'monthly' and d.period_month = mstart), 0) >= month_amt
    from public.profiles p
    left join public.deposits d on d.member_id = p.id and d.status = 'approved'
    where p.status in ('active', 'suspended')
      and (vis or public.is_admin() or p.id = auth.uid())
    group by p.id, p.member_no, p.full_name, p.photo_path, p.status
    order by p.member_no;
end $$;

-- 9) Receipts bucket: same limits as the others (5 MB, images and PDF only).
update storage.buckets
   set file_size_limit = 5242880,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
 where id = 'receipts';

-- 10) More audit coverage (who changed or removed what).
drop trigger if exists audit_nominees   on public.nominees;
drop trigger if exists audit_documents  on public.member_documents;
drop trigger if exists audit_content    on public.site_content;
drop trigger if exists audit_notices    on public.notices;
drop trigger if exists audit_categories on public.expense_categories;
create trigger audit_nominees   after insert or update or delete on public.nominees           for each row execute function public.audit_row();
create trigger audit_documents  after insert or update or delete on public.member_documents   for each row execute function public.audit_row();
create trigger audit_content    after insert or update or delete on public.site_content       for each row execute function public.audit_row();
create trigger audit_notices    after insert or update or delete on public.notices            for each row execute function public.audit_row();
create trigger audit_categories after insert or update or delete on public.expense_categories for each row execute function public.audit_row();


-- #####################################################################
-- ### 004: migrations/004_deposit_entry_rules.sql
-- #####################################################################

-- =====================================================================
-- Phase 3 hardening, found while testing deposits.
-- Run ONCE in Supabase Dashboard > SQL Editor (paste whole file > Run),
-- after 003. Safe to run again. It only makes rules STRICTER.
-- =====================================================================

-- 1) Only the SUPER ADMIN may insert deposit rows on behalf of someone else.
--    Before: any admin could create a "pending" deposit for another member
--    (for example a made-up late fee marked as an old record).
--    Members (and admins paying their own monthly deposit) still submit their own
--    deposits through the policy "deposits_insert_member", which is unchanged.
drop policy if exists deposits_insert_admin on public.deposits;
create policy deposits_insert_admin on public.deposits for insert to authenticated
  with check (public.is_super_admin());

-- 2) A correction must be a NEGATIVE amount pointing at an APPROVED deposit of the SAME member,
--    with the SAME type and month (otherwise totals would be wrong: late fees are not capital).
create or replace function public.deposits_check_correction() returns trigger
language plpgsql security definer set search_path = '' as $$
declare target record;
begin
  if new.corrects_deposit_id is not null then
    select member_id, status, amount, kind, period_month into target
      from public.deposits where id = new.corrects_deposit_id;
    if not found
       or target.member_id <> new.member_id
       or target.status <> 'approved'
       or target.amount <= 0
       or target.kind <> new.kind
       or target.period_month <> new.period_month
       or new.amount >= 0 then
      raise exception 'A correction must be a negative amount for an approved deposit of the same member, type and month.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists deposits_correction_trg on public.deposits;
create trigger deposits_correction_trg
  before insert on public.deposits
  for each row execute function public.deposits_check_correction();


-- #####################################################################
-- ### 005: migrations/005_review_fixes.sql
-- #####################################################################

-- =====================================================================
-- Phase 3 review fixes (from the independent Opus review).
-- Run ONCE in Supabase Dashboard > SQL Editor (paste whole file > Run),
-- after 004. Safe to run again. It only makes rules STRICTER; nothing is loosened.
-- =====================================================================

-- 1) Only the SUPER ADMIN can make a member ACTIVE (approve a new member, or re-activate
--    a suspended one). Normal admins can still suspend and write "information incomplete" notes.
--    Normal admins also cannot change joined_on any more.
create or replace function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
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

  if not public.is_super_admin() then
    new.role      := old.role;
    new.joined_on := old.joined_on;
    if old.role in ('admin', 'super_admin') then
      new.status := old.status;
    end if;
  end if;

  if old.id = auth.uid() then          -- nobody changes their OWN role / status / joining date
    new.role      := old.role;
    new.status    := old.status;
    new.joined_on := old.joined_on;
  end if;

  if new.status = 'active' and old.status <> 'active' and not public.is_super_admin() then
    raise exception 'Only the super admin can activate a member.';
  end if;
  return new;
end $$;

-- 2) Corrections can never take back more than the original deposit.
--    The original row is locked first, so two corrections saved at the same moment
--    cannot both pass the check.
create or replace function public.deposits_check_correction() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  target record;
  already numeric;
begin
  if new.corrects_deposit_id is not null then
    select member_id, status, amount, kind, period_month into target
      from public.deposits
     where id = new.corrects_deposit_id
       for update;
    if not found
       or target.member_id <> new.member_id
       or target.status <> 'approved'
       or target.amount <= 0
       or target.kind <> new.kind
       or target.period_month <> new.period_month
       or new.amount >= 0 then
      raise exception 'A correction must be a negative amount for an approved deposit of the same member, type and month.';
    end if;

    select coalesce(sum(amount), 0) into already
      from public.deposits
     where corrects_deposit_id = new.corrects_deposit_id
       and status <> 'rejected';

    if target.amount + already + new.amount < 0 then
      raise exception 'Corrections cannot exceed the original deposit amount.';
    end if;
  end if;
  return new;
end $$;

-- 3) Double-click protection for manual entries: the form sends one random request id per
--    form load; saving the same id twice is refused.
alter table public.deposits add column if not exists request_id uuid;
create unique index if not exists deposits_request_id_unique
  on public.deposits (request_id)
  where request_id is not null;

-- 4) + 6) Deposit guard.
--    - Nobody can enter an approved/rejected deposit for THEMSELVES (not even the super admin).
--    - Nobody can approve their OWN deposit (not even the super admin): another admin must.
--    - A normal admin still cannot approve a deposit they entered.
--    - On review, the member's note is kept as it was, and a reject reason only stays on rejected rows.
create or replace function public.deposits_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if tg_op = 'INSERT' then
    new.submitted_at := now();
    new.entered_by   := uid;
    if new.status = 'pending' then
      new.reviewed_by   := null;
      new.reviewed_at   := null;
      new.reject_reason := null;
    else
      if uid is not null then
        if new.member_id = uid then
          raise exception 'You cannot enter an approved or rejected deposit for yourself.';
        end if;
        if not public.is_super_admin() then
          raise exception 'Only the super admin can enter deposits directly. Admins approve deposits that members submitted.';
        end if;
        if nullif(btrim(coalesce(new.note, '')), '') is null then
          raise exception 'A note is required for admin-entered deposits.';
        end if;
      end if;
      new.reviewed_by := uid;
      new.reviewed_at := now();
    end if;
    return new;
  end if;

  -- UPDATE
  if old.status <> 'pending' then
    raise exception 'A reviewed deposit cannot be changed. Add a correction entry instead.';
  end if;
  if uid is not null and not public.is_admin() then
    raise exception 'Only admins can review deposits.';
  end if;
  if new.status = 'approved' and uid is not null then
    if old.member_id = uid then
      raise exception 'You cannot approve your own deposit. Another admin must approve it.';
    end if;
    if old.entered_by = uid and not public.is_super_admin() then
      raise exception 'You cannot approve your own deposit or one you entered. Another admin must approve it.';
    end if;
  end if;

  new.member_id           := old.member_id;
  new.period_month        := old.period_month;
  new.kind                := old.kind;
  new.amount              := old.amount;
  new.transaction_ref     := old.transaction_ref;
  new.method              := old.method;
  new.receipt_path        := old.receipt_path;
  new.submitted_at        := old.submitted_at;
  new.entered_by          := old.entered_by;
  new.is_historical       := old.is_historical;
  new.corrects_deposit_id := old.corrects_deposit_id;
  new.request_id          := old.request_id;
  new.note                := old.note;
  new.reject_reason       := case when new.status = 'rejected' then new.reject_reason else null end;

  if new.status in ('approved', 'rejected') then
    new.reviewed_by := uid;
    new.reviewed_at := now();
  else
    new.reviewed_by := null;
    new.reviewed_at := null;
  end if;
  return new;
end $$;


-- #####################################################################
-- ### 006: migrations/006_review_fixes2.sql
-- #####################################################################

-- =====================================================================
-- Phase 3 review fixes, round 2.
-- Run ONCE in Supabase Dashboard > SQL Editor (paste whole file > Run),
-- after 005. Safe to run again. It only makes rules STRICTER; nothing is loosened.
-- =====================================================================

-- 1) deposits_guard: on review (UPDATE) EVERY column is frozen except the status and the
--    reject reason. "new := old" copies the whole row, so columns added in the future are
--    frozen too without editing this function again. The INSERT branch is unchanged from 005.
create or replace function public.deposits_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  uid        uuid := auth.uid();
  new_status public.review_status;
  new_reason text;
begin
  if tg_op = 'INSERT' then
    new.submitted_at := now();
    new.entered_by   := uid;
    if new.status = 'pending' then
      new.reviewed_by   := null;
      new.reviewed_at   := null;
      new.reject_reason := null;
    else
      if uid is not null then
        if new.member_id = uid then
          raise exception 'You cannot enter an approved or rejected deposit for yourself.';
        end if;
        if not public.is_super_admin() then
          raise exception 'Only the super admin can enter deposits directly. Admins approve deposits that members submitted.';
        end if;
        if nullif(btrim(coalesce(new.note, '')), '') is null then
          raise exception 'A note is required for admin-entered deposits.';
        end if;
      end if;
      new.reviewed_by := uid;
      new.reviewed_at := now();
    end if;
    return new;
  end if;

  -- UPDATE
  if old.status <> 'pending' then
    raise exception 'A reviewed deposit cannot be changed. Add a correction entry instead.';
  end if;
  if uid is not null and not public.is_admin() then
    raise exception 'Only admins can review deposits.';
  end if;
  if new.status = 'approved' and uid is not null then
    if old.member_id = uid then
      raise exception 'You cannot approve your own deposit. Another admin must approve it.';
    end if;
    if old.entered_by = uid and not public.is_super_admin() then
      raise exception 'You cannot approve your own deposit or one you entered. Another admin must approve it.';
    end if;
  end if;

  new_status := new.status;
  new_reason := new.reject_reason;
  new := old;                                   -- freeze every column ...
  new.status := new_status;                     -- ... then allow only these two
  new.reject_reason := case when new_status = 'rejected' then new_reason else null end;

  if new_status in ('approved', 'rejected') then
    new.reviewed_by := uid;
    new.reviewed_at := now();
  else
    new.reviewed_by := null;
    new.reviewed_at := null;
  end if;
  return new;
end $$;

-- 2) protect_profile_fields: a NORMAL admin may only
--      - change status active -> suspended (of a normal member), and
--      - write / change the review note of a PENDING member.
--    Every other status change (approve, re-activate, exit, un-suspend...) is super admin only.
--    Everything else (members, self-edits, super admin) works exactly as in 005.
create or replace function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
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

  if old.id = auth.uid() then          -- nobody changes their OWN role / status / joining date
    new.role      := old.role;
    new.status    := old.status;
    new.joined_on := old.joined_on;
  end if;

  if not public.is_super_admin() then
    new.role      := old.role;
    new.joined_on := old.joined_on;
    if old.role in ('admin', 'super_admin') then
      new.status := old.status;        -- another admin's status: super admin only (unchanged)
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

-- ---------- Guard added by production_setup.sql (not part of 007 itself) ----------
-- 007 builds the ledger assuming there are no investments / expenses / income yet.
do $$
declare n bigint;
begin
  select (select count(*) from public.investments)
       + (select count(*) from public.expenses)
       + (select count(*) from public.investment_income) into n;
  if n > 0 then
    raise exception 'STOP: 007 expects investments, expenses and investment_income to be EMPTY (found % rows).', n;
  end if;
end $$;


-- #####################################################################
-- ### 007: migrations/007_ledger_foundation.sql
-- #####################################################################

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


-- #####################################################################
-- ### 008: migrations/008_ledger_hardening.sql
-- #####################################################################

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


-- #####################################################################
-- ### 009: migrations/009_investments_expenses.sql
-- #####################################################################

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


-- #####################################################################
-- ### 010: migrations/010_money_hardening.sql
-- #####################################################################

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


-- #####################################################################
-- ### 011: migrations/011_historical_import.sql
-- #####################################################################

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


-- #####################################################################
-- ### 012: migrations/012_import_hardening.sql
-- #####################################################################

-- =====================================================================
-- Phase 7 hardening after the review of 011.
-- Run ONCE in Supabase Dashboard > SQL Editor (paste whole file > Run), after 011.
-- Safe to run again.
--
-- !! IMPORTANT: from now on the books are CLOSED until a marker exists.
-- !! On a project that already has (test) money and will never run the import, set the go-live marker
-- !! right after this file:    insert into public.system_markers (key) values ('go_live');
--
-- 1. import_batch_id can only be written by the import (transaction flag fd.import = 'on').
-- 2. Until an 'import_done' or 'go_live' marker exists, NOTHING can be approved or entered:
--    no approved deposits, no purchase / cost / sale / income / expense requests or rows.
--    Members can still SUBMIT pending deposits (they wait; see 6).
-- 3. Verify step + confirm code: import_verify(payload) shows each SR NO next to the account it maps to
--    and prints a code = md5(sorted "sr:member_id" pairs | md5(payload)). import_history needs that code.
--    The SR -> member_id map is stored on the import batch. profiles.member_no may now be set (= SR NO).
-- 5. counts_for_payment_rules(deposit): the ONLY filter future late-fee / paid-on-time / suspension
--    logic may use; it leaves out historical, imported and back-month deposits.
-- 6. The import refuses while pending deposits exist for months it covers.
-- 7. check_invariants rule 27: imported deposits were submitted at the moment of the marker; at most
--    one imported investment.
-- 8. Plain temp tables in the import (a pre-planted table makes it fail instead of being used);
--    free money at purchase in the report; the extra cent goes to the lowest SR NO (member_no = SR NO).
-- =====================================================================

-- ---------- 0) member_no can be set to the SR NO (unique, checked at commit) ----------
alter table public.profiles alter column member_no set generated by default;
do $$ begin
  alter table public.profiles add constraint profiles_member_no_unique unique (member_no) deferrable initially deferred;
exception when duplicate_object or duplicate_table then null; end $$;

-- ---------- 1) Helpers ----------
create or replace function public.books_open() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.system_markers where key in ('import_done', 'go_live'));
$$;

create or replace function public.require_sql_editor() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null or coalesce(current_setting('request.jwt.claims', true), '') <> ''
     or session_user not in ('postgres', 'supabase_admin') then
    raise exception 'The historical import can only be run from the Supabase SQL Editor.';
  end if;
end $$;

create or replace function public.counts_for_payment_rules(d public.deposits) returns boolean
language sql immutable set search_path = '' as $$
  select not d.is_historical and d.import_batch_id is null and not d.is_back_month;
$$;
comment on function public.counts_for_payment_rules(public.deposits) is
  'The ONLY filter that late-fee, paid-on-time and suspension rules may use: historical, imported and back-month deposits never count against a member.';

-- ---------- 2) import_batch_id: only the import may write it ----------
create or replace function public.import_batch_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.import_batch_id is not null
     and (tg_op = 'INSERT' or new.import_batch_id is distinct from old.import_batch_id)
     and coalesce(current_setting('fd.import', true), '') <> 'on' then
    raise exception 'Only the historical import may mark rows as imported.';
  end if;
  return new;
end $$;

do $$
declare tb text;
begin
  foreach tb in array array['deposits', 'money_requests', 'investments'] loop
    execute format('drop trigger if exists %I on public.%I', tb || '_import_batch_guard', tb);
    execute format('create trigger %I before insert or update on public.%I for each row execute function public.import_batch_guard()',
                   tb || '_import_batch_guard', tb);
  end loop;
end $$;

drop policy if exists deposits_insert_member on public.deposits;
create policy deposits_insert_member on public.deposits for insert to authenticated
  with check (
    member_id = auth.uid()
    and status = 'pending'
    and amount > 0
    and not is_historical
    and import_batch_id is null
    and kind in ('monthly', 'yearly', 'other')
    and public.is_active_member()
    and (method = 'cash' or (transaction_ref is not null and receipt_path is not null))
  );
drop policy if exists deposits_insert_admin on public.deposits;
create policy deposits_insert_admin on public.deposits for insert to authenticated
  with check (public.is_super_admin() and import_batch_id is null);

-- ---------- 3) Books closed until the import (or go-live) ----------
create or replace function public.books_closed_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if public.books_open() or coalesce(current_setting('fd.import', true), '') = 'on' then
    return new;
  end if;
  if tg_table_name = 'deposits' then
    if new.status = 'approved' and (tg_op = 'INSERT' or old.status <> 'approved') then
      raise exception 'The books open after the historical import. Until then no deposit can be approved or entered (it can be rejected, or wait).';
    end if;
    return new;
  end if;
  if tg_table_name = 'money_requests' and new.import_batch_id is not null then
    return new;
  end if;
  raise exception 'The books open after the historical import. Until then no purchase, cost, sale, income or expense can be entered.';
end $$;

do $$
declare tb text;
begin
  execute 'drop trigger if exists deposits_books_closed on public.deposits';
  execute 'create trigger deposits_books_closed before insert or update on public.deposits
             for each row execute function public.books_closed_guard()';
  foreach tb in array array['money_requests', 'investments', 'expenses', 'investment_income'] loop
    execute format('drop trigger if exists %I on public.%I', tb || '_books_closed', tb);
    execute format('create trigger %I before insert on public.%I for each row execute function public.books_closed_guard()',
                   tb || '_books_closed', tb);
  end loop;
end $$;

-- ---------- 4) The SR -> member map is kept on the batch (admins only) ----------
alter table public.import_batches add column if not exists sr_map jsonb;

-- ---------- 5) Verify and confirm ----------
create or replace function public.import_confirm_code(p jsonb) returns text
language sql stable security definer set search_path = '' as $$
  select md5(coalesce((select string_agg((m ->> 'sr_no') || ':' || pr.id::text, ',' order by (m ->> 'sr_no')::int)
                         from jsonb_array_elements(p -> 'members') m
                         join public.profiles pr on lower(pr.email) = lower(btrim(m ->> 'email'))), '')
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
           case when pr.id is null then 'NO ACCOUNT with this email'
                when pr.status <> 'active' then 'not active (run the prepare step)'
                when pr.joined_on is distinct from (p ->> 'joined_on')::date then 'joined_on is not ' || (p ->> 'joined_on')
                when pr.member_no <> (m ->> 'sr_no')::int then 'member_no is not the SR NO (run the prepare step)'
                when u.email_confirmed_at is null then 'email not confirmed yet'
                else 'ok' end
      from jsonb_array_elements(p -> 'members') m
      left join public.profiles pr on lower(pr.email) = lower(btrim(m ->> 'email'))
      left join auth.users u on u.id = pr.id
     order by 1;
  select count(*) into v_bad
    from jsonb_array_elements(p -> 'members') m
    left join public.profiles pr on lower(pr.email) = lower(btrim(m ->> 'email'))
   where pr.id is null or pr.status <> 'active' or pr.joined_on is distinct from (p ->> 'joined_on')::date
      or pr.member_no <> (m ->> 'sr_no')::int;
  return query select null::int, 'CONFIRM CODE'::text,
                      case when v_bad = 0 then public.import_confirm_code(p) else 'fix the problems above first' end,
                      null::int, null::text, null::date, null::boolean,
                      case when v_bad = 0 then 'check every name above, then use this code' else v_bad || ' problem(s)' end;
end $$;

-- ---------- 6) The import ----------
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
  update pg_temp.fd_import_map f set member_id = pr.id from public.profiles pr where lower(pr.email) = f.email;
  select string_agg(sr_no::text, ', ' order by sr_no) into v_list from pg_temp.fd_import_map where member_id is null;
  if v_list is not null then
    raise exception 'IMPORT: no account found for SR NO %. Every member must sign up first.', v_list;
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

drop function if exists public.import_history(jsonb, boolean);
create or replace function public.import_history(p_payload jsonb, p_confirm text, p_dry_run boolean default true)
returns table (section text, item text, value text)
language plpgsql security definer set search_path = '' as $$
declare rep text[];
begin
  perform public.require_sql_editor();
  perform public.take_fund_lock();
  if exists (select 1 from public.system_markers where key in ('import_done', 'go_live'))
     or exists (select 1 from public.import_batches) then
    raise exception 'The historical import was already done (or the site is live). It can never run again.';
  end if;
  if p_confirm is null or p_confirm <> public.import_confirm_code(p_payload) then
    raise exception 'The confirm code does not match this member map. Run run_verify.sql, check every name, and build the import files again with that code.';
  end if;

  perform set_config('fd.import', 'on', true);
  if p_dry_run then
    begin
      rep := public.import_apply(p_payload);
      raise exception using errcode = 'P0097', message = 'dry run: everything is rolled back';
    exception when sqlstate 'P0097' then
      null;                                   -- all writes of the dry run are undone here
    end;
    perform set_config('fd.import', 'off', true);
    return query select 'DRY RUN ' || split_part(x, '|', 1), split_part(x, '|', 2), split_part(x, '|', 3)
                   from unnest(rep) x;
    return query select 'DRY RUN'::text, 'nothing was saved'::text, 'now run run_import_real.sql (same confirm code)'::text;
  else
    rep := public.import_apply(p_payload);
    perform set_config('fd.import', 'off', true);
    return query select split_part(x, '|', 1), split_part(x, '|', 2), split_part(x, '|', 3) from unnest(rep) x;
    return query select 'DONE'::text, 'historical import saved'::text, 'marker import_done is set'::text;
  end if;
end $$;

-- ---------- 7) check_invariants: rule 27 tightened ----------
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
  select (select count(*) from public.deposits d
           where d.import_batch_id is not null
             and (not d.is_historical or d.status <> 'approved'
                  or d.submitted_at is distinct from (select s.set_at from public.system_markers s where s.key = 'import_done')))
       + greatest((select count(*) from public.investments where import_batch_id is not null) - 1, 0)
       + (select count(*) from (
            select d.import_batch_id as b from public.deposits d where d.import_batch_id is not null
            union all select i.import_batch_id from public.investments i where i.import_batch_id is not null
            union all select q.import_batch_id from public.money_requests q where q.import_batch_id is not null) x
           where not exists (select 1 from public.system_markers s where s.key = 'import_done' and (s.value ->> 'batch')::uuid = x.b))
       + (select count(*) from public.money_requests q where q.import_batch_id is not null and (q.status <> 'approved' or q.kind not in ('purchase', 'investment_cost')))
    into n;
  rule := 'imported rows belong to the one finished import'; ok := n = 0 and k <= 1;   -- incl. submitted at the marker, <= 1 imported investment
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

-- ---------- 8) Permissions: import functions for the SQL Editor only ----------
do $$
declare fn record;
begin
  for fn in select p.oid::regprocedure as sig from pg_proc p
             where p.pronamespace = 'public'::regnamespace
               and p.proname in ('books_open', 'require_sql_editor', 'counts_for_payment_rules', 'import_batch_guard',
                                 'books_closed_guard', 'import_confirm_code', 'import_verify', 'import_apply',
                                 'import_history', 'check_invariants')
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', fn.sig);
  end loop;
end $$;
grant execute on function public.check_invariants(boolean) to authenticated;

do $$
declare names text;
begin
  select string_agg(p.proname, ', ') into names
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('service_role', p.oid, 'execute')
          or (p.proname like 'import%' and has_function_privilege('authenticated', p.oid, 'execute')));
  if names is not null then
    raise exception 'API roles can still execute: %', names;
  end if;
end $$;

-- (On a project with test money and no import planned: insert into public.system_markers (key) values ('go_live');)
select * from public.check_invariants(false);


-- #####################################################################
-- ### 013: migrations/013_content_hardening.sql
-- #####################################################################

-- =====================================================================
-- 013_content_hardening.sql  (run AFTER 012; it touches no money table)
--
-- 1) notices: pinned (default false) + pinned_at. Only admins can pin / unpin; pinned_at is set by the database.
-- 2) policies and site_content:
--    - only the super admin can INSERT or UPDATE (RLS = first layer, trigger = second layer);
--    - nobody can DELETE or TRUNCATE (not even service_role or the SQL Editor): hide instead
--      (policies.is_current = false, site_content text = empty);
--    - every change stays audit-logged (audit_policies / audit_content triggers, checked below);
--    - active members read all rows; anon (and any logged-in user, e.g. pending) reads ONLY the
--      public front-page messages: home_message_1, home_message_2, home_message_3.
--    - The SQL Editor (database owner, no logged-in user) may still insert / update,
--      e.g. supabase/seed_policies.sql on a new project.
-- 3) A self-check at the end stops the migration if anything is not as described.
-- Safe to run more than once.
-- =====================================================================

-- Who may write is decided INSIDE the trigger functions (they run as the calling role, and trigger
-- functions need no execute grant). No new callable function is created, so the API surface stays the same:
--   * the SQL Editor / migrations: not an API role (anon / authenticated / service_role) and no logged-in user;
--   * a logged-in user: role authenticated, checked with is_admin() / is_super_admin();
--   * service_role and anon are never admins here, whatever JWT they carry.

-- ---------- 1) notices: pin ----------
alter table public.notices add column if not exists pinned    boolean not null default false;
alter table public.notices add column if not exists pinned_at timestamptz;
create index if not exists notices_order_idx on public.notices (pinned desc, pinned_at desc nulls last, created_at desc);

create or replace function public.notices_pin_guard() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_admin boolean := false;
begin
  if current_user = 'authenticated' then
    v_admin := public.is_admin();
  elsif current_user not in ('anon', 'service_role') and auth.uid() is null then
    v_admin := true;   -- SQL Editor / migrations
  end if;

  if tg_op = 'INSERT' then
    if new.pinned and not v_admin then
      raise exception 'Only an admin can pin a notice.' using errcode = '42501';
    end if;
    new.pinned_at := case when new.pinned then now() end;
  else
    if new.pinned is distinct from old.pinned then
      if not v_admin then
        raise exception 'Only an admin can pin or unpin a notice.' using errcode = '42501';
      end if;
      new.pinned_at := case when new.pinned then now() end;
    else
      new.pinned_at := old.pinned_at;   -- nobody sets pinned_at by hand
    end if;
  end if;
  return new;
end $$;

drop trigger if exists notices_pin_guard on public.notices;
create trigger notices_pin_guard before insert or update on public.notices
  for each row execute function public.notices_pin_guard();

-- ---------- 2) policies + site_content: second layer (trigger) ----------
create or replace function public.content_write_guard() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_ok boolean := false;
begin
  if tg_op in ('DELETE', 'TRUNCATE') then
    raise exception 'Rows in % are never deleted. Hide them instead.', tg_table_name using errcode = '42501';
  end if;

  if current_user = 'authenticated' then
    v_ok := public.is_super_admin();
  elsif current_user not in ('anon', 'service_role') and auth.uid() is null then
    v_ok := true;      -- SQL Editor / migrations (e.g. seed_policies.sql)
  end if;
  if not v_ok then
    raise exception 'Only the super admin can change %.', tg_table_name using errcode = '42501';
  end if;

  if tg_table_name = 'policies' then
    if tg_op = 'INSERT' then
      new.created_at := now();
      new.created_by := coalesce(auth.uid(), new.created_by);
    else
      new.id         := old.id;          -- identity and history fields never change
      new.created_by := old.created_by;
      new.created_at := old.created_at;
    end if;
  elsif tg_table_name = 'site_content' then
    if tg_op = 'UPDATE' and new.key is distinct from old.key then
      raise exception 'The key of a site_content row cannot change.' using errcode = '42501';
    end if;
    new.updated_at := now();
  end if;
  return new;
end $$;

do $$
declare tb text;
begin
  foreach tb in array array['policies', 'site_content'] loop
    execute format('drop trigger if exists %I on public.%I', tb || '_write_guard', tb);
    execute format('create trigger %I before insert or update or delete on public.%I for each row execute function public.content_write_guard()',
                   tb || '_write_guard', tb);
    execute format('drop trigger if exists %I on public.%I', tb || '_no_truncate', tb);
    execute format('create trigger %I before truncate on public.%I for each statement execute function public.content_write_guard()',
                   tb || '_no_truncate', tb);
  end loop;
end $$;

-- audit triggers (there since 001 / 003; recreated only if missing)
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'audit_policies' and tgrelid = 'public.policies'::regclass) then
    create trigger audit_policies after insert or update or delete on public.policies for each row execute function public.audit_row();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'audit_content' and tgrelid = 'public.site_content'::regclass) then
    create trigger audit_content after insert or update or delete on public.site_content for each row execute function public.audit_row();
  end if;
end $$;

-- ---------- 3) policies + site_content: first layer (privileges + RLS) ----------
revoke all on public.policies, public.site_content from public, anon, authenticated, service_role;
grant select, insert, update on public.policies     to authenticated;
grant select, insert, update on public.site_content to authenticated;
grant select                 on public.site_content to anon;
grant select on public.policies, public.site_content to service_role;   -- read only

alter table public.policies     enable row level security;
alter table public.site_content enable row level security;

-- drop every existing policy on the two tables, then create exactly the ones we want
do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies
            where schemaname = 'public' and tablename in ('policies', 'site_content') loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

create policy policies_select on public.policies for select to authenticated
  using (public.is_active_member());
create policy policies_insert on public.policies for insert to authenticated
  with check (public.is_super_admin());
create policy policies_update on public.policies for update to authenticated
  using (public.is_super_admin()) with check (public.is_super_admin());

create policy content_public_select on public.site_content for select to anon, authenticated
  using (key in ('home_message_1', 'home_message_2', 'home_message_3'));
create policy content_member_select on public.site_content for select to authenticated
  using (public.is_active_member());
create policy content_insert on public.site_content for insert to authenticated
  with check (public.is_super_admin());
create policy content_update on public.site_content for update to authenticated
  using (public.is_super_admin()) with check (public.is_super_admin());

-- ---------- 4) Prove it ----------
do $$
declare v text;
begin
  -- no API role may delete / truncate; anon and service_role may only read
  select string_agg(grantee || ':' || table_name || ':' || privilege_type, ', ') into v
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name in ('policies', 'site_content')
     and grantee in ('PUBLIC', 'anon', 'authenticated', 'service_role')
     and (privilege_type in ('DELETE', 'TRUNCATE', 'TRIGGER', 'REFERENCES')
          or (grantee in ('anon', 'service_role', 'PUBLIC') and privilege_type <> 'SELECT'));
  if v is not null then raise exception '013 check failed: unwanted grants: %', v; end if;

  -- every write policy needs the super admin; no DELETE / ALL policies
  select string_agg(tablename || '.' || policyname, ', ') into v
    from pg_policies
   where schemaname = 'public' and tablename in ('policies', 'site_content')
     and (cmd in ('DELETE', 'ALL')
          or (cmd in ('INSERT', 'UPDATE') and position('is_super_admin()' in coalesce(with_check, '')) = 0)
          or (cmd = 'UPDATE' and position('is_super_admin()' in coalesce(qual, '')) = 0));
  if v is not null then raise exception '013 check failed: write policies without super admin: %', v; end if;

  -- anon reads only the three public keys
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'site_content'
              and cmd = 'SELECT' and 'anon' = any (roles) and position('home_message_1' in coalesce(qual, '')) = 0) then
    raise exception '013 check failed: anon may read more than the public keys';
  end if;

  -- triggers in place
  select string_agg(t, ', ') into v
    from unnest(array['policies_write_guard', 'policies_no_truncate', 'site_content_write_guard',
                      'site_content_no_truncate', 'audit_policies', 'audit_content', 'notices_pin_guard']) t
   where not exists (select 1 from pg_trigger where tgname = t and not tgisinternal);
  if v is not null then raise exception '013 check failed: missing triggers: %', v; end if;

  -- no function (other than the guards) writes these tables
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname not in ('content_write_guard', 'notices_pin_guard')
     and p.prosrc ~* '(insert[[:space:]]+into|update|delete[[:space:]]+from|truncate)[[:space:]]+(table[[:space:]]+)?(only[[:space:]]+)?(public[.])?(policies|site_content)([^a-z_]|$)';
  if v is not null then raise exception '013 check failed: functions that write content tables: %', v; end if;

  raise notice '013 ok: content tables hardened';
end $$;


-- #####################################################################
-- ### 014: migrations/014_launch_hardening.sql
-- #####################################################################

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
