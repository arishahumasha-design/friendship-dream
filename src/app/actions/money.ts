"use server";

import { revalidatePath } from "next/cache";
import { getCurrentProfile, isAdminRole } from "@/lib/auth";
import { parseAmount } from "@/lib/format";
import { getI18n } from "@/lib/i18n/server";
import { moneyErrorMessage, packDescription, toCents, fromCents } from "@/lib/money";
import { createClient } from "@/lib/supabase/server";

/**
 * Every money action runs with the signed-in ADMIN's own session and calls one database function (RPC).
 * The database does all the money rules and arithmetic; these actions only check the input types,
 * call the function and turn its answer / error into a friendly sentence in the viewer's language.
 */
export type MoneyResult<T extends object = object> = ({ ok: true } & T) | { ok: false; message: string };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const isStr = (v: unknown): v is string => typeof v === "string";
const isUuid = (v: unknown): v is string => isStr(v) && UUID_RE.test(v);
const isDate = (v: unknown): v is string => isStr(v) && DATE_RE.test(v) && !Number.isNaN(Date.parse(v));
const text = (v: unknown, max = 500) => (isStr(v) ? v.trim().slice(0, max) : "");

async function admin() {
  const { t } = await getI18n();
  const me = await getCurrentProfile();
  if (!me || me.status !== "active" || !isAdminRole(me.role)) {
    return { ok: false as const, message: t.money.errAdminOnly };
  }
  return { ok: true as const, supabase: await createClient(), me, t };
}
const refresh = () => {
  for (const p of ["/admin/expenses", "/admin/investments", "/investments", "/home", "/admin"]) revalidatePath(p);
};

const REQUEST_RPC = {
  expense: "approve_expense",
  expense_reversal: "approve_expense_reversal",
  purchase: "approve_investment",
  investment_cost: "approve_investment_cost",
  sale: "approve_sale",
  income: "approve_income",
} as const;
type ApproveKind = keyof typeof REQUEST_RPC;

/** Approve any waiting request (the database refuses the maker). For a purchase the approver's confirmed total basis is sent along. */
export async function approveRequest(requestId: unknown, kind: unknown, expectedBasis?: unknown): Promise<MoneyResult<{ profit?: number }>> {
  const a = await admin();
  if (!a.ok) return a;
  if (!isUuid(requestId) || !isStr(kind) || !(kind in REQUEST_RPC)) return { ok: false, message: a.t.money.errGeneric };
  const k = kind as ApproveKind;
  const args: Record<string, unknown> = { p_request: requestId };
  if (k === "purchase") {
    const basis = isStr(expectedBasis) || typeof expectedBasis === "number" ? parseAmount(String(expectedBasis)) : null;
    if (basis === null) return { ok: false, message: a.t.money.errGeneric };
    args.p_expected_basis = basis;
  }
  const { data, error } = await a.supabase.rpc(REQUEST_RPC[k], args);
  if (error) return { ok: false, message: moneyErrorMessage(error, a.t) };
  refresh();
  return { ok: true, profit: k === "sale" && data != null ? Number(data) : undefined };
}

export async function rejectRequest(requestId: unknown, reason: unknown): Promise<MoneyResult> {
  const a = await admin();
  if (!a.ok) return a;
  if (!isUuid(requestId)) return { ok: false, message: a.t.money.errGeneric };
  const { error } = await a.supabase.rpc("reject_request", { p_request: requestId, p_reason: text(reason) });
  if (error) return { ok: false, message: moneyErrorMessage(error, a.t) };
  refresh();
  return { ok: true };
}

export async function proposeExpense(input: unknown): Promise<MoneyResult> {
  const a = await admin();
  if (!a.ok) return a;
  if (input === null || typeof input !== "object") return { ok: false, message: a.t.money.errGeneric };
  const i = input as Record<string, unknown>;
  const amount = isStr(i.amount) ? parseAmount(i.amount) : null;
  if (amount === null || !isDate(i.date)) return { ok: false, message: amount === null ? a.t.money.errAmount : a.t.money.errDate };
  if (i.investmentId && !isUuid(i.investmentId)) return { ok: false, message: a.t.money.errGeneric };
  const category = Number(i.categoryId);
  const { error } = await a.supabase.rpc("propose_expense", {
    p_title: text(i.title, 200),
    p_amount: amount,
    p_spent_on: i.date,
    p_category_id: Number.isInteger(category) && category > 0 ? category : null,
    p_investment: isUuid(i.investmentId) ? i.investmentId : null,
    p_description: text(i.description, 1000) || null,
    p_receipt_path: isStr(i.receiptPath) && i.receiptPath ? i.receiptPath : null,
    p_spent_by: text(i.spentBy, 200) || null,
  });
  if (error) return { ok: false, message: moneyErrorMessage(error, a.t) };
  refresh();
  return { ok: true };
}

export async function proposeExpenseReversal(expenseId: unknown, reason: unknown): Promise<MoneyResult> {
  const a = await admin();
  if (!a.ok) return a;
  if (!isUuid(expenseId)) return { ok: false, message: a.t.money.errGeneric };
  const { error } = await a.supabase.rpc("propose_expense_reversal", { p_expense: expenseId, p_reason: text(reason) });
  if (error) return { ok: false, message: moneyErrorMessage(error, a.t) };
  refresh();
  return { ok: true };
}

export async function proposeInvestment(input: unknown): Promise<MoneyResult> {
  const a = await admin();
  if (!a.ok) return a;
  if (input === null || typeof input !== "object") return { ok: false, message: a.t.money.errGeneric };
  const i = input as Record<string, unknown>;
  const cost = isStr(i.cost) ? parseAmount(i.cost) : null;
  if (cost === null) return { ok: false, message: a.t.money.errCostAmount };
  if (!isDate(i.date)) return { ok: false, message: a.t.money.errDate };
  const { error } = await a.supabase.rpc("propose_investment", {
    p_title: text(i.title, 200),
    p_kind: text(i.kind, 20),
    p_purchase_date: i.date,
    p_cost: cost,
    p_description: packDescription({ location: text(i.location, 300), size: text(i.size, 100), note: text(i.note, 1000) }) || null,
  });
  if (error) return { ok: false, message: moneyErrorMessage(error, a.t) };
  refresh();
  return { ok: true };
}

export async function addInvestmentCost(input: unknown): Promise<MoneyResult> {
  const a = await admin();
  if (!a.ok) return a;
  if (input === null || typeof input !== "object") return { ok: false, message: a.t.money.errGeneric };
  const i = input as Record<string, unknown>;
  const amount = isStr(i.amount) ? parseAmount(i.amount) : null;
  if (amount === null) return { ok: false, message: a.t.money.errAmount };
  if (!isDate(i.date)) return { ok: false, message: a.t.money.errDate };
  if (!isUuid(i.target)) return { ok: false, message: a.t.money.errCostTarget };
  const { error } = await a.supabase.rpc("add_investment_cost", {
    p_target: i.target,
    p_amount: amount,
    p_title: text(i.title, 200),
    p_date: i.date,
    p_description: text(i.note, 1000) || null,
  });
  if (error) return { ok: false, message: moneyErrorMessage(error, a.t) };
  refresh();
  return { ok: true };
}

export async function proposeSale(input: unknown): Promise<MoneyResult> {
  const a = await admin();
  if (!a.ok) return a;
  if (input === null || typeof input !== "object") return { ok: false, message: a.t.money.errGeneric };
  const i = input as Record<string, unknown>;
  const proceeds = isStr(i.proceeds) ? parseAmount(i.proceeds) : null;
  if (proceeds === null) return { ok: false, message: a.t.money.errSaleAmount };
  if (!isDate(i.date)) return { ok: false, message: a.t.money.errDate };
  if (!isUuid(i.investmentId)) return { ok: false, message: a.t.money.errInvestmentNotFound };
  const { error } = await a.supabase.rpc("propose_sale", {
    p_investment: i.investmentId,
    p_proceeds: proceeds,
    p_sale_date: i.date,
    p_note: text(i.note, 1000) || null,
  });
  if (error) return { ok: false, message: moneyErrorMessage(error, a.t) };
  refresh();
  return { ok: true };
}

/**
 * The expected result of a sale (proceeds minus cost basis), worked out HERE on the server from the two
 * stored amounts, in whole cents. The browser only shows it. The real split to members is done by the
 * database when a second admin approves.
 */
export async function previewSale(investmentId: unknown, proceeds: unknown): Promise<MoneyResult<{ basis: number; result: number }>> {
  const a = await admin();
  if (!a.ok) return a;
  const amount = isStr(proceeds) ? parseAmount(proceeds) : null;
  if (!isUuid(investmentId) || amount === null) return { ok: false, message: a.t.money.errSaleAmount };
  const { data } = await a.supabase
    .from("investments")
    .select("cost, capitalized_costs, status")
    .eq("id", investmentId)
    .maybeSingle();
  if (!data) return { ok: false, message: a.t.money.errInvestmentNotFound };
  if (data.status !== "held") return { ok: false, message: a.t.money.errAlreadySold };
  const basisC = toCents(data.cost) + toCents(data.capitalized_costs);
  return { ok: true, basis: fromCents(basisC), result: fromCents(toCents(amount) - basisC) };
}

export async function recordIncome(input: unknown): Promise<MoneyResult> {
  const a = await admin();
  if (!a.ok) return a;
  if (input === null || typeof input !== "object") return { ok: false, message: a.t.money.errGeneric };
  const i = input as Record<string, unknown>;
  if (!isUuid(i.investmentId)) return { ok: false, message: a.t.money.errInvestmentNotFound };
  if (!isDate(i.date)) return { ok: false, message: a.t.money.errDate };
  // A reversal names the original entry; its amount is the whole original amount with the sign flipped
  // (read from the database here, in whole cents, so the browser never works it out).
  const reverses = isUuid(i.reverses) ? i.reverses : null;
  let amount: number | null;
  if (reverses) {
    const { data: orig } = await a.supabase.from("investment_income").select("amount").eq("id", reverses).maybeSingle();
    amount = orig ? fromCents(-toCents(orig.amount)) : null;
  } else {
    amount = isStr(i.amount) ? parseAmount(i.amount) : null;
  }
  if (amount === null || amount === 0) return { ok: false, message: a.t.money.errIncomeAmount };
  const { error } = await a.supabase.rpc("record_income", {
    p_investment: i.investmentId,
    p_amount: amount,
    p_received_on: i.date,
    p_note: text(i.note, 1000) || null,
    p_reverses: reverses,
  });
  if (error) return { ok: false, message: moneyErrorMessage(error, a.t) };
  refresh();
  return { ok: true };
}
