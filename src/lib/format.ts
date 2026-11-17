import type { Lang } from "./i18n/types";
import { todayInDhaka } from "./members";

/** ৳ 1,23,456 (Indian digit grouping, English digits in both languages). */
export function formatTaka(value: number | string) {
  const n = Number(value);
  const abs = Math.abs(n).toLocaleString("en-IN", {
    minimumFractionDigits: Number.isInteger(n) ? 0 : 2,
    maximumFractionDigits: 2,
  });
  return `${n < 0 ? "-" : ""}৳ ${abs}`;
}

const locale = (lang: Lang) => (lang === "bn" ? "bn-BD" : "en-GB");

/** "2026-11-01" → "November 2026" / "নভেম্বর ২০২৬" */
export function formatMonth(ymd: string, lang: Lang) {
  const [y, m] = ymd.split("-").map(Number);
  return new Intl.DateTimeFormat(locale(lang), {
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  }).format(new Date(Date.UTC(y, m - 1, 1)));
}

/** Date and time in Bangladesh time. */
export function formatDateTime(iso: string, lang: Lang) {
  return new Intl.DateTimeFormat(locale(lang), {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone: "Asia/Dhaka",
  }).format(new Date(iso));
}

/** First day of the current month in Bangladesh time, as YYYY-MM-01. */
export function currentMonthDhaka() {
  return todayInDhaka().slice(0, 7) + "-01";
}

/** Month starts around the current month: `back` months before and `forward` after (newest first). */
export function monthOptions(back: number, forward: number): string[] {
  const [y, m] = currentMonthDhaka().split("-").map(Number);
  const out: string[] = [];
  for (let i = forward; i >= -back; i--) {
    const d = new Date(Date.UTC(y, m - 1 + i, 1));
    out.push(`${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-01`);
  }
  return out;
}

/** Money text from a form field: "3,000.50" → 3000.5, or null when it is not a valid amount. */
export function parseAmount(text: string, { allowNegative = false } = {}): number | null {
  const cleaned = text.replace(/[,\s]/g, "");
  const re = allowNegative ? /^-?\d+(\.\d{1,2})?$/ : /^\d+(\.\d{1,2})?$/;
  if (!re.test(cleaned)) return null;
  return Number(cleaned);
}

/** "2026-11-30" → "30 November 2026" (date only, no time zone shift). */
export function formatDay(ymd: string, lang: Lang) {
  const [y, m, d] = ymd.split("-").map(Number);
  return new Intl.DateTimeFormat(locale(lang), {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  }).format(new Date(Date.UTC(y, m - 1, d)));
}

/** A timestamp as a date only, in Bangladesh time. */
export function formatDate(iso: string, lang: Lang) {
  return new Intl.DateTimeFormat(locale(lang), { dateStyle: "medium", timeZone: "Asia/Dhaka" }).format(new Date(iso));
}

/** Last day of the current month in Bangladesh time (the deposit deadline), as YYYY-MM-DD. */
export function monthDeadlineDhaka() {
  const [y, m] = currentMonthDhaka().split("-").map(Number);
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return `${y}-${String(m).padStart(2, "0")}-${String(last).padStart(2, "0")}`;
}

/** Whole days from today (Dhaka) to the given YYYY-MM-DD day; 0 = today, negative = passed. */
export function daysUntil(ymd: string) {
  const day = (s: string) => {
    const [y, m, d] = s.split("-").map(Number);
    return Date.UTC(y, m - 1, d);
  };
  return Math.round((day(ymd) - day(todayInDhaka())) / 86_400_000);
}

/** Today in Bangladesh time as YYYY-MM-DD (a plain helper that is safe in server and client code). */
export function todayInDhakaPlain() {
  return todayInDhaka();
}
