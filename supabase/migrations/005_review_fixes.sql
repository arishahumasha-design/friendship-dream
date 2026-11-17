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
