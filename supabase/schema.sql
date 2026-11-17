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
