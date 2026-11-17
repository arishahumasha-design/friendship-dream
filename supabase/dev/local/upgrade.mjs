// DEV ONLY. Upgrade-path check: 001..009, 009-era activity, then 010, then the test files (needs run.mjs next to it).
// Upgrade path: 001..009, then 009-era money activity (like the real test project), then 010, then tests.
import { PGlite } from "@electric-sql/pglite";
import fs from "fs";
const sb = new URL("../../", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");
const db = new PGlite();
const runner = fs.readFileSync(new URL("./run.mjs", import.meta.url), "utf8");
const stubs = runner.slice(runner.indexOf("const stubs = `") + 15, runner.indexOf("`;", runner.indexOf("const stubs = `")));
const seed = runner.slice(runner.indexOf("const seed = `") + 14, runner.indexOf("`;", runner.indexOf("const seed = `")));
const ex = async (label, sql) => { try { return await db.exec(sql); } catch (e) { console.log(`ERROR in ${label}: ${e.message}`); process.exit(1); } };

await ex("stubs", stubs);
await ex("001", fs.readFileSync(sb + "schema.sql", "utf8"));
for (const f of fs.readdirSync(sb + "migrations").sort().filter((f) => f < "010")) await ex(f, fs.readFileSync(sb + "migrations/" + f, "utf8"));
const seedNoMarker = seed.split(String.fromCharCode(10)).filter((l) => !l.includes("go_live")).join(String.fromCharCode(10));   // markers exist only from 011
await ex("seed", seedNoMarker);
// 009-era activity, with the 009 function signatures
await ex("009 activity", `
do $$
declare a uuid := (select id from public.profiles where email = 'fd.test.admin@example.com');
        a2 uuid := (select id from public.profiles where email = 'fd.test.admin2@example.com');
        r uuid; inv uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  r := public.propose_investment('TEST conc plot 1', 'land', current_date, 22449.60, null);
  perform set_config('request.jwt.claims', json_build_object('sub', a2, 'role', 'authenticated')::text, true);
  inv := public.approve_investment(r);
  foreach r in array array[
      (select public.propose_expense('TEST conc exp', 10.01, current_date)),
      (select public.propose_expense('TEST conc exp 2', 20.02, current_date)),
      (select public.propose_expense('TEST conc exp 3', 30.03, current_date))] loop
    null;
  end loop;
end $$;`);
// the proposals above ran as admin2 (claims were switched), approve them as admin
await ex("009 approvals", `
do $$
declare a uuid := (select id from public.profiles where email = 'fd.test.admin@example.com');
        a2 uuid := (select id from public.profiles where email = 'fd.test.admin2@example.com');
        q record; inv uuid := (select id from public.investments limit 1); r uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  for q in select id from public.money_requests where kind = 'expense' and status = 'pending' loop
    perform public.approve_expense(q.id);
  end loop;
  r := public.propose_sale(inv, 22449.60, current_date, null);
  perform set_config('request.jwt.claims', json_build_object('sub', a2, 'role', 'authenticated')::text, true);
  perform public.approve_sale(r);
end $$;`);
const before = (await db.query("select rule, ok from public.check_invariants(false)")).rows;
console.log(`after 009 activity: ${before.length} rules, ${before.filter((r) => !r.ok).length} failing`);
const neg = (await db.query("select count(*)::int as n from public.fund_reserve where kind = 'remainder' and amount < 0")).rows[0].n;
console.log(`legacy negative remainders present: ${neg}`);

for (const f of fs.readdirSync(sb + "migrations").sort().filter((f) => f >= "010")) await ex(f, fs.readFileSync(sb + "migrations/" + f, "utf8"));
const rows = (await db.query("select rule, ok, detail from public.check_invariants(false)")).rows;
console.log(`010+ applied on top: ${rows.length} rules, failing: ${rows.filter((r) => !r.ok).map((r) => r.rule).join(", ") || "none"}`);
console.log(rows.find((r) => r.rule.startsWith("split amounts"))?.detail);
for (const f of fs.readdirSync(sb + "migrations").sort().filter((f) => f >= "010")) await ex(f + " again", fs.readFileSync(sb + "migrations/" + f, "utf8"));
console.log(`010+ run a second time: ${(await db.query("select ok from public.check_invariants(false)")).rows.filter((r) => !r.ok).length} failing`);
await ex("open the books", "insert into public.system_markers (key) values ('go_live') on conflict do nothing;");   // like a live project after 012
for (const f of ["test_6a_rules.sql", "test_6b_rules.sql", "test_013_content.sql"]) {
  const r = await ex(f, fs.readFileSync(sb + "dev/" + f, "utf8"));
  const t = r[r.length - 1].rows;
  const bad = t.filter((x) => x.result !== "PASS");
  console.log(`${f}: ${t.length} rows, ${t.length - bad.length} PASS` + bad.map((b) => `\n   FAIL ${b.test} -> ${b.detail}`).join(""));
}
