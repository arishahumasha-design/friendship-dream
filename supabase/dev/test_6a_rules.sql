-- DEV / TEST ONLY. Tries to BREAK each 6A rule (migrations 007 + 008), as:
--   postgres (the SQL Editor, the most powerful role), anon (logged-out visitor),
--   authenticated (a logged-in member / admin, with a fake JWT) and service_role.
-- Nothing is kept: every attempt runs in its own sub-transaction that is rolled back
-- (role switches and settings are rolled back with it).
-- Run in Supabase SQL Editor AFTER 008. The last result table shows PASS / FAIL per rule.
-- PASS = the database refused / detected the bad action (or allowed a good one).

create temp table if not exists t6a_results (n serial, test text, result text, detail text);
truncate t6a_results;

do $$
declare
  msg    text;
  st     text;
  names  text;
  lid    bigint := (select min(id) from public.member_ledger);
  rid    bigint := (select min(id) from public.fund_reserve);
  mem    uuid   := (select id from public.profiles where email = 'fd.test.member@example.com');
  adm    uuid   := (select id from public.profiles where email = 'fd.test.admin@example.com');
  poor   uuid   := (select id from public.profiles where email = 'fd.test.admin2@example.com');   -- no capital
  dep    uuid   := (select source_id from public.member_ledger where source_type = 'deposit' order by id limit 1);
  ev     uuid;
  aid    bigint;
  claims_member text;
  claims_admin  text;
begin
  claims_member := json_build_object('sub', mem, 'role', 'authenticated')::text;
  claims_admin  := json_build_object('sub', adm, 'role', 'authenticated')::text;

  ---------------------------------------------------------------- anon (logged-out)
  begin execute 'set local role anon'; perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform * from public.check_invariants(false); raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('anon: check_invariants refused', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin execute 'set local role anon'; perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform * from public.fund_summary(); raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('anon: fund_summary refused', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin execute 'set local role anon'; perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform * from public.member_totals(); raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('anon: member_totals refused', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin execute 'set local role anon'; perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform * from public.deposit_ledger(); raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('anon: deposit_ledger refused', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin execute 'set local role anon'; perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform 1 from public.member_ledger limit 1; raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('anon: read member_ledger refused', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;

  select string_agg(p.proname, ', ') into names
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     and has_function_privilege('anon', p.oid, 'execute');
  insert into t6a_results (test, result, detail)
  values ('anon: no public function is executable', case when names is null then 'PASS' else 'FAIL' end, coalesce(names, 'none'));

  select string_agg(p.proname, ', ' order by p.proname) into names
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     and has_function_privilege('authenticated', p.oid, 'execute');
  insert into t6a_results (test, result, detail)
  values ('authenticated: only the functions the app calls',
          case when names = 'add_investment_cost, approve_expense, approve_expense_reversal, approve_income, approve_investment, '
                         || 'approve_investment_cost, approve_sale, check_invariants, deposit_ledger, fund_summary, is_active_member, '
                         || 'is_admin, is_super_admin, member_totals, propose_expense, propose_expense_reversal, propose_investment, '
                         || 'propose_sale, record_income, reject_request, storage_upload_ok, valid_setting'
               then 'PASS' else 'FAIL' end, names);

  ---------------------------------------------------------------- authenticated (fake JWT)
  begin execute 'set local role authenticated'; perform set_config('request.jwt.claims', claims_member, true);
    perform * from public.check_invariants(false); raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('member: check_invariants refused', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin execute 'set local role authenticated'; perform set_config('request.jwt.claims', claims_admin, true);
    perform * from public.check_invariants(false); raise exception using errcode = 'P0098', message = 'ran';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('admin: check_invariants allowed', case when st = 'P0098' then 'PASS' else 'FAIL' end, msg); end;
  begin execute 'set local role authenticated'; perform set_config('request.jwt.claims', claims_member, true);
    perform * from public.fund_summary(); raise exception using errcode = 'P0098', message = 'ran';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('member: fund_summary still works', case when st = 'P0098' then 'PASS' else 'FAIL' end, msg); end;
  begin execute 'set local role authenticated'; perform set_config('request.jwt.claims', claims_admin, true);
    insert into public.member_ledger (member_id, kind, amount, source_type, source_id) values (mem, 'capital_deposit', 1, 'adjustment', gen_random_uuid());
    raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('admin: insert member_ledger refused', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin execute 'set local role authenticated'; perform set_config('request.jwt.claims', claims_admin, true);
    insert into public.investments (title, purchase_date, cost) values ('x', current_date, 1);
    raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('admin: insert investments refused', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin execute 'set local role authenticated'; perform set_config('request.jwt.claims', claims_admin, true);
    perform public.fund_lock_key(); raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('admin: internal helper not callable', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;

  ---------------------------------------------------------------- service_role
  begin execute 'set local role service_role';
    insert into public.member_ledger (member_id, kind, amount, source_type, source_id) values (mem, 'capital_deposit', 1, 'adjustment', gen_random_uuid());
    raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('service_role: insert member_ledger refused', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin execute 'set local role service_role';
    truncate public.investments; raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('service_role: truncate investments refused', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin execute 'set local role service_role';
    delete from public.deposits where id = dep; raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('service_role: delete deposits refused', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;

  select string_agg(grantee || ' ' || privilege_type || ' ' || table_name, '; ' order by table_name, grantee, privilege_type) into names
    from information_schema.table_privileges
   where table_schema = 'public'
     and table_name in ('member_ledger', 'fund_reserve', 'allocations', 'investment_participation',
                        'investments', 'expenses', 'investment_income', 'deposits')
     and grantee in ('anon', 'authenticated', 'service_role', 'PUBLIC')
     and (grantee in ('anon', 'PUBLIC')
          or privilege_type in ('DELETE', 'TRUNCATE', 'TRIGGER', 'REFERENCES')
          or (table_name <> 'deposits' and privilege_type <> 'SELECT'));
  insert into t6a_results (test, result, detail)
  values ('table privileges: no write/truncate/trigger leaks', case when names is null then 'PASS' else 'FAIL' end, coalesce(names, 'none'));

  ---------------------------------------------------------------- postgres: append-only + insert guard
  begin update public.member_ledger set amount = amount + 1 where id = lid; raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('postgres: member_ledger UPDATE blocked', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin delete from public.member_ledger where id = lid; raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('postgres: member_ledger DELETE blocked', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin truncate public.member_ledger; raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('postgres: member_ledger TRUNCATE blocked', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin update public.fund_reserve set amount = amount + 1 where id = rid; raise exception using errcode = 'P0099', message = 'allowed (or no reserve row)';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('postgres: fund_reserve UPDATE blocked', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin delete from public.fund_reserve where id = rid; raise exception using errcode = 'P0099', message = 'allowed (or no reserve row)';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('postgres: fund_reserve DELETE blocked', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin truncate public.fund_reserve; raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('postgres: fund_reserve TRUNCATE blocked', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin insert into public.member_ledger (member_id, kind, amount, source_type, source_id) values (mem, 'capital_deposit', 1, 'adjustment', gen_random_uuid());
    raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('postgres: insert without posting flag blocked (ledger)', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin insert into public.fund_reserve (kind, amount, source_type) values ('other', 1, 'adjustment');
    raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('postgres: insert without posting flag blocked (reserve)', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total) values ('expense', gen_random_uuid(), 'capital', mem, 1, 1);
    raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('postgres: insert without posting flag blocked (allocations)', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin perform set_config('fd.posting', 'on', true);
    insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total) values ('expense', gen_random_uuid(), 'capital', mem, 10, 10) returning id into aid;
    update public.allocations set amount = 0 where id = aid; raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('postgres: allocations UPDATE blocked', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin perform set_config('fd.posting', 'on', true);
    insert into public.investments (title, purchase_date, cost) values ('TEST', current_date, 1) returning id into ev;
    insert into public.investment_participation (investment_id, member_id, contribution_delta, capital_at_purchase, shares_at_purchase, reason) values (ev, mem, 1, 0, 0, 'purchase');
    delete from public.investment_participation where investment_id = ev; raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('postgres: investment_participation DELETE blocked', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;

  ---------------------------------------------------------------- money rules
  begin insert into public.investments (title, purchase_date, cost) values ('TEST too expensive', current_date, 99999999);
    raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('cash can not go below zero', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin perform set_config('fd.posting', 'on', true);
    insert into public.member_ledger (member_id, kind, amount, source_type, source_id) values (mem, 'capital_deposit', 1, 'deposit', dep);
    raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('a deposit is posted only once', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin perform set_config('fd.posting', 'on', true);
    insert into public.member_ledger (member_id, kind, amount, source_type, source_id) values (mem, 'expense', 50, 'expense', gen_random_uuid());
    raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('ledger kind and sign must match', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin perform set_config('fd.posting', 'on', true); ev := gen_random_uuid();
    insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total) values ('expense', ev, 'capital', mem, 5, 10);
    insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total) values ('expense', ev, 'capital', mem, 5, 10);
    raise exception using errcode = 'P0099', message = 'allowed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('one allocation row per member per event', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;

  ---------------------------------------------------------------- check_invariants must notice
  begin perform set_config('fd.posting', 'on', true);
    insert into public.member_ledger (member_id, kind, amount, source_type, source_id) values (mem, 'capital_deposit', 500, 'adjustment', gen_random_uuid());
    perform public.check_invariants(true); raise exception using errcode = 'P0099', message = 'not noticed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('invariants catch a lone ADJUSTMENT row', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin perform set_config('fd.posting', 'on', true);
    insert into public.member_ledger (member_id, kind, amount, source_type, source_id) values (mem, 'capital_deposit', 500, 'deposit', gen_random_uuid());
    perform public.check_invariants(true); raise exception using errcode = 'P0099', message = 'not noticed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('invariants catch a ledger row with no deposit', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin insert into public.expenses (title, amount, spent_on) values ('TEST stray expense', 10, current_date);
    perform public.check_invariants(true); raise exception using errcode = 'P0099', message = 'not noticed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('invariants catch an expense outside the ledger (cash rebuild)', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin insert into public.investments (title, purchase_date, cost) values ('TEST no participants', current_date, 1);
    perform public.check_invariants(true); raise exception using errcode = 'P0099', message = 'not noticed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('invariants catch an investment without contributions', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin perform set_config('fd.posting', 'on', true);
    insert into public.investments (title, purchase_date, cost) values ('TEST poor member', current_date, 1) returning id into ev;
    insert into public.investment_participation (investment_id, member_id, contribution_delta, capital_at_purchase, shares_at_purchase, free_at_purchase, reason) values (ev, poor, 1, 0, 0, 0, 'purchase');
    perform public.check_invariants(true); raise exception using errcode = 'P0099', message = 'not noticed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('invariants catch a contribution above free money at purchase', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin perform set_config('fd.posting', 'on', true); ev := gen_random_uuid();
    insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total) values ('sale', ev, 'capital', mem, 60, 100);
    insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total) values ('sale', ev, 'capital', null, 39.99, 100);
    perform public.check_invariants(true); raise exception using errcode = 'P0099', message = 'not noticed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('invariants catch an unbalanced allocation set', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin perform set_config('fd.posting', 'on', true); ev := gen_random_uuid();
    insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total) values ('expense', ev, 'capital', mem, -10, -10);
    perform public.check_invariants(true); raise exception using errcode = 'P0099', message = 'not noticed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('invariants catch event_total with no real event / no posting', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;
  begin perform set_config('fd.posting', 'on', true); ev := gen_random_uuid();
    insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total) values ('sale', ev, 'shares', mem, 25, 25) returning id into aid;
    insert into public.member_ledger (member_id, kind, amount, source_type, source_id, allocation_id) values (mem, 'profit', 25, 'investment', ev, aid);
    perform public.check_invariants(true); raise exception using errcode = 'P0099', message = 'not noticed';
  exception when others then get stacked diagnostics msg = message_text; st := sqlstate;
    insert into t6a_results (test, result, detail) values ('invariants catch a display-only (shares) row being posted', case when st = 'P0099' then 'FAIL' else 'PASS' end, msg); end;

  ---------------------------------------------------------------- the real books
  begin perform public.check_invariants(true);
    insert into t6a_results (test, result, detail) values ('current books pass check_invariants', 'PASS', 'all 14 rules hold');
  exception when others then get stacked diagnostics msg = message_text;
    insert into t6a_results (test, result, detail) values ('current books pass check_invariants', 'FAIL', msg); end;
end $$;

select n, test, result, detail from t6a_results order by n;
