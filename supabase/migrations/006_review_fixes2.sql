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
