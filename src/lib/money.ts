import type { Dictionary } from "./i18n/types";
import { formatTaka } from "./format";

/** Whole cents from a database number: used only to add up STORED amounts without float errors. */
export const toCents = (v: number | string | null | undefined) => Math.round(Number(v ?? 0) * 100);
export const fromCents = (c: number) => c / 100;
export const sumCents = (values: (number | string | null | undefined)[]) => values.reduce<number>((s, v) => s + toCents(v), 0);

export type MoneyKey = keyof Dictionary["money"];

/**
 * Database error text -> friendly message key (+ the numbers found in the text).
 * Raw SQL text is never shown. Order matters: the first match wins.
 */
const ERROR_TABLE: { re: RegExp; key: MoneyKey; params?: string[] }[] = [
  { re: /Only an active admin can do this/i, key: "errAdminOnly" },
  { re: /books open after the historical import/i, key: "errBooksClosed" },
  { re: /cannot approve your own entry/i, key: "errOwnEntry" },
  { re: /Give the investment a name/i, key: "errName" },
  { re: /Choose land, shop or other/i, key: "errKind" },
  { re: /must be between ([\d-]+) and ([\d-]+)/i, key: "errDateRange", params: ["from", "to"] },
  { re: /The cost must be more than 0/i, key: "errCostAmount" },
  { re: /The amount must be more than 0/i, key: "errAmount" },
  { re: /Say what this cost is for/i, key: "errCostTitle" },
  { re: /Say what the expense is for/i, key: "errExpenseTitle" },
  { re: /Choose a purchase that is still waiting/i, key: "errCostTarget" },
  { re: /Request not found/i, key: "errRequestNotFound" },
  { re: /This request is a/i, key: "errWrongKind" },
  { re: /This request was already/i, key: "errAlreadyDecided" },
  { re: /Approve or reject the pending cost items/i, key: "errPendingCosts" },
  { re: /The total cost is now (\d+(?:\.\d+)?) \(you confirmed (\d+(?:\.\d+)?|)\)/i, key: "errBasisChanged", params: ["now", "confirmed"] },
  { re: /Not enough free money: this purchase needs (\d+(?:\.\d+)?), the members who can take part have (\d+(?:\.\d+)?)/i, key: "errNotEnoughFree", params: ["need", "have"] },
  { re: /Cash in hand cannot go below zero \(it would be (-?\d+(?:\.\d+)?)\)/i, key: "errCashNegative", params: ["cash"] },
  { re: /no longer waiting; this cost cannot join/i, key: "errPurchaseGone" },
  { re: /Investment not found/i, key: "errInvestmentNotFound" },
  { re: /not held any more|investment that is still held/i, key: "errNotHeld" },
  { re: /A reversal must be a negative amount/i, key: "errReversalNegative" },
  { re: /already sold/i, key: "errAlreadySold" },
  { re: /sale of this investment is already waiting/i, key: "errSaleWaiting" },
  { re: /The sale amount must be 0 or more/i, key: "errSaleAmount" },
  { re: /sale date must be on or after the purchase date/i, key: "errSaleDate" },
  { re: /Approve or reject the waiting costs/i, key: "errWaitingCosts" },
  { re: /Give the date/i, key: "errDate" },
  { re: /Give an amount \(not 0\)/i, key: "errIncomeAmount" },
  { re: /Income must be more than 0/i, key: "errIncomePositive" },
  { re: /Choose the original income entry/i, key: "errReverseTarget" },
  { re: /A reversal undoes the whole entry: the amount must be (-?\d+(?:\.\d+)?)/i, key: "errReversalFull", params: ["amount"] },
  { re: /income entry is already reversed/i, key: "errIncomeReversed" },
  { re: /receipt must be uploaded to your own folder/i, key: "errReceiptFolder" },
  { re: /Choose an approved expense to reverse/i, key: "errExpenseChoose" },
  { re: /Give the reason for the reversal/i, key: "errReversalReason" },
  { re: /expense is already reversed/i, key: "errExpenseReversed" },
  { re: /original expense was not found/i, key: "errExpenseNotFound" },
  { re: /Give a reason/i, key: "errReason" },
  { re: /nobody to share|Cannot split/i, key: "errNobody" },
  { re: /READ COMMITTED/i, key: "errGeneric" },
  { re: /permission denied|row-level security/i, key: "errNotAllowed" },
];

const MONEY_PARAMS = new Set(["now", "confirmed", "need", "have", "cash", "amount"]);

/** The friendly sentence for a database / RPC error, in the viewer's language. */
export function moneyErrorMessage(
  err: { message?: string; code?: string } | null | undefined,
  t: Dictionary,
): string {
  const text = err?.message ?? "";
  for (const row of ERROR_TABLE) {
    const m = text.match(row.re);
    if (!m) continue;
    let out: string = t.money[row.key];
    (row.params ?? []).forEach((name, i) => {
      const raw = m[i + 1] ?? "";
      const val = raw === "" ? "—" : MONEY_PARAMS.has(name) ? formatTaka(Number(raw)) : raw;
      out = out.replaceAll(`{${name}}`, val);
    });
    return out;
  }
  // Only the error CODE is logged, never row data.
  console.error("money rpc error code:", err?.code ?? "unknown");
  return t.money.errGeneric;
}

/** Location / size / note are kept inside the investment's description text (the RPC has one text field). */
export function packDescription(f: { location?: string; size?: string; note?: string }) {
  return [
    f.location?.trim() ? `location: ${f.location.trim()}` : "",
    f.size?.trim() ? `size: ${f.size.trim()}` : "",
    f.note?.trim() ? `note: ${f.note.trim()}` : "",
  ]
    .filter(Boolean)
    .join("\n");
}

export function unpackDescription(text: string | null | undefined) {
  const out: { location?: string; size?: string; note?: string; rest?: string } = {};
  const rest: string[] = [];
  for (const line of String(text ?? "").split("\n")) {
    const m = line.match(/^(location|size|note): (.*)$/);
    if (m) out[m[1] as "location" | "size" | "note"] = m[2];
    else if (line.trim()) rest.push(line);
  }
  if (rest.length) out.rest = rest.join("\n");
  return out;
}
