-- DEV / TEST ONLY. Do not use for real members.
-- Makes the fake test account fd.test.admin@example.com an active ADMIN
-- so the admin pages can be tested. Run in Supabase SQL Editor AFTER 002.
update public.profiles
   set role = 'admin', status = 'active', joined_on = current_date
 where email = 'fd.test.admin@example.com';

-- Check: should show 3 test rows.
select email, role, status from public.profiles where email like 'fd.test.%@example.com';
