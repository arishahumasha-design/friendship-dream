// Run: node supabase/dev/build_production_setup.js
// Builds supabase/production_setup.sql = schema.sql (001) + every numbered migration, in order.
const fs = require("fs");
const root = require("path").join(__dirname, "..") + "/";  // the supabase/ folder
// 001 = schema.sql, then every numbered migration in supabase/migrations, in order.
const parts = [["001 (schema.sql)", "schema.sql"]].concat(
  fs.readdirSync(root + "migrations")
    .filter((f) => /^\d{3}_.*\.sql$/.test(f))
    .sort()
    .map((f) => [f.slice(0, 3), "migrations/" + f]),
);
const guard = `
-- ---------- Guard added by production_setup.sql (not part of 007 itself) ----------
-- 007 builds the ledger assuming there are no investments / expenses / income yet.
do $$
declare n bigint;
begin
  select (select count(*) from public.investments)
       + (select count(*) from public.expenses)
       + (select count(*) from public.investment_income) into n;
  if n > 0 then
    raise exception 'STOP: 007 expects investments, expenses and investment_income to be EMPTY (found % rows).', n;
  end if;
end $$;
`;
let out = `-- =====================================================================
-- Friendship Dream — COMPLETE database setup for a BRAND NEW Supabase project.
-- Generated from: supabase/schema.sql (001) and every file in supabase/migrations, in number order.
-- Do NOT edit by hand: change the migration files and run: node supabase/dev/build_production_setup.js
--
-- HOW TO USE (only once, on an EMPTY new Supabase project, e.g. the real production one):
-- Create the project, open Dashboard > SQL Editor > New query, paste this whole file and Run.
-- It creates every table, rule, trigger, storage bucket and function exactly as the test
-- project has them after the last migration. Then run supabase/seed_policies.sql the same way.
-- Then: set "Confirm email" and the site URL / redirect URLs in Authentication settings,
-- put the new project's URL and publishable key in Vercel, sign up yourself on the website,
-- CONFIRM your email, and run the "SUPER ADMIN BOOTSTRAP" SQL printed at the top of section 014
-- (it uses the auth.users id; ignore the older one-liner at the end of section 001).
-- Never run this file on a project that already has data: it is not meant for upgrades
-- (use the numbered migration files for that).
-- =====================================================================
`;
for (const [label, file] of parts) {
  if (file.includes("007")) out += guard;
  const body = fs.readFileSync(root + file, "utf8").trimEnd();
  out += `\n\n-- #####################################################################\n-- ### ${label}: ${file}\n-- #####################################################################\n\n${body}\n`;
}
fs.writeFileSync(root + "production_setup.sql", out);
console.log("written", out.length, "chars,", out.split("\n").length, "lines");
