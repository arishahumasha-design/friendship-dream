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
