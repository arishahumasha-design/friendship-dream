// One-time historical import: Google Sheet export (.xlsx) + member_map.csv  ->  SQL files for the SQL Editor.
//
//   1st run (no member_map.csv yet):  writes supabase/import/member_map.csv  -> fill in the login emails
//   2nd run (emails filled):          writes run_prepare.sql and run_verify.sql
//   3rd run with --confirm <code>:    also writes run_import_dry.sql and run_import_real.sql
//   options: --xlsx <file>  --map <file>  --out <folder>  --confirm <code>
//
// The SQL files contain the members' login emails. They are written OUTSIDE the project folder, by default to
//   %USERPROFILE%\fd-import-out   (Windows)   /   ~/fd-import-out
// Delete that folder after the real run.
//
// Reads ONLY: SR NO, the name (for the map template), Amount and Yearly Amount of every month tab and the
// Home / Projects totals. Phone numbers, emails, transaction IDs and notes in the sheet are never read.
// Members are matched ONLY by SR NO.
import fs from "fs";
import os from "os";
import path from "path";
import { readXlsx } from "./xlsx_mini.mjs";

const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"));
const root = path.resolve(here, "../..");
const arg = (name, def) => { const i = process.argv.indexOf("--" + name); return i > 0 ? process.argv[i + 1] : def; };
const xlsxPath = arg("xlsx", fs.readdirSync(root).filter((f) => /^Friendship.*\.xlsx$/i.test(f)).map((f) => path.join(root, f))[0]);
const mapPath = arg("map", path.join(here, "member_map.csv"));
const outDir = arg("out", path.join(os.homedir(), "fd-import-out"));
const confirm = arg("confirm", null);

// ---- facts confirmed by the owner (the sheet must agree, otherwise we stop) ----
const FACTS = {
  members: 15,
  monthly: 3000,
  firstMonth: "2025-06-01",
  lastMonth: "2026-10-01",
  months: 17,
  yearly: { month: "2025-12-01", amount: 67000 },
  joinedOn: "2025-06-01",
  depositNote: "historical import",
  // Reviewed by hand, NOT parsed from the sheet. Kept only on the import batch (admins only).
  // The member-by-member lines of that note name members and amounts; they are deliberately not copied
  // into this repository (no personal data in git) — they stay in the February 2026 tab of the sheet.
  sheetNote:
    "February 2026 tab, note: \"এখানে ২০২৫ সালের yearly payment মাসিক সঞ্চয়ে রূপান্তরিত করা হলো।\" " +
    "(2025 yearly payments were re-classified as monthly savings; this changes the classification only, not any total. " +
    "Cell values were imported as they are. The per-member details are in that tab of the original Google Sheet.)",
  purchase: {
    title: "First land (about 9 shatak)",
    kind: "land",
    date: "2025-12-09",
    cost: 1125000,
    description: "Seller paid 1,125,000 (Projects tab of the Google Sheet).",
    items: [
      { title: "Deed (dolil)", amount: 113500 },
      { title: "Copy (nokol)", amount: 2000 },
      { title: "Other costs", amount: 500 },
    ],
  },
  expect: { members: 15, total_deposits: 1770000, invested: 1241000, cash: 529000, member_capital: 118000, participants: 15 },
};
const MONTHS = { january: 1, february: 2, march: 3, april: 4, may: 5, june: 6, july: 7, august: 8, september: 9, septamber: 9, october: 10, november: 11, december: 12 };

const stop = (msg) => { console.error("STOP: " + msg); process.exit(1); };

/** Minimal CSV parser (quotes, doubled quotes, commas inside quotes). */
export function parseCsv(text) {
  const rows = [];
  let row = [], cur = "", q = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (q) {
      if (ch === '"' && text[i + 1] === '"') { cur += '"'; i++; }
      else if (ch === '"') q = false;
      else cur += ch;
    } else if (ch === '"') q = true;
    else if (ch === ",") { row.push(cur); cur = ""; }
    else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++;
      row.push(cur); cur = "";
      if (row.some((c) => c.trim() !== "")) rows.push(row);
      row = [];
    } else cur += ch;
  }
  row.push(cur);
  if (row.some((c) => c.trim() !== "")) rows.push(row);
  return rows.map((r) => r.map((c) => c.trim()));
}

if (!xlsxPath || !fs.existsSync(xlsxPath)) stop("the .xlsx export was not found in the project folder (use --xlsx <file>).");
const sheets = readXlsx(xlsxPath);
const cell = (s, r, c) => (s.rows[r - 1] ?? [])[c.charCodeAt(0) - 65];
const num = (v) => (typeof v === "number" ? v : v == null || v === "" || v === "-" ? 0 : Number(String(v).replace(/,/g, "")));

// ---- Home: names for the template, totals for the cross-check ----
const home = sheets.find((s) => s.name.trim().toLowerCase() === "home") ?? stop("no Home tab");
const homeMembers = [];
for (let r = 5; r < 5 + FACTS.members; r++) homeMembers.push({ sr: num(cell(home, r, "B")), name: String(cell(home, r, "C") ?? "").trim() });
if (homeMembers.map((m) => m.sr).join() !== Array.from({ length: FACTS.members }, (_, i) => i + 1).join()) stop("Home tab: SR NO is not 1..15");
const homeTotals = { grand: num(cell(home, 20, "E")), invest: num(cell(home, 21, "E")), present: num(cell(home, 22, "E")) };

// ---- member map ----
if (!fs.existsSync(mapPath)) {
  const csv = "sr_no,sheet_name,email\n" + homeMembers.map((m) => `${m.sr},"${m.name.replace(/"/g, '""')}",`).join("\n") + "\n";
  fs.writeFileSync(mapPath, csv);
  console.log(`Wrote ${path.relative(root, mapPath)} with ${homeMembers.length} rows and an EMPTY email column.`);
  console.log("Fill in each member's login email (after their account exists), save, and run this script again.");
  process.exit(0);
}
const csvRows = parseCsv(fs.readFileSync(mapPath, "utf8"));
const head = csvRows.shift().map((h) => h.toLowerCase());
if (head.join() !== "sr_no,sheet_name,email") stop("member_map.csv must have the columns sr_no,sheet_name,email");
const members = csvRows.map((r) => ({ sr_no: Number(r[0]), sheet_name: r[1] ?? "", email: (r[2] ?? "").toLowerCase() }));
if (members.length !== FACTS.members) stop(`member_map has ${members.length} rows, expected ${FACTS.members}`);
if (members.some((m) => !Number.isInteger(m.sr_no)) || members.map((m) => m.sr_no).sort((a, b) => a - b).join() !== homeMembers.map((m) => m.sr).join()) {
  stop("member_map: sr_no must be 1..15, each once");
}
const missing = members.filter((m) => !/^[^\s@,"]+@[^\s@,"]+\.[^\s@,"]+$/.test(m.email)).map((m) => m.sr_no);
if (missing.length) stop(`member_map: SR NO ${missing.join(", ")} have no valid email yet`);
if (new Set(members.map((m) => m.email)).size !== members.length) stop("member_map: the same email is used twice");
members.sort((a, b) => a.sr_no - b.sr_no);

// ---- month tabs ----
const deposits = [];
const monthTotals = [];
for (const s of sheets) {
  if (String(cell(s, 4, "B") ?? "").trim().toUpperCase() !== "SR NO." || String(cell(s, 4, "H") ?? "").trim() !== "Amount") continue;
  const mName = String(cell(s, 1, "G") ?? "").trim().toLowerCase();
  const year = num(cell(s, 1, "H"));
  if (!MONTHS[mName] || !year) stop(`tab "${s.name}": cannot read the month/year in G1/H1`);
  const month = `${year}-${String(MONTHS[mName]).padStart(2, "0")}-01`;
  let monthly = 0, yearly = 0;
  for (let r = 5; r < 5 + FACTS.members; r++) {
    const sr = num(cell(s, r, "B"));
    if (sr !== r - 4) stop(`tab "${s.name}": row ${r} is not SR NO ${r - 4}`);
    const a = num(cell(s, r, "H")), y = num(cell(s, r, "I"));
    if (a) { deposits.push({ sr_no: sr, month, kind: "monthly", amount: a, note: FACTS.depositNote }); monthly += a; }
    if (y) { deposits.push({ sr_no: sr, month, kind: "yearly", amount: y, note: FACTS.depositNote }); yearly += y; }
  }
  if (num(cell(s, 20, "H")) !== monthly || num(cell(s, 20, "I")) !== yearly) stop(`tab "${s.name}": row totals do not match the sheet's own total`);
  monthTotals.push({ tab: s.name, month, monthly, yearly });
}
monthTotals.sort((a, b) => a.month.localeCompare(b.month));

// ---- cross-check against the confirmed facts ----
if (monthTotals.length !== FACTS.months) stop(`found ${monthTotals.length} month tabs, expected ${FACTS.months}`);
if (monthTotals[0].month !== FACTS.firstMonth || monthTotals.at(-1).month !== FACTS.lastMonth) stop("month range is not June 2025 .. October 2026");
if (new Set(monthTotals.map((m) => m.month)).size !== FACTS.months) stop("a month appears twice");
for (const d of deposits) {
  if (d.kind === "monthly" && d.amount !== FACTS.monthly) stop(`SR ${d.sr_no} ${d.month}: monthly amount ${d.amount} is not ${FACTS.monthly}`);
  if (d.kind === "yearly" && (d.month !== FACTS.yearly.month || d.amount !== FACTS.yearly.amount)) stop(`SR ${d.sr_no} ${d.month}: unexpected yearly amount`);
}
const total = deposits.reduce((s, d) => s + d.amount, 0);
const basis = FACTS.purchase.cost + FACTS.purchase.items.reduce((s, i) => s + i.amount, 0);
if (total !== FACTS.expect.total_deposits || homeTotals.grand !== total) stop(`total deposits ${total} / Home ${homeTotals.grand} is not ${FACTS.expect.total_deposits}`);
if (basis !== FACTS.expect.invested || homeTotals.invest !== basis) stop(`land cost ${basis} / Home ${homeTotals.invest} is not ${FACTS.expect.invested}`);
if (homeTotals.present !== total - basis || total - basis !== FACTS.expect.cash) stop("present value does not match");
const projects = sheets.find((s) => s.name.trim().toLowerCase() === "projects");
if (!projects || num(cell(projects, 3, "C")) !== basis) stop("Projects tab total is not 1241000");

// ---- write the SQL files (outside the repository) ----
const payload = {
  label: "historical import from Google Sheet (June 2025 - October 2026)",
  source_note: FACTS.sheetNote,
  joined_on: FACTS.joinedOn,
  members,
  deposits,
  purchase: FACTS.purchase,
  expect: FACTS.expect,
};
const json = JSON.stringify(payload);
if (json.includes("$fd$")) stop("unexpected text in the data");
fs.mkdirSync(outDir, { recursive: true });
const sq = (s) => `'${String(s).replace(/'/g, "''")}'`;
const emailList = members.map((m) => sq(m.email)).join(", ");
const header = (what) => `-- ${what}\n-- GENERATED by supabase/import/build_import.mjs on ${new Date().toISOString()}.\n-- Contains the members' login emails: do NOT share. Delete this folder after the real run.\n\n`;

fs.writeFileSync(path.join(outDir, "run_prepare.sql"), header(`Step 1 (prepare): the 15 members become active, joined_on = ${FACTS.joinedOn}, member_no = SR NO`) + `do $$
declare n int;
begin
  -- accounts are found by their LOGIN email (auth.users), and the email must be confirmed
  select count(*) into n
    from auth.users u join public.profiles p on p.id = u.id
   where lower(u.email) in (${emailList}) and u.email_confirmed_at is not null;
  if n <> ${FACTS.members} then
    raise exception 'Only % of the ${FACTS.members} members have an account with a CONFIRMED email. Ask the others to sign up and confirm first. Nothing was changed.', n;
  end if;
end $$;
-- other accounts move out of the way of the numbers 1..${FACTS.members}
update public.profiles set member_no = member_no + 1000
 where member_no <= ${FACTS.members}
   and id not in (select u.id from auth.users u where lower(u.email) in (${emailList}) and u.email_confirmed_at is not null);
update public.profiles p
   set status = 'active', joined_on = date '${FACTS.joinedOn}', member_no = m.sr
  from (values ${members.map((m) => `(${m.sr_no}, ${sq(m.email)})`).join(", ")}) as m(sr, email)
  join auth.users u on lower(u.email) = m.email and u.email_confirmed_at is not null
 where p.id = u.id;
select setval(pg_get_serial_sequence('public.profiles', 'member_no'), (select greatest(max(member_no), ${FACTS.members}) from public.profiles));
update public.app_settings set value = '"${FACTS.firstMonth}"' where key = 'samiti_start';
select p.member_no, p.status, p.joined_on
  from public.profiles p join auth.users u on u.id = p.id
 where lower(u.email) in (${emailList}) and u.email_confirmed_at is not null
 order by p.member_no;
`);
fs.writeFileSync(path.join(outDir, "run_verify.sql"), header("Step 2 (verify): check every SR NO -> name; the last row is the CONFIRM CODE")
  + `select * from public.import_verify($fd$${json}$fd$::jsonb);\n`);

if (confirm) {
  if (!/^[0-9a-f]{32}$/.test(confirm)) stop("--confirm must be the 32-character code from run_verify.sql");
  for (const [file, dry] of [["run_import_dry.sql", true], ["run_import_real.sql", false]]) {
    fs.writeFileSync(path.join(outDir, file), header(dry ? "Step 3 (DRY RUN): shows what the import would do; saves NOTHING" : "Step 4 (REAL IMPORT): saves the history. It can only ever run once.")
      + `select * from public.import_history($fd$${json}$fd$::jsonb, p_confirm => '${confirm}', p_dry_run => ${dry});\n`);
  }
} else {
  for (const f of ["run_import_dry.sql", "run_import_real.sql"]) fs.rmSync(path.join(outDir, f), { force: true });
}

console.log(`Read ${monthTotals.length} month tabs (${monthTotals[0].tab} .. ${monthTotals.at(-1).tab}), ${members.length} members, ${deposits.length} deposit rows.`);
console.log(`Total deposits ${total}, land basis ${basis} (cost ${FACTS.purchase.cost} + ${basis - FACTS.purchase.cost}), cash ${total - basis}.`);
console.log(`Wrote run_prepare.sql, run_verify.sql${confirm ? ", run_import_dry.sql, run_import_real.sql" : ""} to ${outDir}`);
if (!confirm) console.log("Next: run run_prepare.sql, then run_verify.sql, check the names, then run this script again with --confirm <code>.");
