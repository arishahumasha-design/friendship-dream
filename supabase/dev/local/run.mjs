// DEV ONLY. Runs supabase/production_setup.sql + test files in a local, throw-away Postgres (PGlite).
// One-time setup in an empty folder: npm init -y && npm install @electric-sql/pglite@0.2.17
// Then: node run.mjs <path>/supabase/production_setup.sql <path>/supabase/dev/test_6a_rules.sql <path>/supabase/dev/test_6b_rules.sql
// (Set DETAIL=1 to print the message behind every PASS.)
// Local test harness: a fresh Postgres (PGlite) with small stand-ins for Supabase's auth/storage,
// then supabase/production_setup.sql, some fake members, then the given test SQL files.
// Usage: node run.mjs <setup.sql> [test1.sql test2.sql ...]
import { PGlite } from "@electric-sql/pglite";
import fs from "fs";

const [setupFile, ...tests] = process.argv.slice(2);
const db = new PGlite();

const stubs = `
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb, email_confirmed_at timestamptz default now());
create function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                         (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')), '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
create schema storage;
create table storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid);
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as $$
  select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1] $$;
grant usage on schema storage to anon, authenticated, service_role;
`;

// Fake members like the real test project: emails fd.test.*, roles and money.
const seed = `
insert into public.system_markers (key) values ('go_live') on conflict do nothing;   -- books open for the tests (since 012)
insert into auth.users (email, raw_user_meta_data) values
  ('owner@example.com', '{"full_name":"Owner"}'),
  ('fd.test.member@example.com', '{"full_name":"Test Member One"}'),
  ('fd.test.other@example.com', '{"full_name":"Test Other Member"}'),
  ('fd.test.admin@example.com', '{"full_name":"Test Admin"}'),
  ('fd.test.admin2@example.com', '{"full_name":"Test Admin Two"}'),
  ('fd.test.super@example.com', '{"full_name":"Test Super Admin"}'),
  ('fd.test.pending2@example.com', '{"full_name":"Test Pending Two"}'),
  ('fd.test.pending3@example.com', '{"full_name":"Test Pending Three"}');
update public.profiles set status = 'active', joined_on = current_date - 10
 where email in ('owner@example.com', 'fd.test.member@example.com', 'fd.test.other@example.com',
                 'fd.test.admin@example.com', 'fd.test.admin2@example.com', 'fd.test.super@example.com',
                 'fd.test.pending2@example.com');
update public.profiles set role = 'admin' where email in ('fd.test.admin@example.com', 'fd.test.admin2@example.com');
update public.profiles set role = 'super_admin' where email = 'fd.test.super@example.com';
insert into public.deposits (member_id, period_month, kind, amount, method, status, note)
select id, date_trunc('month', current_date)::date, 'monthly', amt, 'cash', 'approved', 'seed'
  from (values ('fd.test.member@example.com', 21700), ('fd.test.other@example.com', 4000),
               ('fd.test.admin@example.com', 3000), ('fd.test.super@example.com', 9000)) v(e, amt)
  join public.profiles p on p.email = v.e;
insert into public.deposits (member_id, period_month, kind, amount, method, status, note)
select id, date_trunc('month', current_date)::date, 'late_fee', 70, 'cash', 'approved', 'seed late fee'
  from public.profiles where email = 'fd.test.member@example.com';
`;

async function run(label, sql) {
  try {
    const res = await db.exec(sql);
    return res;
  } catch (e) {
    console.log(`\n### ${label}: ERROR\n${e.message}${e.where ? "\nwhere: " + e.where : ""}${e.position ? "\nposition: " + e.position : ""}`);
    if (e.position) {
      const p = Number(e.position);
      console.log("near: ..." + sql.slice(Math.max(0, p - 300), p + 100).replace(/\n/g, "\n   ") + "...");
    }
    process.exit(1);
  }
}

await run("stubs", stubs);
const setupRes = await run("setup", fs.readFileSync(setupFile, "utf8"));
const last = setupRes[setupRes.length - 1];
const bad = (last.rows ?? []).filter((r) => r.ok === false);
console.log(`setup OK (${fs.readFileSync(setupFile, "utf8").split("\n").length} lines); last check: ${last.rows?.length} rule rows, ${bad.length} not ok`);
await run("seed", seed);
const inv = (await db.query("select rule, ok, detail from public.check_invariants(false)")).rows;
console.log("after seed: " + inv.filter((r) => !r.ok).map((r) => r.rule + " [" + r.detail + "]").join("; ") || "after seed: all invariants ok (" + inv.length + ")");

for (const f of tests) {
  const res = await run(f, fs.readFileSync(f, "utf8"));
  const rows = res[res.length - 1].rows ?? [];
  const fails = rows.filter((r) => r.result !== "PASS");
  console.log(`\n### ${f.split(/[\\/]/).pop()}: ${rows.length} rows, ${rows.length - fails.length} PASS, ${fails.length} not PASS`);
  for (const r of rows) console.log(`${r.result === "PASS" ? "  " : "!!"} ${r.result.padEnd(4)} ${r.test}${process.env.DETAIL || r.result !== "PASS" ? "  -> " + String(r.detail).slice(0, 150) : ""}`);
}
