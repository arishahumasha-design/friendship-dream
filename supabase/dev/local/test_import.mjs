// DEV ONLY. Tests the one-time historical import (migrations 011 + 012) in a throw-away local Postgres (PGlite).
// Needs @electric-sql/pglite installed where you run it (see run.mjs). Uses 15 FAKE members
// (fd.import.NN@example.com) and the real sheet's amounts; never prints names, emails or phones.
// Usage: node test_import.mjs <project folder>
import { PGlite } from "@electric-sql/pglite";
import { execFileSync } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";

const proj = process.argv[2];
const sb = path.join(proj, "supabase");
const gen = path.join(sb, "import", "build_import.mjs");
const runner = fs.readFileSync(new URL("./run.mjs", import.meta.url), "utf8");
const stubs = runner.slice(runner.indexOf("const stubs = `") + 15, runner.indexOf("`;", runner.indexOf("const stubs = `")));
const setupSql = fs.readFileSync(path.join(sb, "production_setup.sql"), "utf8");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "fd-import-test-"));

let pass = 0, fail = 0;
const ok = (name, cond, detail = "") => { cond ? pass++ : fail++; console.log(`${cond ? "PASS" : "FAIL"} ${name}${cond ? "" : "  -> " + detail}`); };
const lastRows = (res) => res[res.length - 1].rows;
const email = (i) => `fd.import.${String(i).padStart(2, "0")}@example.com`;
const writeMap = (file, rows) => fs.writeFileSync(file, "sr_no,sheet_name,email\n" + rows.join("\n") + "\n");
const runGen = (args) => { try { return { out: execFileSync("node", [gen, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }) }; } catch (e) { return { err: String(e.stderr || e.message) }; } };
const read = (dir, f) => fs.readFileSync(path.join(dir, f), "utf8");

// ---------------- generator / reader tests (no database) ----------------
const outA = path.join(tmp, "a"); fs.mkdirSync(outA);
const mapA = path.join(tmp, "map_a.csv");
// quoted fields, a comma inside a name, quoted emails, CRLF line ends
fs.writeFileSync(mapA, "sr_no,sheet_name,email\r\n" + Array.from({ length: 15 }, (_, i) => `"${i + 1}","Fake, Person ${i + 1}","${email(i + 1)}"`).join("\r\n") + "\r\n");
const g1 = runGen(["--map", mapA, "--out", outA]);
ok("generator: quoted CSV (commas inside names, quoted emails, CRLF) is read", !g1.err && fs.existsSync(path.join(outA, "run_verify.sql")), g1.err);
ok("generator: without --confirm no import files are written", !fs.existsSync(path.join(outA, "run_import_real.sql")));
ok("generator: notes are the generic 'historical import' (nothing parsed from the sheet)", !g1.err && !/sheet note|Feb 2026 sheet/.test(read(outA, "run_verify.sql")) && /"note":"historical import"/.test(read(outA, "run_verify.sql")));
ok("generator: default output folder is outside the project", /fd-import-out/.test(fs.readFileSync(gen, "utf8")) && !path.relative(proj, path.join(os.homedir(), "fd-import-out")).startsWith(".." + path.sep) === false);
const bad = path.join(tmp, "bad.csv");
writeMap(bad, Array.from({ length: 15 }, (_, i) => `${i + 1},x,${i === 3 ? "" : email(i + 1)}`));
ok("generator: a missing email stops it", /SR NO 4 have no valid email/.test(runGen(["--map", bad, "--out", tmp]).err ?? ""));
writeMap(bad, Array.from({ length: 15 }, (_, i) => `${i + 1},x,${email(i === 5 ? 1 : i + 1)}`));
ok("generator: the same email twice stops it", /same email is used twice/.test(runGen(["--map", bad, "--out", tmp]).err ?? ""));
writeMap(bad, Array.from({ length: 15 }, (_, i) => `${i === 14 ? 16 : i + 1},x,${email(i + 1)}`));
ok("generator: an SR NO outside 1..15 stops it", /sr_no must be 1..15/.test(runGen(["--map", bad, "--out", tmp]).err ?? ""));
ok("generator: a malformed --confirm is refused", /32-character code/.test(runGen(["--map", mapA, "--out", outA, "--confirm", "nope"]).err ?? ""));

// self-closing <row/> regression: build a tiny .xlsx by hand
{
  const { readXlsx } = await import(new URL("file:///" + path.join(sb, "import", "xlsx_mini.mjs").replace(/\\/g, "/")).href);
  const files = {
    "xl/workbook.xml": `<workbook><sheets><sheet name="T" sheetId="1" r:id="rId1"/></sheets></workbook>`,
    "xl/_rels/workbook.xml.rels": `<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>`,
    "xl/sharedStrings.xml": `<sst><si><t>A</t></si><si><t>C</t></si></sst>`,
    "xl/worksheets/sheet1.xml": `<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row><row r="2"/><row r="3"><c r="A3" t="s"><v>1</v></c><c r="B3"><v>7</v></c></row></sheetData></worksheet>`,
  };
  const parts = [], central = [];
  let offset = 0;
  for (const [name, text] of Object.entries(files)) {
    const data = Buffer.from(text), nm = Buffer.from(name);
    const local = Buffer.alloc(30); local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(0, 8);
    local.writeUInt32LE(data.length, 18); local.writeUInt32LE(data.length, 22); local.writeUInt16LE(nm.length, 26);
    const cen = Buffer.alloc(46); cen.writeUInt32LE(0x02014b50, 0); cen.writeUInt16LE(0, 10);
    cen.writeUInt32LE(data.length, 20); cen.writeUInt32LE(data.length, 24); cen.writeUInt16LE(nm.length, 28); cen.writeUInt32LE(offset, 42);
    parts.push(local, nm, data); central.push(cen, nm);
    offset += 30 + nm.length + data.length;
  }
  const cd = Buffer.concat(central);
  const end = Buffer.alloc(22); end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(Object.keys(files).length, 10);
  end.writeUInt32LE(cd.length, 12); end.writeUInt32LE(offset, 16);
  const xfile = path.join(tmp, "selfclosing.xlsx");
  fs.writeFileSync(xfile, Buffer.concat([...parts, cd, end]));
  const rows = readXlsx(xfile)[0].rows;
  ok("xlsx reader: a self-closing <row/> does not swallow the next row", rows[0][0] === "A" && (rows[1] ?? []).length === 0 && rows[2][0] === "C" && rows[2][1] === 7, JSON.stringify(rows));
}

// ---------------- database tests ----------------
async function freshDb({ members = 15, ownerFirst = true } = {}) {
  const db = new PGlite();
  await db.exec(stubs);
  await db.exec(setupSql);
  const users = [];
  if (ownerFirst) users.push(`('owner.super@example.com', '{"full_name":"Owner"}')`);         // takes member_no 1
  for (let i = 1; i <= members; i++) users.push(`('${email(i)}', '{"full_name":"Fake ${i}"}')`);
  users.push(`('someone.pending@example.com', '{"full_name":"Pending"}')`);
  await db.exec(`insert into auth.users (email, raw_user_meta_data) values ${users.join(",")};
    update public.profiles set role = 'super_admin', status = 'active', joined_on = current_date where email = 'owner.super@example.com';`);
  return db;
}
const count = async (db, sql) => Number((await db.query(sql)).rows[0].n);
const tryExec = async (db, sql) => { try { return { res: await db.exec(sql) }; } catch (e) { return { err: e.message }; } };
const nothingSaved = async (db) =>
  (await count(db, "select count(*) as n from public.member_ledger")) === 0 &&
  (await count(db, "select count(*) as n from public.deposits where status = 'approved'")) === 0 &&
  (await count(db, "select count(*) as n from public.investments")) === 0 &&
  (await count(db, "select count(*) as n from public.import_batches")) === 0 &&
  (await count(db, "select count(*) as n from public.system_markers")) === 0;
const asUser = (id) => `select set_config('request.jwt.claims', '${JSON.stringify({ sub: id, role: "authenticated" })}', false);`;
const asEditor = `select set_config('request.jwt.claims', '', false); reset role;`;
const idOf = async (db, e) => (await db.query(`select id from public.profiles where email = '${e}'`)).rows[0].id;
async function verifyCode(db, out) {
  const r = await tryExec(db, read(out, "run_verify.sql"));
  const rows = r.res ? lastRows(r.res) : [];
  return { rows, code: rows.find((x) => x.sheet_name === "CONFIRM CODE")?.full_name, err: r.err };
}

// the full flow on one database
const outB = path.join(tmp, "b"); fs.mkdirSync(outB);
{
  const db = await freshDb();
  const gB = runGen(["--map", mapA, "--out", outB]);
  ok("generator writes prepare + verify", !gB.err, gB.err);

  // books closed before the import
  const fake1 = await idOf(db, email(1)), fake2 = await idOf(db, email(2)), owner = await idOf(db, "owner.super@example.com");
  await db.exec(`update public.profiles set status = 'active', joined_on = '2025-06-01', role = 'admin' where email = '${email(3)}';`);
  const pend = await tryExec(db, `insert into public.deposits (member_id, period_month, kind, amount, method, status) values ('${owner}', '2026-11-01', 'monthly', 3000, 'cash', 'pending')`);
  ok("before the import: a member can still SUBMIT a pending deposit", !pend.err, pend.err);
  const appr = await tryExec(db, `${asUser(await idOf(db, email(3)))} set role authenticated; update public.deposits set status = 'approved' where member_id = '${owner}'; ${asEditor}`);
  await tryExec(db, asEditor);
  ok("before the import: approving a deposit is refused", !!appr.err && /books open after the historical import/.test(appr.err), appr.err);
  const enter = await tryExec(db, `insert into public.deposits (member_id, period_month, kind, amount, method, status, note) values ('${owner}', '2026-11-01', 'monthly', 3000, 'cash', 'approved', 'x')`);
  ok("before the import: entering an approved deposit is refused (even SQL Editor)", !!enter.err && /books open/.test(enter.err), enter.err);
  const prop = await tryExec(db, `${asUser(owner)} select public.propose_expense('x', 10, current_date); ${asEditor}`);
  await tryExec(db, asEditor);
  ok("before the import: proposing an expense is refused", !!prop.err && /books open/.test(prop.err), prop.err);

  // prepare -> member_no = SR NO, other accounts out of the way
  const p = await tryExec(db, read(outB, "run_prepare.sql"));
  const prepared = p.res ? lastRows(p.res) : [];
  ok("prepare: 15 members active, joined_on 2025-06-01, member_no = SR NO", prepared.length === 15 && prepared.every((r, i) => r.status === "active" && Number(r.member_no) === i + 1), p.err ?? JSON.stringify(prepared.slice(0, 2)));
  ok("prepare: the owner account moved out of 1..15", (await count(db, "select member_no as n from public.profiles where email = 'owner.super@example.com'")) > 15);

  // verify -> code -> import files
  const v = await verifyCode(db, outB);
  ok("verify: 15 rows all 'ok' + a confirm code, no emails shown", v.rows.length === 16 && v.rows.slice(0, 15).every((r) => r.problem === "ok") && /^[0-9a-f]{32}$/.test(v.code ?? "") && !JSON.stringify(v.rows).includes("@"), v.err ?? JSON.stringify(v.rows.at(-1)));
  const gC = runGen(["--map", mapA, "--out", outB, "--confirm", v.code]);
  ok("generator with --confirm writes the dry and real files", !gC.err && fs.existsSync(path.join(outB, "run_import_real.sql")), gC.err);

  // pending overlap
  await db.exec(`insert into public.deposits (member_id, period_month, kind, amount, method, status) values ('${fake2}', '2026-10-01', 'monthly', 3000, 'cash', 'pending')`);
  const ov = await tryExec(db, read(outB, "run_import_dry.sql"));
  ok("pending deposit for an imported month: refused, listed", !!ov.err && /pending deposits exist for months the import covers \(No\. 2 2026-10\)/.test(ov.err), ov.err);
  await db.exec(`update public.deposits set status = 'rejected', reject_reason = 'entered before the import' where member_id = '${fake2}' and status = 'pending'`);

  // confirm code mismatch and direct apply
  const mm = await tryExec(db, read(outB, "run_import_real.sql").replace(v.code, "0".repeat(32)));
  ok("wrong confirm code: refused, nothing saved", !!mm.err && /confirm code does not match/.test(mm.err) && await nothingSaved(db), mm.err);
  const direct = await tryExec(db, read(outB, "run_import_real.sql").replace(/select \* from public\.import_history\((\$fd\$[\s\S]*\$fd\$::jsonb), p_confirm => '[0-9a-f]+', p_dry_run => false\);/, "select public.import_apply($1);"));
  ok("calling import_apply directly (SQL Editor) is refused", !!direct.err && /call public.import_history/.test(direct.err) && await nothingSaved(db), direct.err);
  const directApi = await tryExec(db, `${asUser(owner)} set role authenticated; select public.import_apply('{}'::jsonb);`);
  await tryExec(db, asEditor);
  ok("calling import_apply as a logged-in user: permission denied", !!directApi.err && /permission denied/.test(directApi.err), directApi.err);

  // dry run, real run
  const d = await tryExec(db, read(outB, "run_import_dry.sql"));
  const dr = d.res ? lastRows(d.res) : [];
  ok("dry run: report (member, month, plan, check) and nothing saved", ["DRY RUN member", "DRY RUN month", "DRY RUN plan", "DRY RUN check"].every((s) => dr.some((r) => r.section === s)) && await nothingSaved(db), d.err);
  ok("dry run: free money at purchase is in the report", dr.some((r) => r.section === "DRY RUN member" && /free money at purchase 88000/.test(r.value)), JSON.stringify(dr.find((r) => r.section === "DRY RUN member")));
  const rr = await tryExec(db, read(outB, "run_import_real.sql"));
  ok("real import (same confirm code) runs", !rr.err && lastRows(rr.res).some((r) => r.section === "DONE"), rr.err);

  const f = (await db.query("select * from public.fund_totals_internal()")).rows[0];
  ok("totals: deposits 1,770,000; invested 1,241,000; cash 529,000", (await db.query("select sum(amount) as s from public.deposits where status = 'approved'")).rows[0].s == 1770000 && Number(f.invested) === 1241000 && Number(f.cash_available) === 529000, JSON.stringify(f));
  ok("each of the 15 has capital 118,000", (await count(db, "select count(*) as n from public.member_balances_internal() b join public.profiles p on p.id = b.member_id where p.email like 'fd.import.%' and b.capital = 118000")) === 15);
  const extra = (await db.query("select string_agg(p.member_no::text, ',' order by p.member_no) as s from public.investment_participation ip join public.profiles p on p.id = ip.member_id where ip.contribution_delta = 82733.34")).rows[0].s;
  ok("the 5 extra cents go to the lowest SR NO (1..5)", extra === "1,2,3,4,5", extra);
  ok("15 participation rows summing exactly to 1,241,000", (await count(db, "select count(*) as n from public.investment_participation")) === 15 && (await db.query("select sum(contribution_delta) as s from public.investment_participation")).rows[0].s == 1241000);
  ok("every imported deposit has the note 'historical import' and no txn id", (await count(db, "select count(*) as n from public.deposits where import_batch_id is not null and (note <> 'historical import' or transaction_ref is not null)")) === 0);
  ok("the batch keeps the SR -> member map and the reviewed sheet note", (await count(db, "select jsonb_array_length(sr_map) as n from public.import_batches")) === 15 && (await count(db, "select count(*) as n from public.import_batches where source_note like 'February 2026 tab%'")) === 1);
  ok("imported deposits never count for payment rules (late fee, on time, suspension)", (await count(db, "select count(*) as n from public.deposits d where d.import_batch_id is not null and public.counts_for_payment_rules(d)")) === 0);
  const inv = (await db.query("select rule, ok from public.check_invariants(false)")).rows;
  ok(`check_invariants: all ${inv.length} rules pass (rule 27 incl. submitted_at = marker time)`, inv.length >= 27 && inv.every((r) => r.ok), inv.filter((r) => !r.ok).map((r) => r.rule).join(", "));

  // after the import
  const batchId = (await db.query("select id from public.import_batches")).rows[0].id;   // members cannot read it: take it as the editor
  const forge = await tryExec(db, `${asUser(fake1)} set role authenticated;
    insert into public.deposits (member_id, period_month, kind, amount, method, status, import_batch_id)
    values ('${fake1}', '2026-11-01', 'monthly', 3000, 'cash', 'pending', '${batchId}');`);
  await tryExec(db, asEditor);
  ok("a member forging an import batch id is refused", !!forge.err, forge.err);
  const forge2 = await tryExec(db, `insert into public.deposits (member_id, period_month, kind, amount, method, status, import_batch_id)
    values ('${fake1}', '2026-11-01', 'monthly', 3000, 'cash', 'pending', (select id from public.import_batches))`);
  ok("even the SQL Editor cannot add rows to the import batch afterwards", !!forge2.err && /Only the historical import/.test(forge2.err), forge2.err);
  const own = await tryExec(db, `${asUser(fake1)} set role authenticated; select count(*) as n, count(*) filter (where member_id <> '${fake1}') as others, min(note) as note from public.deposits;`);
  const ownRow = own.res ? lastRows(own.res)[0] : {};
  const batchSeen = await tryExec(db, `select count(*) as n from public.import_batches;`);
  await tryExec(db, asEditor);
  ok("a member reads only their own 18 deposits (generic notes), never the batch", Number(ownRow.n) === 18 && Number(ownRow.others) === 0 && ownRow.note === "historical import" && batchSeen.res && Number(lastRows(batchSeen.res)[0].n) === 0, own.err ?? JSON.stringify(ownRow));
  const again = await tryExec(db, read(outB, "run_import_real.sql"));
  ok("second run refused", !!again.err && /already done/.test(again.err), again.err);
  const pend2 = await tryExec(db, `${asUser(await idOf(db, email(3)))} set role authenticated; update public.deposits set status = 'approved' where member_id = '${owner}' and status = 'pending';`);
  await tryExec(db, asEditor);
  ok("after the import the books are open: approving works again", !pend2.err, pend2.err);
}

// wrong member map: two emails swapped after the code was made
{
  const db = await freshDb();
  const out = path.join(tmp, "c"); fs.mkdirSync(out);
  runGen(["--map", mapA, "--out", out]);
  await db.exec(read(out, "run_prepare.sql"));
  const { code } = await verifyCode(db, out);
  const swapped = path.join(tmp, "swapped.csv");
  writeMap(swapped, Array.from({ length: 15 }, (_, i) => `${i + 1},x,${email(i === 0 ? 2 : i === 1 ? 1 : i + 1)}`));
  const out2 = path.join(tmp, "d"); fs.mkdirSync(out2);
  runGen(["--map", swapped, "--out", out2, "--confirm", code]);
  const v2 = await verifyCode(db, out2);
  ok("swapped map: verify flags it (member_no is not the SR NO) and gives no code", v2.rows.filter((r) => /member_no is not the SR NO/.test(r.problem ?? "")).length === 2 && v2.code === "fix the problems above first", JSON.stringify(v2.rows.slice(0, 2)));
  const r = await tryExec(db, read(out2, "run_import_real.sql"));
  ok("swapped map with the old code: refused, nothing saved", !!r.err && /confirm code does not match/.test(r.err) && await nothingSaved(db), r.err);
}

// other refusals
{
  const db = await freshDb({ members: 14 });
  const out = path.join(tmp, "e"); fs.mkdirSync(out);
  runGen(["--map", mapA, "--out", out]);
  const p = await tryExec(db, read(out, "run_prepare.sql"));
  ok("member 15 has no account: prepare refuses, nothing changed", !!p.err && /Only 14 of the 15/.test(p.err) && await nothingSaved(db), p.err);
}
{
  const db = await freshDb();
  const out = path.join(tmp, "f"); fs.mkdirSync(out);
  runGen(["--map", mapA, "--out", out]);
  await db.exec(read(out, "run_prepare.sql"));
  const { code } = await verifyCode(db, out);
  runGen(["--map", mapA, "--out", out, "--confirm", code]);
  const jwt = await tryExec(db, `select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}', false);` + read(out, "run_import_real.sql"));
  await tryExec(db, asEditor);
  ok("with a JWT (website / API): refused", !!jwt.err && /only be run from the Supabase SQL Editor/.test(jwt.err) && await nothingSaved(db), jwt.err);
  const svc = await tryExec(db, "set role service_role;" + read(out, "run_import_real.sql"));
  await tryExec(db, asEditor);
  ok("as service_role: permission denied", !!svc.err && /permission denied/.test(svc.err), svc.err);
  const mis = await tryExec(db, read(out, "run_import_real.sql").replace('"cash":529000', '"cash":529001'));
  ok("payload changed after the code was made: refused by the code", !!mis.err && /confirm code does not match/.test(mis.err) && await nothingSaved(db), mis.err);
  await db.exec("insert into public.system_markers (key) values ('go_live')");
  const live = await tryExec(db, read(out, "run_import_dry.sql"));
  ok("go_live marker present: refused (even the dry run)", !!live.err && /already done \(or the site is live\)/.test(live.err), live.err);
}
{
  // reconciliation still fails loudly when the expectation in a correctly-confirmed payload is wrong
  const db = await freshDb();
  const out = path.join(tmp, "g"); fs.mkdirSync(out);
  runGen(["--map", mapA, "--out", out]);
  await db.exec(read(out, "run_prepare.sql"));
  const verifySql = read(out, "run_verify.sql").replace('"cash":529000', '"cash":529001');
  const v = await tryExec(db, verifySql);
  const code = lastRows(v.res).at(-1).full_name;
  const real = read(out, "run_verify.sql").replace('"cash":529000', '"cash":529001')
    .replace("select * from public.import_verify(", "select * from public.import_history(").replace("::jsonb);", `::jsonb, p_confirm => '${code}', p_dry_run => false);`);
  const r = await tryExec(db, real);
  ok("reconciliation mismatch (expected cash 529001): fails loudly, nothing saved", !!r.err && /RECONCILIATION FAILED/.test(r.err) && await nothingSaved(db), r.err);
}

fs.rmSync(tmp, { recursive: true, force: true });
console.log(`\nRESULT: ${pass} passed, ${fail} failed`);
