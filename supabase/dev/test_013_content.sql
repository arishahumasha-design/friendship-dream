-- DEV / TEST ONLY. Tries to BREAK every 013 rule (notices pin, policies, site_content), as:
--   anon (logged-out), pending (logged in, not active), member, admin, super admin,
--   service_role (with and without a super admin JWT) and the SQL Editor (database owner).
-- NOTHING is kept: everything runs inside one block that is rolled back at the end
-- (each attempt also runs in its own sub-transaction). Only the result table remains (temp).
-- Run in Supabase SQL Editor AFTER 013. The last table shows PASS / FAIL per rule.

create temp table if not exists t013_results (n serial, test text, result text, detail text);
truncate t013_results;

-- Run statements as someone. Returns 'ok:<value of the last statement>' or 'err:<sqlstate>:<message>'.
-- A non-select statement gives 'ok:rows=<n>'. The marker '#owner' switches back to the SQL Editor
-- inside the same attempt (to look at the result). Everything is rolled back afterwards.
create or replace function pg_temp.probe(p_who text, p_sql text[]) returns text language plpgsql as $f$
declare
  v_uid uuid := (select id from public.profiles where email = case p_who
                    when 'member'        then 'fd.test.member@example.com'
                    when 'admin'         then 'fd.test.admin@example.com'
                    when 'super'         then 'fd.test.super@example.com'
                    when 'service_super' then 'fd.test.super@example.com'
                    when 'pending'       then 'fd.test.pending3@example.com' end);
  v text; n bigint; s text;
begin
  begin
    if p_who = 'anon' then
      execute 'set local role anon'; perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    elsif p_who in ('service', 'service_super') then
      execute 'set local role service_role';
      perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'service_role')::text, true);
    elsif p_who = 'owner' then
      perform set_config('request.jwt.claims', '', true);
    else
      execute 'set local role authenticated';
      perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    end if;
    foreach s in array p_sql loop
      if s = '#owner' then
        execute 'reset role'; perform set_config('request.jwt.claims', '', true);
      elsif lower(ltrim(s)) like 'select%' then
        execute s into v;
      else
        execute s; get diagnostics n = row_count; v := 'rows=' || n;
      end if;
    end loop;
    raise exception using errcode = 'P0099', message = 'ok:' || coalesce(v, 'null');
  exception when others then
    return case when sqlstate = 'P0099' then sqlerrm else 'err:' || sqlstate || ':' || sqlerrm end;
  end;
end $f$;

do $$
declare
  res text[] := '{}';
  r   text;
  pol uuid; pol2 uuid; ntc uuid;
  u_s uuid := (select id from public.profiles where email = 'fd.test.super@example.com');
  u_a uuid := (select id from public.profiles where email = 'fd.test.admin@example.com');
  v   text;
begin
  begin   -- everything below is rolled back at the end (P0097)
    perform set_config('request.jwt.claims', '', true);
    -- test rows, written as the SQL Editor (also proves the seed path still works)
    insert into public.policies (sort_order, title, body) values (9001, 'TEST 013 policy', 'TEST body') returning id into pol;
    insert into public.policies (sort_order, title, body, is_current) values (9002, 'TEST 013 hidden', 'TEST body', false) returning id into pol2;
    insert into public.site_content (key, body_en, body_bn) values ('home_message_3', 'TEST m3', 'TEST m3')
      on conflict (key) do update set body_en = 'TEST m3';
    insert into public.notices (title, body, created_by) values ('TEST 013 notice', 'TEST', u_a) returning id into ntc;
    res := res || format('owner (SQL Editor): can insert policies / site_content / notices|PASS|%s', pol);

    ------------------------------------------------------------------ anon
    r := pg_temp.probe('anon', array['select string_agg(key, '','' order by key) from public.site_content']);
    res := res || format('anon: reads ONLY home_message_1..3 from site_content|%s|%s',
      case when r like 'ok:%' and r not like '%about%' and r like '%home_message_1%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('anon', array['select count(*)::text from public.site_content where key not like ''home_message_%''']);
    res := res || format('anon: non-public keys invisible|%s|%s', case when r = 'ok:0' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('anon', array['select count(*)::text from public.policies']);
    res := res || format('anon: cannot read policies|%s|%s', case when r like 'err:%' or r = 'ok:0' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('anon', array['select count(*)::text from public.notices']);
    res := res || format('anon: cannot read notices|%s|%s', case when r like 'err:%' or r = 'ok:0' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('anon', array['update public.site_content set body_en = ''hack'' where key = ''home_message_1''']);
    res := res || format('anon: cannot update site_content|%s|%s', case when r like 'err:%' or r = 'ok:rows=0' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('anon', array['insert into public.policies (title, body) values (''x'', ''x'')']);
    res := res || format('anon: cannot insert policies|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);

    ------------------------------------------------------------------ pending (logged in, not active)
    r := pg_temp.probe('pending', array['select string_agg(key, '','' order by key) from public.site_content']);
    res := res || format('pending: reads only the public keys|%s|%s',
      case when r like 'ok:%' and r not like '%about%' and r like '%home_message_1%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('pending', array['select count(*)::text from public.policies']);
    res := res || format('pending: sees no policies|%s|%s', case when r = 'ok:0' then 'PASS' else 'FAIL' end, r);

    ------------------------------------------------------------------ member
    r := pg_temp.probe('member', array[format('select count(*)::text from public.policies where id = %L', pol)]);
    res := res || format('member: reads policies|%s|%s', case when r = 'ok:1' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('member', array['select count(*)::text from public.site_content where key = ''about''']);
    res := res || format('member: reads about (non-public key)|%s|%s', case when r = 'ok:1' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('member', array['insert into public.policies (title, body) values (''x'', ''x'')']);
    res := res || format('member: cannot insert policies|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('member', array[format('update public.policies set title = ''hack'' where id = %L', pol)]);
    res := res || format('member: cannot update policies|%s|%s', case when r like 'err:%' or r = 'ok:rows=0' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('member', array['update public.site_content set body_en = ''hack'' where key = ''about''']);
    res := res || format('member: cannot update site_content|%s|%s', case when r like 'err:%' or r = 'ok:rows=0' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('member', array['insert into public.notices (title, body, pinned) values (''x'', ''x'', true)']);
    res := res || format('member: cannot post / pin a notice|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('member', array[format('update public.notices set pinned = true where id = %L', ntc)]);
    res := res || format('member: cannot pin an existing notice|%s|%s', case when r like 'err:%' or r = 'ok:rows=0' then 'PASS' else 'FAIL' end, r);

    ------------------------------------------------------------------ admin (normal)
    r := pg_temp.probe('admin', array['insert into public.policies (title, body) values (''x'', ''x'')']);
    res := res || format('admin: cannot insert policies|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('admin', array[format('update public.policies set title = ''hack'' where id = %L', pol)]);
    res := res || format('admin: cannot update policies|%s|%s', case when r like 'err:%' or r = 'ok:rows=0' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('admin', array[format('update public.policies set is_current = false where id = %L', pol)]);
    res := res || format('admin: cannot hide policies|%s|%s', case when r like 'err:%' or r = 'ok:rows=0' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('admin', array[format('delete from public.policies where id = %L', pol)]);
    res := res || format('admin: cannot delete policies|%s|%s', case when r like 'err:%' or r = 'ok:rows=0' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('admin', array['truncate public.policies']);
    res := res || format('admin: cannot truncate policies|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('admin', array['insert into public.site_content (key, body_en) values (''home_message_9'', ''x'')']);
    res := res || format('admin: cannot insert site_content|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('admin', array['update public.site_content set body_en = ''hack'' where key = ''home_message_1''']);
    res := res || format('admin: cannot update site_content|%s|%s', case when r like 'err:%' or r = 'ok:rows=0' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('admin', array['delete from public.site_content where key = ''about''']);
    res := res || format('admin: cannot delete site_content|%s|%s', case when r like 'err:%' or r = 'ok:rows=0' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('admin', array['truncate public.site_content']);
    res := res || format('admin: cannot truncate site_content|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    -- second layer: even with RLS switched off (owner does it inside the attempt), the trigger refuses an admin
    r := pg_temp.probe('owner', array['alter table public.policies disable row level security',
                                      'set local role authenticated',
                                      format('select set_config(''request.jwt.claims'', %L, true)', json_build_object('sub', u_a, 'role', 'authenticated')::text),
                                      format('update public.policies set title = ''hack'' where id = %L', pol)]);
    res := res || format('admin: trigger refuses even without RLS (2nd layer)|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);
    -- admin and notices: post pinned, unpin, pinned_at by hand
    r := pg_temp.probe('admin', array['insert into public.notices (title, body, pinned, pinned_at) values (''TEST p'', ''x'', true, ''2000-01-01'')',
                                      '#owner',
                                      'select (pinned and pinned_at > now() - interval ''1 minute'')::text from public.notices where title = ''TEST p''']);
    res := res || format('admin: posts a pinned notice, pinned_at set by DB|%s|%s', case when r = 'ok:true' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('admin', array[format('update public.notices set pinned = true where id = %L', ntc),
                                      format('update public.notices set pinned = false where id = %L', ntc),
                                      '#owner',
                                      format('select (not pinned and pinned_at is null)::text from public.notices where id = %L', ntc)]);
    res := res || format('admin: pins and unpins a notice|%s|%s', case when r = 'ok:true' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('admin', array[format('update public.notices set pinned_at = ''2000-01-01'' where id = %L', ntc),
                                      '#owner',
                                      format('select (pinned_at is null)::text from public.notices where id = %L', ntc)]);
    res := res || format('admin: cannot set pinned_at by hand|%s|%s', case when r = 'ok:true' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('admin', array['update public.notices set pinned = false where false',
                                      format('select count(*)::text from public.notices where id = %L', ntc)]);
    res := res || format('admin: still reads notices|%s|%s', case when r = 'ok:1' then 'PASS' else 'FAIL' end, r);

    ------------------------------------------------------------------ super admin
    r := pg_temp.probe('super', array[format('insert into public.policies (title, body, created_by, created_at) values (''TEST s'', ''x'', %L, ''2000-01-01'')', u_a),
                                      '#owner',
                                      format('select (created_by = %L and created_at > now() - interval ''1 minute'')::text from public.policies where title = ''TEST s''', u_s)]);
    res := res || format('super: inserts a policy (created_by / created_at set by DB)|%s|%s', case when r = 'ok:true' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('super', array[format('update public.policies set title = ''TEST edited'', sort_order = 1, created_by = %L where id = %L', u_a, pol),
                                      '#owner',
                                      format('select (title = ''TEST edited'' and sort_order = 1 and created_by is distinct from %L)::text from public.policies where id = %L', u_a, pol)]);
    res := res || format('super: edits / reorders a policy, created_by kept|%s|%s', case when r = 'ok:true' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('super', array[format('update public.policies set is_current = false where id = %L', pol),
                                      '#owner',
                                      format('select count(*)::text from public.audit_log where table_name = ''policies'' and record_id = %L and action = ''UPDATE'' and actor_id = %L', pol, u_s)]);
    res := res || format('super: hides a policy, audit-logged with actor|%s|%s', case when r = 'ok:1' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('super', array[format('delete from public.policies where id = %L', pol)]);
    res := res || format('super: cannot delete policies|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('super', array['truncate public.policies']);
    res := res || format('super: cannot truncate policies|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('super', array['update public.site_content set body_en = ''TEST new'' where key = ''about''',
                                      '#owner',
                                      'select (body_en = ''TEST new'' and updated_at > now() - interval ''1 minute'')::text || '','' || (select count(*) from public.audit_log a where a.table_name = ''site_content'' and a.record_id = ''about'' and a.actor_id = ''' || u_s || ''') from public.site_content where key = ''about''']);
    res := res || format('super: edits site_content, audit-logged|%s|%s', case when r = 'ok:true,1' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('super', array['insert into public.site_content (key, body_en, body_bn) values (''about_start'', ''June 2025'', ''জুন ২০২৫'')']);
    res := res || format('super: inserts a site_content key|%s|%s', case when r = 'ok:rows=1' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('super', array['update public.site_content set key = ''about2'' where key = ''about''']);
    res := res || format('super: cannot rename a site_content key|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('super', array['delete from public.site_content where key = ''about''']);
    res := res || format('super: cannot delete site_content|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('super', array['truncate public.site_content']);
    res := res || format('super: cannot truncate site_content|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('super', array[format('select count(*)::text from public.policies where id in (%L, %L)', pol, pol2)]);
    res := res || format('super: reads hidden policies too|%s|%s', case when r = 'ok:2' then 'PASS' else 'FAIL' end, r);

    ------------------------------------------------------------------ service_role
    r := pg_temp.probe('service', array['insert into public.policies (title, body) values (''x'', ''x'')']);
    res := res || format('service_role: cannot insert policies|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('service', array[format('update public.policies set title = ''hack'' where id = %L', pol)]);
    res := res || format('service_role: cannot update policies|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('service', array[format('delete from public.policies where id = %L', pol)]);
    res := res || format('service_role: cannot delete policies|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('service', array['truncate public.policies']);
    res := res || format('service_role: cannot truncate policies|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('service', array['update public.site_content set body_en = ''hack'' where key = ''home_message_1''']);
    res := res || format('service_role: cannot update site_content|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('service', array['delete from public.site_content where key = ''about''']);
    res := res || format('service_role: cannot delete site_content|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('service', array['truncate public.site_content']);
    res := res || format('service_role: cannot truncate site_content|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('service', array['select count(*)::text from public.site_content']);
    res := res || format('service_role: can still read site_content|%s|%s', case when r like 'ok:%' and r <> 'ok:0' then 'PASS' else 'FAIL' end, r);
    -- second layer: even if someone grants writes back to service_role, the trigger refuses (also with a super admin JWT)
    r := pg_temp.probe('owner', array['grant insert, update, delete on public.policies, public.site_content to service_role',
                                      'set local role service_role',
                                      format('select set_config(''request.jwt.claims'', %L, true)', json_build_object('sub', u_s, 'role', 'service_role')::text),
                                      format('update public.policies set title = ''hack'' where id = %L', pol)]);
    res := res || format('service_role + super JWT: trigger refuses policy update (2nd layer)|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('owner', array['grant insert, update, delete on public.policies, public.site_content to service_role',
                                      'set local role service_role',
                                      'update public.site_content set body_en = ''hack'' where key = ''home_message_1''']);
    res := res || format('service_role: trigger refuses site_content update (2nd layer)|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('owner', array['grant insert, update, delete on public.policies, public.site_content to service_role',
                                      'set local role service_role',
                                      'delete from public.site_content where key = ''about''']);
    res := res || format('service_role: trigger refuses site_content delete (2nd layer)|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('owner', array['grant select, insert, update on public.notices to service_role',
                                      'set local role service_role',
                                      format('update public.notices set pinned = true where id = %L', ntc)]);
    res := res || format('service_role: cannot pin a notice (2nd layer)|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);

    ------------------------------------------------------------------ SQL Editor (owner)
    r := pg_temp.probe('owner', array[format('delete from public.policies where id = %L', pol)]);
    res := res || format('owner (SQL Editor): cannot delete policies|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('owner', array['truncate public.policies']);
    res := res || format('owner (SQL Editor): cannot truncate policies|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('owner', array['delete from public.site_content where key = ''about''']);
    res := res || format('owner (SQL Editor): cannot delete site_content|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe('owner', array['truncate public.site_content']);
    res := res || format('owner (SQL Editor): cannot truncate site_content|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);

    ------------------------------------------------------------------ nothing else lets a normal admin write them
    select string_agg(p.proname, ', ') into v
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname not in ('content_write_guard', 'notices_pin_guard')
       and p.prosrc ~* '(insert[[:space:]]+into|update|delete[[:space:]]+from|truncate)[[:space:]]+(table[[:space:]]+)?(only[[:space:]]+)?(public[.])?(policies|site_content)([^a-z_]|$)';
    res := res || format('no function writes policies / site_content|%s|%s', case when v is null then 'PASS' else 'FAIL' end, coalesce(v, 'none'));
    select string_agg(tablename || '.' || policyname || ':' || cmd, ', ') into v
      from pg_policies
     where schemaname = 'public' and tablename in ('policies', 'site_content') and cmd <> 'SELECT'
       and position('is_super_admin()' in coalesce(with_check, '') || coalesce(qual, '')) = 0;
    res := res || format('every write RLS policy needs the super admin|%s|%s', case when v is null then 'PASS' else 'FAIL' end, coalesce(v, 'none'));
    select string_agg(grantee || ':' || table_name || ':' || privilege_type, ', ') into v
      from information_schema.role_table_grants
     where table_schema = 'public' and table_name in ('policies', 'site_content')
       and grantee in ('PUBLIC', 'anon', 'authenticated', 'service_role')
       and (privilege_type in ('DELETE', 'TRUNCATE') or (grantee <> 'authenticated' and privilege_type <> 'SELECT'));
    res := res || format('no delete / truncate grants; anon + service_role read only|%s|%s', case when v is null then 'PASS' else 'FAIL' end, coalesce(v, 'none'));

    raise exception using errcode = 'P0097', message = 'roll back';
  exception when sqlstate 'P0097' then null;
  end;

  -- the real data is untouched and the books still balance
  perform set_config('request.jwt.claims', '', true);
  res := res || format('test rows are gone (rolled back)|%s|',
    case when not exists (select 1 from public.policies where title like 'TEST 013%') then 'PASS' else 'FAIL' end);
  select coalesce(string_agg(c.rule || ' [' || c.detail || ']', '; '), 'all ok') into v from public.check_invariants(false) c where not c.ok;
  res := res || format('check_invariants all ok|%s|%s', case when v = 'all ok' then 'PASS' else 'FAIL' end, v);

  insert into t013_results (test, result, detail)
  select split_part(x, '|', 1), split_part(x, '|', 2), substr(x, length(split_part(x, '|', 1)) + length(split_part(x, '|', 2)) + 3)
    from unnest(res) x;
end $$;

select n, test, result, detail from t013_results order by n;
