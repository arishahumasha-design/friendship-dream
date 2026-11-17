-- DEV / TEST ONLY. Removes the fake test accounts and ALL their deposits.
--
-- !! After migration 007 this script NO LONGER WORKS as is: member_ledger, fund_reserve,
-- !! allocations and investment_participation are append-only for every role, and their rows
-- !! point at these test accounts. Removing test money from the ledger needs a separate,
-- !! deliberate "reset before go-live" step (to be decided with the owner). Do not run this.
-- Run in Supabase SQL Editor when testing is finished (the SQL Editor is allowed
-- to delete deposits; the website never is).
--
-- Uploaded test FILES must be removed by hand (Supabase does not allow deleting
-- storage files with SQL): Dashboard > Storage > 'avatars', 'documents' and
-- 'receipts' > delete the folders whose names match the ids this query shows:
select id, email from auth.users where email like 'fd.test.%@example.com';

-- 1) deposits that belong to, were entered by, or were reviewed by a test account
delete from public.deposits
 where member_id   in (select id from public.profiles where email like 'fd.test.%@example.com')
    or entered_by  in (select id from public.profiles where email like 'fd.test.%@example.com')
    or reviewed_by in (select id from public.profiles where email like 'fd.test.%@example.com');

-- 2) the accounts themselves (profiles, nominees and document rows go with them)
delete from auth.users where email like 'fd.test.%@example.com';
