-- DEV / TEST ONLY. Do not use for real members.
-- Phase 3 testing needs more fake accounts with different roles.
-- Run in Supabase SQL Editor. Safe to run again.
--
--   fd.test.admin2@example.com  -> admin  (second admin, so two admins can approve each other)
--   fd.test.super@example.com   -> super_admin (to test manual entry and settings)
--   fd.test.other@example.com   -> active member (to test that members cannot see each other's deposits)
update public.profiles set role = 'admin',       status = 'active', joined_on = current_date
 where email = 'fd.test.admin2@example.com';
update public.profiles set role = 'super_admin', status = 'active', joined_on = current_date
 where email = 'fd.test.super@example.com';
update public.profiles set status = 'active', joined_on = current_date
 where email = 'fd.test.other@example.com';

-- Check: should show 5 test rows (member, other, admin, admin2, super).
select email, role, status from public.profiles where email like 'fd.test.%@example.com' order by email;
