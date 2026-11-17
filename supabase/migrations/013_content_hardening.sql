-- =====================================================================
-- 013_content_hardening.sql  (run AFTER 012; it touches no money table)
--
-- 1) notices: pinned (default false) + pinned_at. Only admins can pin / unpin; pinned_at is set by the database.
-- 2) policies and site_content:
--    - only the super admin can INSERT or UPDATE (RLS = first layer, trigger = second layer);
--    - nobody can DELETE or TRUNCATE (not even service_role or the SQL Editor): hide instead
--      (policies.is_current = false, site_content text = empty);
--    - every change stays audit-logged (audit_policies / audit_content triggers, checked below);
--    - active members read all rows; anon (and any logged-in user, e.g. pending) reads ONLY the
--      public front-page messages: home_message_1, home_message_2, home_message_3.
--    - The SQL Editor (database owner, no logged-in user) may still insert / update,
--      e.g. supabase/seed_policies.sql on a new project.
-- 3) A self-check at the end stops the migration if anything is not as described.
-- Safe to run more than once.
-- =====================================================================

-- Who may write is decided INSIDE the trigger functions (they run as the calling role, and trigger
-- functions need no execute grant). No new callable function is created, so the API surface stays the same:
--   * the SQL Editor / migrations: not an API role (anon / authenticated / service_role) and no logged-in user;
--   * a logged-in user: role authenticated, checked with is_admin() / is_super_admin();
--   * service_role and anon are never admins here, whatever JWT they carry.

-- ---------- 1) notices: pin ----------
alter table public.notices add column if not exists pinned    boolean not null default false;
alter table public.notices add column if not exists pinned_at timestamptz;
create index if not exists notices_order_idx on public.notices (pinned desc, pinned_at desc nulls last, created_at desc);

create or replace function public.notices_pin_guard() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_admin boolean := false;
begin
  if current_user = 'authenticated' then
    v_admin := public.is_admin();
  elsif current_user not in ('anon', 'service_role') and auth.uid() is null then
    v_admin := true;   -- SQL Editor / migrations
  end if;

  if tg_op = 'INSERT' then
    if new.pinned and not v_admin then
      raise exception 'Only an admin can pin a notice.' using errcode = '42501';
    end if;
    new.pinned_at := case when new.pinned then now() end;
  else
    if new.pinned is distinct from old.pinned then
      if not v_admin then
        raise exception 'Only an admin can pin or unpin a notice.' using errcode = '42501';
      end if;
      new.pinned_at := case when new.pinned then now() end;
    else
      new.pinned_at := old.pinned_at;   -- nobody sets pinned_at by hand
    end if;
  end if;
  return new;
end $$;

drop trigger if exists notices_pin_guard on public.notices;
create trigger notices_pin_guard before insert or update on public.notices
  for each row execute function public.notices_pin_guard();

-- ---------- 2) policies + site_content: second layer (trigger) ----------
create or replace function public.content_write_guard() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_ok boolean := false;
begin
  if tg_op in ('DELETE', 'TRUNCATE') then
    raise exception 'Rows in % are never deleted. Hide them instead.', tg_table_name using errcode = '42501';
  end if;

  if current_user = 'authenticated' then
    v_ok := public.is_super_admin();
  elsif current_user not in ('anon', 'service_role') and auth.uid() is null then
    v_ok := true;      -- SQL Editor / migrations (e.g. seed_policies.sql)
  end if;
  if not v_ok then
    raise exception 'Only the super admin can change %.', tg_table_name using errcode = '42501';
  end if;

  if tg_table_name = 'policies' then
    if tg_op = 'INSERT' then
      new.created_at := now();
      new.created_by := coalesce(auth.uid(), new.created_by);
    else
      new.id         := old.id;          -- identity and history fields never change
      new.created_by := old.created_by;
      new.created_at := old.created_at;
    end if;
  elsif tg_table_name = 'site_content' then
    if tg_op = 'UPDATE' and new.key is distinct from old.key then
      raise exception 'The key of a site_content row cannot change.' using errcode = '42501';
    end if;
    new.updated_at := now();
  end if;
  return new;
end $$;

do $$
declare tb text;
begin
  foreach tb in array array['policies', 'site_content'] loop
    execute format('drop trigger if exists %I on public.%I', tb || '_write_guard', tb);
    execute format('create trigger %I before insert or update or delete on public.%I for each row execute function public.content_write_guard()',
                   tb || '_write_guard', tb);
    execute format('drop trigger if exists %I on public.%I', tb || '_no_truncate', tb);
    execute format('create trigger %I before truncate on public.%I for each statement execute function public.content_write_guard()',
                   tb || '_no_truncate', tb);
  end loop;
end $$;

-- audit triggers (there since 001 / 003; recreated only if missing)
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'audit_policies' and tgrelid = 'public.policies'::regclass) then
    create trigger audit_policies after insert or update or delete on public.policies for each row execute function public.audit_row();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'audit_content' and tgrelid = 'public.site_content'::regclass) then
    create trigger audit_content after insert or update or delete on public.site_content for each row execute function public.audit_row();
  end if;
end $$;

-- ---------- 3) policies + site_content: first layer (privileges + RLS) ----------
revoke all on public.policies, public.site_content from public, anon, authenticated, service_role;
grant select, insert, update on public.policies     to authenticated;
grant select, insert, update on public.site_content to authenticated;
grant select                 on public.site_content to anon;
grant select on public.policies, public.site_content to service_role;   -- read only

alter table public.policies     enable row level security;
alter table public.site_content enable row level security;

-- drop every existing policy on the two tables, then create exactly the ones we want
do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies
            where schemaname = 'public' and tablename in ('policies', 'site_content') loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

create policy policies_select on public.policies for select to authenticated
  using (public.is_active_member());
create policy policies_insert on public.policies for insert to authenticated
  with check (public.is_super_admin());
create policy policies_update on public.policies for update to authenticated
  using (public.is_super_admin()) with check (public.is_super_admin());

create policy content_public_select on public.site_content for select to anon, authenticated
  using (key in ('home_message_1', 'home_message_2', 'home_message_3'));
create policy content_member_select on public.site_content for select to authenticated
  using (public.is_active_member());
create policy content_insert on public.site_content for insert to authenticated
  with check (public.is_super_admin());
create policy content_update on public.site_content for update to authenticated
  using (public.is_super_admin()) with check (public.is_super_admin());

-- ---------- 4) Prove it ----------
do $$
declare v text;
begin
  -- no API role may delete / truncate; anon and service_role may only read
  select string_agg(grantee || ':' || table_name || ':' || privilege_type, ', ') into v
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name in ('policies', 'site_content')
     and grantee in ('PUBLIC', 'anon', 'authenticated', 'service_role')
     and (privilege_type in ('DELETE', 'TRUNCATE', 'TRIGGER', 'REFERENCES')
          or (grantee in ('anon', 'service_role', 'PUBLIC') and privilege_type <> 'SELECT'));
  if v is not null then raise exception '013 check failed: unwanted grants: %', v; end if;

  -- every write policy needs the super admin; no DELETE / ALL policies
  select string_agg(tablename || '.' || policyname, ', ') into v
    from pg_policies
   where schemaname = 'public' and tablename in ('policies', 'site_content')
     and (cmd in ('DELETE', 'ALL')
          or (cmd in ('INSERT', 'UPDATE') and position('is_super_admin()' in coalesce(with_check, '')) = 0)
          or (cmd = 'UPDATE' and position('is_super_admin()' in coalesce(qual, '')) = 0));
  if v is not null then raise exception '013 check failed: write policies without super admin: %', v; end if;

  -- anon reads only the three public keys
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'site_content'
              and cmd = 'SELECT' and 'anon' = any (roles) and position('home_message_1' in coalesce(qual, '')) = 0) then
    raise exception '013 check failed: anon may read more than the public keys';
  end if;

  -- triggers in place
  select string_agg(t, ', ') into v
    from unnest(array['policies_write_guard', 'policies_no_truncate', 'site_content_write_guard',
                      'site_content_no_truncate', 'audit_policies', 'audit_content', 'notices_pin_guard']) t
   where not exists (select 1 from pg_trigger where tgname = t and not tgisinternal);
  if v is not null then raise exception '013 check failed: missing triggers: %', v; end if;

  -- no function (other than the guards) writes these tables
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname not in ('content_write_guard', 'notices_pin_guard')
     and p.prosrc ~* '(insert[[:space:]]+into|update|delete[[:space:]]+from|truncate)[[:space:]]+(table[[:space:]]+)?(only[[:space:]]+)?(public[.])?(policies|site_content)([^a-z_]|$)';
  if v is not null then raise exception '013 check failed: functions that write content tables: %', v; end if;

  raise notice '013 ok: content tables hardened';
end $$;
