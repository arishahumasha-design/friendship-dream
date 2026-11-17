-- DEV / TEST ONLY. Tries to BREAK every 6B rule (migrations 009 + 010).
-- Every scenario runs in its own sub-transaction and is ROLLED BACK: nothing is kept.
-- Identities are faked with request.jwt.claims (maker = fd.test.admin, checker = fd.test.admin2).
-- Run in Supabase SQL Editor AFTER 010. The last table shows PASS / FAIL per rule.
-- (PL/pgSQL names are case-insensitive: all member variables are prefixed with u_ to avoid clashes.)

create temp table if not exists t6b_results (n serial, test text, result text, detail text);
truncate t6b_results;
create temp table if not exists t6b_free (member_id uuid, free numeric);

-- act as a user (null = the SQL Editor itself, no JWT)
create or replace function pg_temp.act(p uuid) returns void language sql as $f$
  select set_config('request.jwt.claims',
                    case when p is null then '' else json_build_object('sub', p, 'role', 'authenticated')::text end, true);
$f$;
-- give a member an approved deposit (as the SQL Editor); returns the deposit id
create or replace function pg_temp.give(p uuid, amt numeric) returns uuid language plpgsql as $f$
declare v uuid;
begin
  perform pg_temp.act(null);
  insert into public.deposits (member_id, period_month, kind, amount, method, status, note)
  values (p, date_trunc('month', current_date)::date, 'monthly', amt, 'cash', 'approved', 'test 6b')
  returning id into v;
  return v;
end $f$;
create or replace function pg_temp.inv_ok() returns boolean language plpgsql as $f$
begin
  perform pg_temp.act(null);
  return not exists (select 1 from public.check_invariants(false) c where not c.ok);
end $f$;
create or replace function pg_temp.inv_bad() returns text language plpgsql as $f$
begin
  perform pg_temp.act(null);
  return coalesce((select string_agg(c.rule || ' [' || c.detail || ']', '; ') from public.check_invariants(false) c where not c.ok), 'all ok');
end $f$;
-- does this invariant rule currently fail?
create or replace function pg_temp.rule_fails(p_rule text) returns boolean language plpgsql as $f$
begin
  perform pg_temp.act(null);
  return exists (select 1 from public.check_invariants(false) c where not c.ok and c.rule = p_rule);
end $f$;
-- approve a purchase with the basis the request currently has
create or replace function pg_temp.buy(p_req uuid, p_checker uuid) returns uuid language plpgsql as $f$
declare v_basis numeric;
begin
  perform pg_temp.act(null);
  select q.amount + coalesce((select sum(c.amount) from public.money_requests c
                               where c.kind = 'investment_cost' and c.purchase_request_id = q.id and c.status = 'approved'), 0)
    into v_basis from public.money_requests q where q.id = p_req;
  perform pg_temp.act(p_checker);
  return public.approve_investment(p_req, v_basis);
end $f$;

do $$
declare
  res   text[] := '{}';
  msg   text; st text;
  u_m   uuid := (select id from public.profiles where email = 'fd.test.member@example.com');
  u_o   uuid := (select id from public.profiles where email = 'fd.test.other@example.com');
  u_a   uuid := (select id from public.profiles where email = 'fd.test.admin@example.com');
  u_a2  uuid := (select id from public.profiles where email = 'fd.test.admin2@example.com');
  u_s   uuid := (select id from public.profiles where email = 'fd.test.super@example.com');
  u_p2  uuid := (select id from public.profiles where email = 'fd.test.pending2@example.com');
  u_p3  uuid := (select id from public.profiles where email = 'fd.test.pending3@example.com');
  v_req uuid; v_req2 uuid; v_inv uuid; v_ex uuid; v_inc uuid; v_dep uuid;
  v_n   numeric; v_m numeric; v_k numeric; v_c integer;
  f     record;
begin
  -------------------------------------------------------------------- S1 purchase: who takes part, exact sums
  begin
    perform pg_temp.give(u_p3, 10000);                                   -- P3 is PENDING: must be left out
    perform pg_temp.act(null);
    update public.profiles set joined_on = current_date + 30 where id = u_p2;   -- P2 "joins after" (no money yet)
    perform pg_temp.give(u_p2, 10000);
    truncate t6b_free; insert into t6b_free select member_id, free from public.member_balances_internal();

    perform pg_temp.act(u_a); v_req := public.propose_investment('TEST land A', 'land', current_date, 7777.77, null);
    begin perform pg_temp.act(u_a2); perform public.approve_investment(v_req, 7777.00); res := res || 'S1 wrong expected basis refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S1 wrong expected basis refused|PASS|' || msg); end;
    v_inv := pg_temp.buy(v_req, u_a2);

    res := res || format('S1 pending member left out|%s|', case when not exists (select 1 from public.investment_participation where investment_id = v_inv and member_id = u_p3) then 'PASS' else 'FAIL' end);
    res := res || format('S1 member who joins after left out|%s|', case when not exists (select 1 from public.investment_participation where investment_id = v_inv and member_id = u_p2) then 'PASS' else 'FAIL' end);
    select count(*) into v_c from public.member_balances_internal() b join t6b_free fr on fr.member_id = b.member_id
     where b.status = 'active' and b.joined_on <= current_date and fr.free > 0
       and not exists (select 1 from public.investment_participation p where p.investment_id = v_inv and p.member_id = b.member_id);
    res := res || format('S1 every eligible active member takes part|%s|%s missing', case when v_c = 0 then 'PASS' else 'FAIL' end, v_c);
    select sum(contribution_delta), count(*) into v_n, v_c from public.investment_participation where investment_id = v_inv;
    res := res || format('S1 contributions add up exactly to the cost (7777.77)|%s|sum %s over %s members', case when v_n = 7777.77 then 'PASS' else 'FAIL' end, v_n, v_c);
    select count(*) into v_c from public.investment_participation p join t6b_free fr on fr.member_id = p.member_id
     where p.investment_id = v_inv and (p.contribution_delta > fr.free or p.free_at_purchase <> fr.free);
    res := res || format('S1 nobody puts in more than their free money (and it is recorded)|%s|%s wrong', case when v_c = 0 then 'PASS' else 'FAIL' end, v_c);
    res := res || format('S1 check_invariants after purchase|%s|%s', case when pg_temp.inv_ok() then 'PASS' else 'FAIL' end, pg_temp.inv_bad());

    -- overspend
    perform pg_temp.act(null);
    select sum(free) into v_n from public.member_balances_internal() where status = 'active' and free > 0;
    perform pg_temp.act(u_a); v_req := public.propose_investment('TEST too big', 'land', current_date, v_n + 1, null);
    begin perform pg_temp.buy(v_req, u_a2); res := res || 'S2 overspend refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S2 overspend refused|PASS|' || msg); end;

    -- own approval
    begin perform pg_temp.buy(v_req, u_a); res := res || 'S3 admin approves own entry refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S3 admin approves own entry refused|PASS|' || msg); end;
    perform pg_temp.act(u_s); v_req2 := public.propose_expense('TEST super expense', 10, current_date);
    begin perform pg_temp.act(u_s); perform public.approve_expense(v_req2); res := res || 'S3 super admin approves own entry refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S3 super admin approves own entry refused|PASS|' || msg); end;

    begin perform pg_temp.act(null); update public.investments set cost = 1, title = 'x' where id = v_inv; res := res || 'S3 edit approved investment refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S3 edit approved investment refused|PASS|' || msg); end;
    begin perform pg_temp.act(null); delete from public.investment_participation where investment_id = v_inv; res := res || 'S3 delete participation refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S3 delete participation refused|PASS|' || msg); end;
    begin perform pg_temp.act(null); update public.profiles set joined_on = current_date - 400 where id = u_m;
      res := res || 'S3 joined_on frozen once there is money (even SQL Editor)|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S3 joined_on frozen once there is money (even SQL Editor)|PASS|' || msg); end;
    begin perform pg_temp.act(u_s); update public.profiles set status = 'exited' where id = u_o;
      res := res || 'S3 super admin cannot set exited|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S3 super admin cannot set exited|PASS|' || msg); end;

    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S1-S3 scenario crashed|FAIL|' || msg); end if;
  end;

  -------------------------------------------------------------------- S4 loss sale, waiting costs, sell twice, edit sold
  begin
    perform pg_temp.act(u_a); v_req := public.propose_investment('TEST land loss', 'land', current_date, 5000, null);
    v_inv := pg_temp.buy(v_req, u_a2);
    perform pg_temp.act(u_a); v_req2 := public.propose_expense('TEST plot fee', 12.34, current_date, null, v_inv);
    perform pg_temp.act(u_a); v_req := public.propose_sale(v_inv, 4000.03, current_date, null);
    begin perform pg_temp.act(u_a2); perform public.approve_sale(v_req); res := res || 'S4 sale waits for pending plot expenses|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S4 sale waits for pending plot expenses|PASS|' || msg); end;
    perform pg_temp.act(u_a2); perform public.reject_request(v_req2, 'not now');
    perform pg_temp.act(u_a2); v_n := public.approve_sale(v_req);
    res := res || format('S4 loss computed (4000.03 - 5000 = -999.97)|%s|%s', case when v_n = -999.97 then 'PASS' else 'FAIL' end, v_n);
    select coalesce(sum(amount), 0) into v_m from public.member_ledger where source_type = 'investment' and source_id = v_inv;
    select coalesce(sum(amount), 0) into v_k from public.fund_reserve where source_type = 'allocation' and source_id = v_inv;
    res := res || format('S4 member losses + reserve = -999.97 exactly, reserve leftover >= 0|%s|members %s, reserve %s', case when v_m + v_k = -999.97 and v_k >= 0 then 'PASS' else 'FAIL' end, v_m, v_k);
    select count(*) into v_c from public.allocations where event_id = v_inv and basis = 'shares';
    res := res || format('S4 illustrative shares set written, never posted|%s|%s rows', case when v_c > 0 and not exists (select 1 from public.member_ledger l join public.allocations a on a.id = l.allocation_id where a.basis = 'shares') then 'PASS' else 'FAIL' end, v_c);
    res := res || format('S4 check_invariants after loss sale|%s|%s', case when pg_temp.inv_ok() then 'PASS' else 'FAIL' end, pg_temp.inv_bad());
    -- expense on a SOLD plot is allowed, charged to its participants
    perform pg_temp.act(u_a); v_req := public.propose_expense('TEST lawyer after sale', 30.01, current_date, null, v_inv);
    perform pg_temp.act(u_a2); v_ex := public.approve_expense(v_req);
    select count(*) into v_c from public.member_ledger l where l.source_id = v_ex
       and l.member_id not in (select s.member_id from public.investment_sharers(v_inv) s);
    res := res || format('S4 expense on a sold plot charged to its participants only|%s|outsiders %s', case when v_c = 0 and (select count(*) from public.member_ledger where source_id = v_ex) > 0 then 'PASS' else 'FAIL' end, v_c);
    begin perform pg_temp.act(u_a); perform public.propose_sale(v_inv, 9000, current_date, null); res := res || 'S4 sell twice refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S4 sell twice refused|PASS|' || msg); end;
    begin perform pg_temp.act(null); perform set_config('fd.posting', 'on', true);
      update public.investments set sale_amount = 1 where id = v_inv; res := res || 'S4 edit sold investment refused even with the posting flag|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S4 edit sold investment refused even with the posting flag|PASS|' || msg); end;
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S4 scenario crashed|FAIL|' || msg); end if;
  end;

  -------------------------------------------------------------------- S5 cost at purchase; profit sale; orphan cost items
  begin
    perform pg_temp.act(u_a); v_req := public.propose_investment('TEST shop', 'shop', current_date, 3000, null);
    perform pg_temp.act(u_a); v_req2 := public.add_investment_cost(v_req, 250.50, 'Registration', current_date, null);
    begin perform pg_temp.act(u_a2); perform public.approve_investment(v_req, 3000); res := res || 'S5 purchase blocked while a cost item waits|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S5 purchase blocked while a cost item waits|PASS|' || msg); end;
    perform pg_temp.act(u_a2); perform public.approve_investment_cost(v_req2);
    v_inv := pg_temp.buy(v_req, u_a2);
    select capitalized_costs into v_n from public.investments where id = v_inv;
    select sum(contribution_delta) into v_m from public.investment_participation where investment_id = v_inv;
    res := res || format('S5 cost basis = 3000 + 250.50 and contributions match|%s|capitalized %s, contributions %s', case when v_n = 250.50 and v_m = 3250.50 then 'PASS' else 'FAIL' end, v_n, v_m);
    perform pg_temp.act(u_a); v_req := public.propose_sale(v_inv, 7000.07, current_date, null);
    perform pg_temp.act(u_a2); v_n := public.approve_sale(v_req);
    select coalesce(sum(amount), 0) into v_m from public.member_ledger where source_type = 'investment' and source_id = v_inv;
    select coalesce(sum(amount), 0) into v_k from public.fund_reserve where source_type = 'allocation' and source_id = v_inv;
    res := res || format('S5 profit 3749.57 = member profits + remainder|%s|profit %s, members %s, reserve %s', case when v_n = 3749.57 and v_m + v_k = v_n and v_k >= 0 and v_k < 1 then 'PASS' else 'FAIL' end, v_n, v_m, v_k);
    -- a rejected purchase takes its approved cost items with it
    perform pg_temp.act(u_a); v_req := public.propose_investment('TEST cancelled', 'land', current_date, 100, null);
    perform pg_temp.act(u_a); v_req2 := public.add_investment_cost(v_req, 10, 'Stamp', current_date, null);
    perform pg_temp.act(u_a2); perform public.approve_investment_cost(v_req2);
    perform pg_temp.act(u_a2); perform public.reject_request(v_req, 'changed our mind');
    res := res || format('S5 rejecting a purchase rejects its approved cost items|%s|', case when (select status from public.money_requests where id = v_req2) = 'rejected' then 'PASS' else 'FAIL' end);
    res := res || format('S5 check_invariants after profit sale and cancelled purchase|%s|%s', case when pg_temp.inv_ok() then 'PASS' else 'FAIL' end, pg_temp.inv_bad());
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S5 scenario crashed|FAIL|' || msg); end if;
  end;

  -------------------------------------------------------------------- S6 cost after purchase, income and full reversal
  begin
    perform pg_temp.act(u_a); v_req := public.propose_investment('TEST plot rent', 'land', current_date, 2000, null);
    v_inv := pg_temp.buy(v_req, u_a2);
    perform pg_temp.act(u_a); v_req := public.add_investment_cost(v_inv, 100.03, 'Fence', current_date, null);
    perform pg_temp.act(u_a2); v_ex := public.approve_investment_cost(v_req);
    select count(*) into v_c from public.member_ledger l
     where l.source_id = v_ex and l.member_id not in (select member_id from public.investment_participation where investment_id = v_inv);
    select coalesce(sum(amount), 0) into v_m from public.member_ledger where source_id = v_ex;
    select coalesce(sum(amount), 0) into v_k from public.fund_reserve where source_id = v_ex;
    res := res || format('S6 cost after purchase charged only to participants, -100.03, leftover >= 0|%s|outsiders %s, members %s, reserve %s', case when v_c = 0 and v_m + v_k = -100.03 and v_k >= 0 then 'PASS' else 'FAIL' end, v_c, v_m, v_k);
    perform pg_temp.act(u_a); v_req := public.record_income(v_inv, 1000.01, current_date, 'rent', null);
    perform pg_temp.act(u_a2); v_inc := public.approve_income(v_req);
    select coalesce(sum(amount), 0) into v_m from public.member_ledger where source_id = v_inc;
    select coalesce(sum(amount), 0) into v_k from public.fund_reserve where source_id = v_inc;
    res := res || format('S6 income 1000.01 split exactly to participants|%s|members %s, reserve %s', case when v_m + v_k = 1000.01 then 'PASS' else 'FAIL' end, v_m, v_k);
    begin perform pg_temp.act(u_a); perform public.record_income(v_inv, -400, current_date, 'part', v_inc); res := res || 'S6 partial reversal refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S6 partial reversal refused|PASS|' || msg); end;
    perform pg_temp.act(u_a); v_req := public.record_income(v_inv, -1000.01, current_date, 'wrong entry', v_inc);
    perform pg_temp.act(u_a2); v_ex := public.approve_income(v_req);
    res := res || format('S6 full reversal mirrors the original rows|%s|', case when not exists (
        select 1 from public.allocations o full join (select * from public.allocations where event_id = v_ex) n
          on n.basis = o.basis and n.member_id is not distinct from o.member_id
         where o.event_id = v_inc and (n.id is null or n.amount <> -o.amount)) then 'PASS' else 'FAIL' end);
    begin perform pg_temp.act(u_a); perform public.record_income(v_inv, -1000.01, current_date, 'again', v_inc); res := res || 'S6 second reversal refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S6 second reversal refused|PASS|' || msg); end;
    begin perform pg_temp.act(u_a); perform public.record_income(v_inv, -5, current_date, 'no original', null); res := res || 'S6 negative income without original refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S6 negative income without original refused|PASS|' || msg); end;
    begin perform pg_temp.act(null); update public.investment_income set amount = 1 where id = v_inc; res := res || 'S6 edit income refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S6 edit income refused|PASS|' || msg); end;
    res := res || format('S6 check_invariants after cost, income, reversal|%s|%s', case when pg_temp.inv_ok() then 'PASS' else 'FAIL' end, pg_temp.inv_bad());
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S6 scenario crashed|FAIL|' || msg); end if;
  end;

  -------------------------------------------------------------------- S7 general expense 100000.01 across 7 members, then reversal
  begin
    perform pg_temp.act(null);
    update public.profiles set status = 'active', joined_on = current_date where id = u_p3;
    perform pg_temp.give(u_m, 20000.01); perform pg_temp.give(u_o, 20001.03); perform pg_temp.give(u_a, 20002.07);
    perform pg_temp.give(u_a2, 20003.11); perform pg_temp.give(u_s, 20004.13); perform pg_temp.give(u_p2, 20005.17); perform pg_temp.give(u_p3, 20006.19);
    perform pg_temp.act(u_a); v_req := public.propose_expense('TEST big expense', 100000.01, current_date);
    perform pg_temp.act(u_a2); v_ex := public.approve_expense(v_req);
    select coalesce(sum(amount), 0), count(*) into v_m, v_c from public.member_ledger where source_id = v_ex;
    select coalesce(sum(amount), 0) into v_k from public.fund_reserve where source_id = v_ex;
    res := res || format('S7 100000.01 split by equity: members + reserve = -100000.01, leftover >= 0|%s|%s members pay %s, reserve %s', case when v_m + v_k = -100000.01 and v_k >= 0 and v_k < 0.01 * (v_c + 1) then 'PASS' else 'FAIL' end, v_c, v_m, v_k);
    res := res || format('S7 split among ACTIVE members only|%s|', case when not exists (select 1 from public.member_ledger l join public.profiles p on p.id = l.member_id where l.source_id = v_ex and p.status <> 'active') then 'PASS' else 'FAIL' end);
    res := res || format('S7 expense: created_by = maker, approved_by = checker|%s|', case when exists (select 1 from public.expenses where id = v_ex and approved_by = u_a2 and created_by = u_a) then 'PASS' else 'FAIL' end);
    begin perform pg_temp.act(null); update public.expenses set amount = 1 where id = v_ex; res := res || 'S7 edit approved expense refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S7 edit approved expense refused|PASS|' || msg); end;
    -- reversal
    perform pg_temp.act(u_a); v_req := public.propose_expense_reversal(v_ex, 'entered twice');
    begin perform pg_temp.act(u_a); perform public.approve_expense_reversal(v_req); res := res || 'S7 own reversal approval refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S7 own reversal approval refused|PASS|' || msg); end;
    perform pg_temp.act(u_a2); v_inc := public.approve_expense_reversal(v_req);
    select coalesce(sum(amount), 0) into v_m from public.member_ledger where source_id = v_inc;
    select coalesce(sum(amount), 0) into v_k from public.fund_reserve where source_id = v_inc;
    res := res || format('S7 expense reversal gives back exactly 100000.01 (members + reserve)|%s|members %s, reserve %s', case when v_m + v_k = 100000.01 then 'PASS' else 'FAIL' end, v_m, v_k);
    begin perform pg_temp.act(u_a); perform public.propose_expense_reversal(v_ex, 'again'); res := res || 'S7 second expense reversal refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S7 second expense reversal refused|PASS|' || msg); end;
    res := res || format('S7 check_invariants after big expense and its reversal|%s|%s', case when pg_temp.inv_ok() then 'PASS' else 'FAIL' end, pg_temp.inv_bad());
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S7 scenario crashed|FAIL|' || msg); end if;
  end;

  -------------------------------------------------------------------- S8 money in land: cash check
  begin
    v_dep := pg_temp.give(u_m, 5000);
    perform pg_temp.act(null);
    select least((select cash_available from public.fund_totals_internal()),
                 (select sum(free) from public.member_balances_internal() where status = 'active' and joined_on <= current_date and free > 0)) - 1
      into v_n;
    perform pg_temp.act(u_a); v_req := public.propose_investment('TEST almost everything', 'land', current_date, round(v_n, 2), null);
    v_inv := pg_temp.buy(v_req, u_a2);
    begin
      perform pg_temp.act(null);
      insert into public.deposits (member_id, period_month, kind, amount, method, status, note, corrects_deposit_id)
      values (u_m, date_trunc('month', current_date)::date, 'monthly', -5000, 'cash', 'approved', 'correction', v_dep);
      res := res || 'S8 deposit correction while money is in land refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S8 deposit correction while money is in land refused|PASS|' || msg); end;
    perform pg_temp.act(u_a); v_req := public.add_investment_cost(v_inv, 500, 'Too expensive fence', current_date, null);
    begin perform pg_temp.act(u_a2); perform public.approve_investment_cost(v_req); res := res || 'S8 plot cost bigger than CASH refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S8 plot cost bigger than CASH refused|PASS|' || msg); end;
    perform pg_temp.act(u_a); v_req := public.propose_expense('TEST general too big', 500, current_date);
    begin perform pg_temp.act(u_a2); perform public.approve_expense(v_req); res := res || 'S8 general expense bigger than cash refused|FAIL|was allowed';
    exception when others then get stacked diagnostics msg = message_text; res := res || ('S8 general expense bigger than cash refused|PASS|' || msg); end;
    res := res || format('S8 check_invariants with money in land|%s|%s', case when pg_temp.inv_ok() then 'PASS' else 'FAIL' end, pg_temp.inv_bad());
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S8 scenario crashed|FAIL|' || msg); end if;
  end;

  -------------------------------------------------------------------- S9 FREE money runs out before CASH: allowed, members owe the pool
  begin
    perform pg_temp.act(null);
    update public.profiles set joined_on = current_date + 30 where id = u_p2;   -- P2 can not take part in the purchase
    perform pg_temp.act(null);
    select sum(free) - 1 into v_n from public.member_balances_internal()
     where status = 'active' and joined_on <= current_date and free > 0;
    perform pg_temp.act(u_a); v_req := public.propose_investment('TEST nearly all free money', 'land', current_date, round(v_n, 2), null);
    v_inv := pg_temp.buy(v_req, u_a2);
    perform pg_temp.give(u_p2, 50000);                                   -- plenty of cash, but not the participants'
    perform pg_temp.act(u_a); v_req := public.add_investment_cost(v_inv, 500, 'Boundary wall', current_date, null);
    perform pg_temp.act(u_a2); v_ex := public.approve_investment_cost(v_req);
    select count(*) into v_c from public.member_balances_internal() where free < 0;
    perform pg_temp.act(null);
    res := res || format('S9 plot cost beyond participants free money is allowed (they owe the pool)|%s|%s member(s) now below zero, cash %s', case when v_ex is not null and v_c > 0 then 'PASS' else 'FAIL' end, v_c, (select cash_available from public.fund_totals_internal()));
    res := res || format('S9 check_invariants with members owing the pool|%s|%s', case when pg_temp.inv_ok() then 'PASS' else 'FAIL' end, pg_temp.inv_bad());
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S9 scenario crashed|FAIL|' || msg); end if;
  end;

  -------------------------------------------------------------------- S10 the home-page formula with cents (100.00 + 0.10 expenses)
  begin
    perform pg_temp.act(u_a); v_req := public.propose_expense('TEST 100', 100.00, current_date);
    perform pg_temp.act(u_a2); perform public.approve_expense(v_req);
    perform pg_temp.act(u_a); v_req := public.propose_expense('TEST 0.10', 0.10, current_date);
    perform pg_temp.act(u_a2); perform public.approve_expense(v_req);
    perform pg_temp.act(u_a);
    select * into f from public.fund_summary();
    res := res || format('S10 total_fund = capital + late fees + income + profit - expenses + other reserve|%s|%s = %s + %s + %s + %s - %s + %s (rounding cents %s inside)',
      case when f.total_fund = f.capital + f.late_fees + f.investment_income + f.realized_profit - f.expenses + f.reserve_other then 'PASS' else 'FAIL' end,
      f.total_fund, f.capital, f.late_fees, f.investment_income, f.realized_profit, f.expenses, f.reserve_other, f.reserve_rounding);
    res := res || format('S10 reserve = late fees + rounding + other|%s|', case when f.reserve = f.reserve_late_fees + f.reserve_rounding + f.reserve_other then 'PASS' else 'FAIL' end);
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S10 scenario crashed|FAIL|' || msg); end if;
  end;

  -------------------------------------------------------------------- S11 bad input
  begin perform pg_temp.act(null);
    perform public.post_allocation('expense', gen_random_uuid(), -10, array[u_m], array[0::numeric], null, 'expense', 'expense', 'capital');
    res := res || 'S11 split with total weight 0 refused|FAIL|was allowed';
  exception when others then get stacked diagnostics msg = message_text; res := res || ('S11 split with total weight 0 refused|PASS|' || msg); end;
  begin perform pg_temp.act(null);
    perform public.post_allocation('expense', gen_random_uuid(), -10, array[u_m, u_o], array[5, null]::numeric[], null, 'expense', 'expense', 'capital');
    res := res || 'S11 split with a NULL weight refused|FAIL|was allowed';
  exception when others then get stacked diagnostics msg = message_text; res := res || ('S11 split with a NULL weight refused|PASS|' || msg); end;
  begin perform pg_temp.act(null);
    perform public.post_allocation('expense', gen_random_uuid(), -10, array[u_m, u_o], array[5, -1]::numeric[], null, 'expense', 'expense', 'capital');
    res := res || 'S11 split with a negative weight refused|FAIL|was allowed';
  exception when others then get stacked diagnostics msg = message_text; res := res || ('S11 split with a negative weight refused|PASS|' || msg); end;
  begin perform pg_temp.act(null);
    perform public.post_allocation('expense', gen_random_uuid(), -10, array[]::uuid[], array[]::numeric[], null, 'expense', 'expense', 'capital');
    res := res || 'S11 split with nobody refused|FAIL|was allowed';
  exception when others then get stacked diagnostics msg = message_text; res := res || ('S11 split with nobody refused|PASS|' || msg); end;
  begin perform pg_temp.act(u_a); perform public.propose_investment('TEST old', 'land', date '2019-06-01', 10, null); res := res || 'S11 date before the samiti start refused|FAIL|was allowed';
  exception when others then get stacked diagnostics msg = message_text; res := res || ('S11 date before the samiti start refused|PASS|' || msg); end;
  begin perform pg_temp.act(u_a); perform public.propose_expense('TEST future', 10, current_date + 10); res := res || 'S11 date more than 3 days ahead refused|FAIL|was allowed';
  exception when others then get stacked diagnostics msg = message_text; res := res || ('S11 date more than 3 days ahead refused|PASS|' || msg); end;

  -------------------------------------------------------------------- S12 direct writes / calls by API roles
  begin execute 'set local role anon'; perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform public.propose_investment('x', 'land', current_date, 1, null); res := res || 'S12 anon calls propose_investment refused|FAIL|was allowed';
  exception when others then get stacked diagnostics msg = message_text; res := res || ('S12 anon calls propose_investment refused|PASS|' || msg); end;
  begin perform pg_temp.act(u_m); execute 'set local role authenticated';
    perform public.propose_expense('x', 1, current_date); res := res || 'S12 member calls propose_expense refused|FAIL|was allowed';
  exception when others then get stacked diagnostics msg = message_text; res := res || ('S12 member calls propose_expense refused|PASS|' || msg); end;
  begin perform pg_temp.act(u_a); execute 'set local role authenticated';
    insert into public.expenses (title, amount, spent_on, created_by) values ('x', 1, current_date, u_a2);
    res := res || 'S12 admin inserts expenses directly refused|FAIL|was allowed';
  exception when others then get stacked diagnostics msg = message_text; res := res || ('S12 admin inserts expenses directly refused|PASS|' || msg); end;
  begin perform pg_temp.act(u_a); execute 'set local role authenticated';
    perform public.post_allocation('expense', gen_random_uuid(), -10, array[u_m], array[1::numeric], null, 'expense', 'expense', 'capital');
    res := res || 'S12 admin calls internal post_allocation refused|FAIL|was allowed';
  exception when others then get stacked diagnostics msg = message_text; res := res || ('S12 admin calls internal post_allocation refused|PASS|' || msg); end;
  begin execute 'set local role service_role';
    perform public.take_fund_lock(); res := res || 'S12 service_role calls take_fund_lock refused|FAIL|was allowed';
  exception when others then get stacked diagnostics msg = message_text; res := res || ('S12 service_role calls take_fund_lock refused|PASS|' || msg); end;
  begin execute 'set local role service_role';
    perform public.approve_investment(gen_random_uuid(), 1); res := res || 'S12 service_role calls approve_investment refused|FAIL|was allowed';
  exception when others then get stacked diagnostics msg = message_text; res := res || ('S12 service_role calls approve_investment refused|PASS|' || msg); end;
  begin execute 'set local role service_role';
    insert into public.investments (title, purchase_date, cost) values ('x', current_date, 1);
    res := res || 'S12 service_role inserts investments refused|FAIL|was allowed';
  exception when others then get stacked diagnostics msg = message_text; res := res || ('S12 service_role inserts investments refused|PASS|' || msg); end;
  begin
    perform pg_temp.act(u_a); v_req := public.propose_expense('TEST hidden', 5, current_date);
    perform pg_temp.act(u_m); execute 'set local role authenticated';
    select count(*) into v_c from public.money_requests;
    execute 'reset role';
    res := res || format('S12 members cannot see admin requests|%s|member sees %s', case when v_c = 0 then 'PASS' else 'FAIL' end, v_c);
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S12 visibility scenario crashed|FAIL|' || msg); end if;
  end;

  -------------------------------------------------------------------- S13 check_invariants notices each simulated bug (owner + posting flag)
  -- a) a split amount that does not match its weight
  begin perform pg_temp.act(u_a); v_req := public.propose_expense('TEST w', 10, current_date);
    perform pg_temp.act(u_a2); v_ex := public.approve_expense(v_req);
    perform pg_temp.act(null); perform set_config('fd.posting', 'on', true);
    insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total, weight, weight_sum)
    values ('expense', v_ex, 'shares', u_m, -9, -10, 1, 2), ('expense', v_ex, 'shares', null, -1, -10, null, 2);
    res := res || format('S13a wrong split amount caught|%s|', case when pg_temp.rule_fails('split amounts recompute from weights') then 'PASS' else 'FAIL' end);
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S13a crashed|FAIL|' || msg); end if; end;
  -- b) a plot result reaching an outsider
  begin perform pg_temp.act(u_a); v_req := public.propose_investment('TEST plot b', 'land', current_date, 1000, null);
    v_inv := pg_temp.buy(v_req, u_a2);
    perform pg_temp.act(null); perform set_config('fd.posting', 'on', true);
    insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total, weight, weight_sum)
    values ('sale', v_inv, 'shares', u_p3, 5, 5, 1, 1);
    res := res || format('S13b result to a non-participant caught|%s|', case when pg_temp.rule_fails('plot results only reach its participants') then 'PASS' else 'FAIL' end);
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S13b crashed|FAIL|' || msg); end if; end;
  -- c) an expense row with no approved request
  begin perform pg_temp.act(null); perform set_config('fd.posting', 'on', true);
    insert into public.expenses (title, amount, spent_on, created_by, approved_by) values ('TEST stray', 10, current_date, u_a, u_a2);
    res := res || format('S13c money row without a request caught|%s|', case when pg_temp.rule_fails('each money row has exactly one approved request') then 'PASS' else 'FAIL' end);
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S13c crashed|FAIL|' || msg); end if; end;
  -- d) capitalized costs that no approved cost item explains
  begin perform pg_temp.act(null); perform set_config('fd.posting', 'on', true);
    insert into public.investments (title, purchase_date, cost, capitalized_costs, created_by, approved_by)
    values ('TEST cap', current_date, 10, 5, u_a, u_a2) returning id into v_inv;
    insert into public.money_requests (kind, status, title, investment_kind, amount, event_date, proposed_by, proposed_at, decided_by, decided_at, result_id)
    values ('purchase', 'approved', 'TEST cap', 'land', 10, current_date, u_a, now(), u_a2, now(), v_inv);
    res := res || format('S13d capitalized costs without cost items caught|%s|', case when pg_temp.rule_fails('capitalized costs = approved cost items') then 'PASS' else 'FAIL' end);
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S13d crashed|FAIL|' || msg); end if; end;
  -- e) an approved request with no decider
  begin perform pg_temp.act(null); perform set_config('fd.posting', 'on', true);
    insert into public.money_requests (kind, status, title, amount, event_date, proposed_by, proposed_at, decided_by, decided_at)
    values ('expense', 'approved', 'TEST nobody decided', 1, current_date, u_a, now(), null, now());
    res := res || format('S13e approved request without a decider caught|%s|', case when pg_temp.rule_fails('two people per decision (or the import batch)') then 'PASS' else 'FAIL' end);
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S13e crashed|FAIL|' || msg); end if; end;
  -- f) a purchase contribution that is negative / more than the free money then
  begin perform pg_temp.act(u_a); v_req := public.propose_investment('TEST plot f', 'land', current_date, 1000, null);
    v_inv := pg_temp.buy(v_req, u_a2);
    perform pg_temp.act(null); perform set_config('fd.posting', 'on', true);
    insert into public.investment_participation (investment_id, member_id, contribution_delta, capital_at_purchase, shares_at_purchase, free_at_purchase, reason)
    values (v_inv, u_p3, 50, 0, 0, 10, 'purchase');
    res := res || format('S13f contribution above free money caught|%s|', case when pg_temp.rule_fails('purchase: 0 < contribution <= free money then') then 'PASS' else 'FAIL' end);
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S13f crashed|FAIL|' || msg); end if; end;
  -- g) a reserve leftover below zero
  begin perform pg_temp.act(u_a); v_req := public.propose_expense('TEST g', 10, current_date);
    perform pg_temp.act(u_a2); v_ex := public.approve_expense(v_req);
    perform pg_temp.act(null); perform set_config('fd.posting', 'on', true);
    insert into public.allocations (event_type, event_id, basis, member_id, amount, event_total, weight, weight_sum)
    values ('expense', v_ex, 'shares', u_m, -9.99, -10, 1, 1), ('expense', v_ex, 'shares', null, -0.01, -10, null, 1);
    res := res || format('S13g negative reserve leftover caught|%s|', case when pg_temp.rule_fails('reserve leftover >= 0') then 'PASS' else 'FAIL' end);
    raise exception using errcode = 'P0098', message = 'rollback';
  exception when others then get stacked diagnostics msg = message_text, st = returned_sqlstate;
    if st <> 'P0098' then res := res || ('S13g crashed|FAIL|' || msg); end if; end;

  -------------------------------------------------------------------- the real books
  res := res || format('real books pass check_invariants|%s|%s', case when pg_temp.inv_ok() then 'PASS' else 'FAIL' end, pg_temp.inv_bad());

  insert into t6b_results (test, result, detail)
  select split_part(x, '|', 1), split_part(x, '|', 2), substr(x, length(split_part(x, '|', 1)) + length(split_part(x, '|', 2)) + 3)
    from unnest(res) x;
end $$;

select n, test, result, detail from t6b_results order by n;
