-- DEV / TEST ONLY. Tries to BREAK every 014 rule (email, text limits, storage uploads, file paths,
-- audit_log, anon), as anon, pending, member, admin, super admin, service_role and the SQL Editor.
-- NOTHING is kept: everything runs inside one block that is rolled back at the end.
-- Run in Supabase SQL Editor AFTER 014. The last table shows PASS / FAIL per rule.

create temp table if not exists t014_results (n serial, test text, result text, detail text);
truncate t014_results;

-- Switch to someone inside the current sub-transaction.
create or replace function pg_temp.become(p_who text) returns void language plpgsql as $f$
declare v_uid uuid := (select id from public.profiles where email = case p_who
                         when 'member'  then 'fd.test.member@example.com'
                         when 'other'   then 'fd.test.other@example.com'
                         when 'admin'   then 'fd.test.admin@example.com'
                         when 'super'   then 'fd.test.super@example.com'
                         when 'pending' then 'fd.test.pending3@example.com' end);
begin
  if p_who = 'anon' then
    execute 'set local role anon'; perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  elsif p_who = 'service' then
    execute 'set local role service_role'; perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  elsif p_who = 'owner' then
    execute 'reset role'; perform set_config('request.jwt.claims', '', true);
  else
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  end if;
end $f$;

-- Run statements; '@who' switches identity, '#owner' = SQL Editor. Returns 'ok:<last value>' or 'err:<state>:<msg>'.
create or replace function pg_temp.probe(p_sql text[]) returns text language plpgsql as $f$
declare v text; n bigint; s text;
begin
  begin
    foreach s in array p_sql loop
      if s like '@%' then perform pg_temp.become(substr(s, 2));
      elsif s = '#owner' then execute 'reset role'; perform set_config('request.jwt.claims', '', true);
      elsif lower(ltrim(s)) like 'select%' then execute s into v;
      else execute s; get diagnostics n = row_count; v := 'rows=' || n;
      end if;
    end loop;
    raise exception using errcode = 'P0099', message = 'ok:' || coalesce(v, 'null');
  exception when others then
    return case when sqlstate = 'P0099' then sqlerrm else 'err:' || sqlstate || ':' || sqlerrm end;
  end;
end $f$;

do $$
declare
  res  text[] := '{}';
  r    text;
  v    text;
  u_m  uuid := (select id from public.profiles where email = 'fd.test.member@example.com');
  u_o  uuid := (select id from public.profiles where email = 'fd.test.other@example.com');
  u_a  uuid := (select id from public.profiles where email = 'fd.test.admin@example.com');
  u_s  uuid := (select id from public.profiles where email = 'fd.test.super@example.com');
  u_p  uuid := (select id from public.profiles where email = 'fd.test.pending3@example.com');
  long201 text := repeat('x', 201);
  g    text := 'grant select, insert, update on storage.objects to authenticated';   -- Supabase has this; the local stub not
  ok_name text;
begin
  begin   -- everything below is rolled back at the end (P0097)
    perform set_config('request.jwt.claims', '', true);

    ------------------------------------------------------------------ 1) email
    r := pg_temp.probe(array['@member', format('update public.profiles set email = ''hack@example.com'' where id = %L', u_m),
                             '#owner', format('select email from public.profiles where id = %L', u_m)]);
    res := res || format('email: member cannot change own profile email|%s|%s', case when r = 'ok:fd.test.member@example.com' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['@super', format('update public.profiles set email = ''hack@example.com'' where id = %L', u_m),
                             '#owner', format('select email from public.profiles where id = %L', u_m)]);
    res := res || format('email: super admin cannot change a profile email|%s|%s', case when r = 'ok:fd.test.member@example.com' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['grant update, select on public.profiles to service_role', '@service',
                             format('update public.profiles set email = ''hack@example.com'' where id = %L', u_m),
                             '#owner', format('select email from public.profiles where id = %L', u_m)]);
    res := res || format('email: service_role cannot change a profile email (trigger)|%s|%s', case when r = 'ok:fd.test.member@example.com' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', format('update public.profiles set email = ''changed@example.com'' where id = %L', u_m),
                             format('select email from public.profiles where id = %L', u_m)]);
    res := res || format('email: SQL Editor can change a profile email|%s|%s', case when r = 'ok:changed@example.com' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', format('update auth.users set email = ''new.login@example.com'' where id = %L', u_m),
                             format('select email from public.profiles where id = %L', u_m)]);
    res := res || format('email: auth.users change is copied to profiles|%s|%s', case when r = 'ok:new.login@example.com' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', format('update public.profiles set email = ''FD.TEST.MEMBER@example.com'' where id = %L', u_o)]);
    res := res || format('email: same email (other case) on two profiles refused|%s|%s', case when r like 'err:23505:%' then 'PASS' else 'FAIL' end, r);
    -- import steps find accounts by CONFIRMED auth.users email (profile email is not the key)
    r := pg_temp.probe(array['#owner', format('update public.profiles set email = ''elsewhere@example.com'' where id = %L', u_m),
          'select string_agg(coalesce(full_name, ''-'') || ''='' || problem, '';'') from public.import_verify(''{"joined_on":"2025-06-01","members":[{"sr_no":1,"sheet_name":"A","email":"fd.test.member@example.com"}]}''::jsonb) where sr_no = 1']);
    res := res || format('import_verify: finds the member by auth.users email|%s|%s', case when r like 'ok:Test Member One=%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', format('update auth.users set email_confirmed_at = null where id = %L', u_m),
          'select problem from public.import_verify(''{"joined_on":"2025-06-01","members":[{"sr_no":1,"sheet_name":"A","email":"fd.test.member@example.com"}]}''::jsonb) where sr_no = 1']);
    res := res || format('import_verify: unconfirmed email is a problem|%s|%s', case when r = 'ok:email not confirmed yet' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', format('update auth.users set email_confirmed_at = null where id = %L', u_m),
          'select (public.import_confirm_code(''{"members":[{"sr_no":1,"email":"fd.test.member@example.com"}]}''::jsonb) = md5(''|'' || md5(''{"members":[{"sr_no":1,"email":"fd.test.member@example.com"}]}''::jsonb::text)))::text']);
    res := res || format('import_confirm_code: unconfirmed email not mapped|%s|%s', case when r = 'ok:true' then 'PASS' else 'FAIL' end, r);
    select position('email_confirmed_at is not null' in pg_get_functiondef('public.import_apply(jsonb)'::regprocedure)) > 0
       and position('lower(pr.email)' in pg_get_functiondef('public.import_apply(jsonb)'::regprocedure)) = 0 into v;
    res := res || format('import_apply: map joins confirmed auth.users emails|%s|', case when v = 'true' then 'PASS' else 'FAIL' end);

    ------------------------------------------------------------------ 2a) length limits
    r := pg_temp.probe(array['@admin', format('insert into public.notices (title, body) values (%L, ''x'')', long201)]);
    res := res || format('length: notice title > 200 refused|%s|%s', case when r like 'err:23514:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['@member', format('update public.profiles set full_name = %L where id = %L', long201, u_m)]);
    res := res || format('length: profile full_name > 200 refused|%s|%s', case when r like 'err:23514:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['@member', format('update public.profiles set phone = %L where id = %L', repeat('1', 31), u_m)]);
    res := res || format('length: profile phone > 30 refused|%s|%s', case when r like 'err:23514:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', format('insert into public.nominees (member_id, name) values (%L, %L)', u_m, long201)]);
    res := res || format('length: nominee name > 200 refused (even SQL Editor)|%s|%s', case when r like 'err:23514:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['@member', format('update public.profiles set full_name = %L where id = %L', repeat('ক', 200), u_m)]);
    res := res || format('length: 200 Bengali letters still allowed|%s|%s', case when r = 'ok:rows=1' then 'PASS' else 'FAIL' end, r);
    select count(*)::text into v from pg_constraint where conname like '%\_len' escape '\' and connamespace = 'public'::regnamespace;
    res := res || format('length: limit constraints in place|%s|%s', case when v::int >= 38 then 'PASS' else 'FAIL' end, v || ' constraints');

    ------------------------------------------------------------------ 2b) storage uploads
    ok_name := u_p || '/abcdef12-3456.jpg';
    r := pg_temp.probe(array[g, '@pending', format('insert into storage.objects (bucket_id, name, owner) values (''documents'', %L, %L)', ok_name, u_p)]);
    res := res || format('storage: pending member uploads a document|%s|%s', case when r = 'ok:rows=1' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array[g, '@pending', format('insert into storage.objects (bucket_id, name, owner) values (''receipts'', %L, %L)', ok_name, u_p)]);
    res := res || format('storage: pending member cannot upload a receipt|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array[g, '@member', format('insert into storage.objects (bucket_id, name, owner) values (''receipts'', %L, %L)', u_m || '/0123456789abcdef.png', u_m)]);
    res := res || format('storage: active member uploads a receipt|%s|%s', case when r = 'ok:rows=1' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array[g, format('update public.profiles set status = ''suspended'' where id = %L', u_m), '@member',
                             format('insert into storage.objects (bucket_id, name, owner) values (''documents'', %L, %L)', u_m || '/abcdef12-3456.jpg', u_m)]);
    res := res || format('storage: suspended member cannot upload|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array[g, '@member', format('insert into storage.objects (bucket_id, name, owner) values (''documents'', %L, %L)', u_o || '/abcdef12-3456.jpg', u_m)]);
    res := res || format('storage: member cannot upload into another folder|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array[g, '@admin', format('insert into storage.objects (bucket_id, name, owner) values (''receipts'', %L, %L)', u_m || '/0123456789abcdef.pdf', u_a)]);
    res := res || format('storage: admin uploads into a member folder|%s|%s', case when r = 'ok:rows=1' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array[g, '@admin', format('insert into storage.objects (bucket_id, name, owner) values (''receipts'', %L, %L)', gen_random_uuid() || '/0123456789abcdef.pdf', u_a)]);
    res := res || format('storage: admin cannot upload into a folder of nobody|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array[g, '@member', format('insert into storage.objects (bucket_id, name, owner) values (''documents'', %L, %L)', u_m || '/x.jpg', u_m)]);
    res := res || format('storage: bad file name refused|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array[g, '@member', format('insert into storage.objects (bucket_id, name, owner) values (''documents'', %L, %L)', u_m || '/abcdef12-3456.exe', u_m)]);
    res := res || format('storage: bad file type refused|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array[g, '@anon', format('insert into storage.objects (bucket_id, name) values (''documents'', %L)', u_m || '/abcdef12-3456.jpg')]);
    res := res || format('storage: anon cannot upload|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array[g,
          format('insert into storage.objects (bucket_id, name, owner) select ''avatars'', %L || ''/photo-'' || (1000000000000 + i) || ''.jpg'', %L from generate_series(1, 20) i', u_m, u_m),
          '@member', format('insert into storage.objects (bucket_id, name, owner) values (''avatars'', %L, %L)', u_m || '/photo-9999999999999.jpg', u_m)]);
    res := res || format('storage: 21st avatar refused (cap 20)|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array[g,
          format('insert into storage.objects (bucket_id, name, owner) select ''avatars'', %L || ''/photo-'' || (1000000000000 + i) || ''.jpg'', %L from generate_series(1, 19) i', u_m, u_m),
          '@member', format('insert into storage.objects (bucket_id, name, owner) values (''avatars'', %L, %L)', u_m || '/photo-9999999999999.jpg', u_m)]);
    res := res || format('storage: 20th avatar still allowed|%s|%s', case when r = 'ok:rows=1' then 'PASS' else 'FAIL' end, r);
    select string_agg(policyname, ', ') into v from pg_policies
     where schemaname = 'storage' and tablename = 'objects' and cmd in ('INSERT', 'UPDATE')
       and position('storage_upload_ok' in coalesce(with_check, '') || coalesce(qual, '')) = 0;
    res := res || format('storage: every upload / replace policy uses the check|%s|%s', case when v is null then 'PASS' else 'FAIL' end, coalesce(v, 'none'));

    ------------------------------------------------------------------ 3) strict paths
    r := pg_temp.probe(array['#owner', format('update public.profiles set photo_path = %L where id = %L', u_m || '/photo-1731900000000.jpg', u_m)]);
    res := res || format('path: app-style photo path accepted|%s|%s', case when r = 'ok:rows=1' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', format('update public.profiles set photo_path = %L where id = %L', u_m || '/../x/photo-1731900000000.jpg', u_m)]);
    res := res || format('path: photo path with ../ refused|%s|%s', case when r like 'err:23514:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', format('update public.profiles set photo_path = %L where id = %L', u_o || '/photo-1731900000000.jpg', u_m)]);
    res := res || format('path: photo in someone else''s folder refused|%s|%s', case when r like 'err:23514:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', format('update public.profiles set photo_path = %L where id = %L', u_m || '/photo-1731900000000.gif', u_m)]);
    res := res || format('path: photo with .gif refused|%s|%s', case when r like 'err:23514:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', format('insert into public.member_documents (member_id, kind, storage_path) values (%L, ''nid_front'', %L)', u_m, u_m || '/nid_front-1731900000000.pdf')]);
    res := res || format('path: app-style document path accepted|%s|%s', case when r = 'ok:rows=1' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', format('insert into public.member_documents (member_id, kind, storage_path) values (%L, ''nid_front'', %L)', u_m, u_m || '/a b.pdf')]);
    res := res || format('path: document name with space refused|%s|%s', case when r like 'err:23514:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', format('insert into public.deposits (member_id, period_month, kind, amount, method, status, receipt_path) values (%L, date_trunc(''month'', current_date)::date, ''other'', 1, ''cash'', ''pending'', %L)',
                                              u_m, u_m || '/' || gen_random_uuid() || '.webp')]);
    res := res || format('path: app-style receipt path (uuid name) accepted|%s|%s', case when r = 'ok:rows=1' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', format('insert into public.deposits (member_id, period_month, kind, amount, method, status, receipt_path) values (%L, date_trunc(''month'', current_date)::date, ''other'', 1, ''cash'', ''pending'', %L)',
                                              u_m, u_m || '/' || gen_random_uuid() || '.jpg.exe')]);
    res := res || format('path: receipt with double extension refused|%s|%s', case when r like 'err:23514:%' then 'PASS' else 'FAIL' end, r);
    select string_agg(c, ', ') into v
      from unnest(array['profiles_photo_path_strict', 'member_documents_path_strict', 'deposits_receipt_path_strict',
                        'money_requests_receipt_path_strict', 'expenses_receipt_path_strict']) c
     where not exists (select 1 from pg_constraint where conname = c);
    res := res || format('path: strict constraints on all 5 path columns|%s|%s', case when v is null then 'PASS' else 'FAIL' end, coalesce(v, 'all there'));

    ------------------------------------------------------------------ 4) audit_log + anon
    r := pg_temp.probe(array['#owner', 'update public.audit_log set action = ''x'' where id = (select min(id) from public.audit_log)']);
    res := res || format('audit_log: SQL Editor cannot update|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', 'delete from public.audit_log where id = (select min(id) from public.audit_log)']);
    res := res || format('audit_log: SQL Editor cannot delete|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['#owner', 'truncate public.audit_log']);
    res := res || format('audit_log: SQL Editor cannot truncate|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['@super', 'delete from public.audit_log']);
    res := res || format('audit_log: super admin cannot delete|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['@super', 'insert into public.audit_log (action, table_name) values (''FAKE'', ''x'')']);
    res := res || format('audit_log: super admin cannot insert fake rows|%s|%s', case when r like 'err:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['grant update, delete, select on public.audit_log to service_role', '@service',
                             'update public.audit_log set action = ''x''']);
    res := res || format('audit_log: service_role refused even with a grant (trigger)|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['@admin', 'insert into public.notices (title, body) values (''TEST 014'', ''x'')', '#owner',
                             'select count(*)::text from public.audit_log where table_name = ''notices'' and new_data ->> ''title'' = ''TEST 014''']);
    res := res || format('audit_log: normal changes are still logged|%s|%s', case when r = 'ok:1' then 'PASS' else 'FAIL' end, r);
    select string_agg(c.relname, ', ' order by c.relname) into v
      from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm')
       and (has_table_privilege('anon', c.oid, 'INSERT') or has_table_privilege('anon', c.oid, 'UPDATE')
            or has_table_privilege('anon', c.oid, 'DELETE') or has_table_privilege('anon', c.oid, 'TRUNCATE')
            or (c.relname <> 'site_content' and has_table_privilege('anon', c.oid, 'SELECT')));
    res := res || format('anon: no rights on any core table (site_content read only)|%s|%s', case when v is null then 'PASS' else 'FAIL' end, coalesce(v, 'none'));
    r := pg_temp.probe(array['@anon', 'select count(*)::text from public.profiles']);
    res := res || format('anon: cannot read profiles|%s|%s', case when r like 'err:42501:%' then 'PASS' else 'FAIL' end, r);
    r := pg_temp.probe(array['@anon', 'select count(*)::text from public.site_content']);
    res := res || format('anon: still reads the 3 public messages|%s|%s', case when r like 'ok:%' and r <> 'ok:0' then 'PASS' else 'FAIL' end, r);

    raise exception using errcode = 'P0097', message = 'roll back';
  exception when sqlstate 'P0097' then null;
  end;

  perform set_config('request.jwt.claims', '', true);
  res := res || format('test rows are gone (rolled back)|%s|',
    case when not exists (select 1 from public.notices where title = 'TEST 014')
          and (select email from public.profiles where id = u_m) = 'fd.test.member@example.com' then 'PASS' else 'FAIL' end);
  select coalesce(string_agg(c.rule || ' [' || c.detail || ']', '; '), 'all ok') into v from public.check_invariants(false) c where not c.ok;
  res := res || format('check_invariants all ok|%s|%s', case when v = 'all ok' then 'PASS' else 'FAIL' end, v);

  insert into t014_results (test, result, detail)
  select split_part(x, '|', 1), split_part(x, '|', 2), substr(x, length(split_part(x, '|', 1)) + length(split_part(x, '|', 2)) + 3)
    from unnest(res) x;
end $$;

select n, test, result, detail from t014_results order by n;
