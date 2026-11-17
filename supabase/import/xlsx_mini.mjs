// Tiny, dependency-free .xlsx reader (enough for a Google Sheets export): sheet names + cell values.
// Reads the zip central directory, inflates the XML parts with Node's zlib, parses cells with regexes.
import fs from "fs";
import zlib from "zlib";

function unzip(buf) {
  // find "end of central directory" record
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 65557); i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error("Not a zip / xlsx file");
  const count = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16);
  const files = {};
  for (let n = 0; n < count; n++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) throw new Error("Bad zip central directory");
    const method = buf.readUInt16LE(p + 10);
    const csize = buf.readUInt32LE(p + 20);
    const nameLen = buf.readUInt16LE(p + 28), extraLen = buf.readUInt16LE(p + 30), commentLen = buf.readUInt16LE(p + 32);
    const local = buf.readUInt32LE(p + 42);
    const name = buf.slice(p + 46, p + 46 + nameLen).toString("utf8");
    const lNameLen = buf.readUInt16LE(local + 26), lExtraLen = buf.readUInt16LE(local + 28);
    const data = buf.slice(local + 30 + lNameLen + lExtraLen, local + 30 + lNameLen + lExtraLen + csize);
    files[name] = method === 8 ? zlib.inflateRawSync(data) : data;
    p += 46 + nameLen + extraLen + commentLen;
  }
  return files;
}

const unesc = (s) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'")
  .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(Number(d))).replace(/&amp;/g, "&");

function colIndex(ref) {
  const letters = ref.match(/^[A-Z]+/)[0];
  let n = 0;
  for (const ch of letters) n = n * 26 + (ch.charCodeAt(0) - 64);
  return n - 1;
}

/** Returns [{ name, rows: Array<Array<string|number|null>> }] for every sheet, in workbook order. */
export function readXlsx(path) {
  const files = unzip(fs.readFileSync(path));
  const text = (n) => (files[n] ? files[n].toString("utf8") : "");
  const shared = [];
  for (const si of text("xl/sharedStrings.xml").match(/<si>[\s\S]*?<\/si>/g) ?? []) {
    shared.push(unesc((si.match(/<t[^>]*>([\s\S]*?)<\/t>/g) ?? []).map((t) => t.replace(/<t[^>]*>|<\/t>/g, "")).join("")));
  }
  const rels = {};
  for (const r of text("xl/_rels/workbook.xml.rels").match(/<Relationship [^>]*>/g) ?? []) {
    const id = r.match(/Id="([^"]+)"/)[1], target = r.match(/Target="([^"]+)"/)[1];
    rels[id] = target.startsWith("/") ? target.slice(1) : "xl/" + target;
  }
  const sheets = [];
  for (const s of text("xl/workbook.xml").match(/<sheet [^>]*\/>/g) ?? []) {
    const name = unesc(s.match(/name="([^"]+)"/)[1]);
    const rid = s.match(/r:id="([^"]+)"/)[1];
    const xml = text(rels[rid]);
    const rows = [];
    // self-closing <row .../> FIRST: otherwise "<row r="3"/>" would open a row that runs on to the NEXT </row>
    for (const row of xml.match(/<row\b[^>]*\/>|<row\b[^>]*>[\s\S]*?<\/row>/g) ?? []) {
      const rIdx = Number(row.match(/ r="(\d+)"/)[1]) - 1;
      const cells = [];
      for (const c of row.match(/<c [^>]*\/>|<c [^>]*>[\s\S]*?<\/c>/g) ?? []) {
        const ref = c.match(/ r="([A-Z]+\d+)"/)[1];
        const type = (c.match(/ t="([^"]+)"/) ?? [])[1];
        const v = (c.match(/<v>([\s\S]*?)<\/v>/) ?? [])[1];
        const inl = (c.match(/<is>[\s\S]*?<t[^>]*>([\s\S]*?)<\/t>/) ?? [])[1];
        let val = null;
        if (type === "s") val = shared[Number(v)];
        else if (type === "inlineStr") val = unesc(inl ?? "");
        else if (type === "str" || type === "e") val = v != null ? unesc(v) : null;
        else if (type === "b") val = v === "1";
        else if (v != null) val = Number(v);
        cells[colIndex(ref)] = val;
      }
      rows[rIdx] = cells;
    }
    sheets.push({ name, rows: Array.from(rows, (r) => r ?? []) });
  }
  return sheets;
}

/** Hide anything that looks like an email or a phone number (never print personal contact data). */
export function mask(v) {
  if (v == null) return v;
  const s = String(v);
  if (/@/.test(s)) return "[email hidden]";
  if (/(\+?88)?0?1[3-9]\d{2}[\s-]?\d{6}/.test(s.replace(/[\s-]/g, "")) || /\d{9,}/.test(s.replace(/[\s-]/g, ""))) return "[number hidden]";
  return v;
}
