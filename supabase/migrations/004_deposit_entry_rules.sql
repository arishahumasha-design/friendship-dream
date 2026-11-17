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
