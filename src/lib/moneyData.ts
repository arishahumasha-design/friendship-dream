import type { SupabaseClient } from "@supabase/supabase-js";
import { sumCents, fromCents, toCents } from "./money";

export type RequestKind = "purchase" | "investment_cost" | "sale" | "income" | "expense" | "expense_reversal";
export type RequestStatus = "pending" | "approved" | "rejected";

export type MoneyRequest = {
  id: string;
  kind: RequestKind;
  status: RequestStatus;
  title: string | null;
  investmentKind: "land" | "shop" | "other" | null;
  amount: number;
  eventDate: string;
  description: string | null;
  categoryId: number | null;
  hasReceipt: boolean;
  receiptIsPdf: boolean;
  spentBy: string | null;
  investmentId: string | null;
  purchaseRequestId: string | null;
  reversesIncomeId: string | null;
  reversesExpenseId: string | null;
  proposedBy: string | null;
  proposedAt: string;
  decidedBy: string | null;
  decidedAt: string | null;
  rejectReason: string | null;
  resultId: string | null;
};

// import_batch_id is deliberately NOT selected: it only exists after migration 011.
const REQUEST_COLUMNS =
  "id, kind, status, title, investment_kind, amount, event_date, description, category_id, receipt_path, spent_by, investment_id, purchase_request_id, reverses_income_id, reverses_expense_id, proposed_by, proposed_at, decided_by, decided_at, reject_reason, result_id";

type RawRequest = Record<string, unknown>;
const mapRequest = (r: RawRequest): MoneyRequest => ({
  id: String(r.id),
  kind: r.kind as RequestKind,
  status: r.status as RequestStatus,
  title: (r.title as string | null) ?? null,
  investmentKind: (r.investment_kind as MoneyRequest["investmentKind"]) ?? null,
  amount: Number(r.amount),
  eventDate: String(r.event_date),
  description: (r.description as string | null) ?? null,
  categoryId: (r.category_id as number | null) ?? null,
  hasReceipt: !!r.receipt_path,
  receiptIsPdf: typeof r.receipt_path === "string" && r.receipt_path.toLowerCase().endsWith(".pdf"),
  spentBy: (r.spent_by as string | null) ?? null,
  investmentId: (r.investment_id as string | null) ?? null,
  purchaseRequestId: (r.purchase_request_id as string | null) ?? null,
  reversesIncomeId: (r.reverses_income_id as string | null) ?? null,
  reversesExpenseId: (r.reverses_expense_id as string | null) ?? null,
  proposedBy: (r.proposed_by as string | null) ?? null,
  proposedAt: String(r.proposed_at),
  decidedBy: (r.decided_by as string | null) ?? null,
  decidedAt: (r.decided_at as string | null) ?? null,
  rejectReason: (r.reject_reason as string | null) ?? null,
  resultId: (r.result_id as string | null) ?? null,
});

/** Requests (admins only: RLS). `kinds` and `status` narrow the list; newest decisions first. */
export async function loadRequests(
  supabase: SupabaseClient,
  opts: { kinds: RequestKind[]; status?: RequestStatus; range?: [number, number] },
) {
  let q = supabase.from("money_requests").select(REQUEST_COLUMNS, { count: "exact" }).in("kind", opts.kinds);
  if (opts.status) q = q.eq("status", opts.status);
  q = opts.status === "pending" ? q.order("proposed_at", { ascending: true }) : q.order("proposed_at", { ascending: false });
  if (opts.range) q = q.range(opts.range[0], opts.range[1]);
  const { data, count, error } = await q;
  if (error) console.error("money_requests error code:", error.code ?? "unknown");
  return { rows: ((data ?? []) as RawRequest[]).map(mapRequest), count: count ?? 0, failed: !!error };
}

export type Investment = {
  id: string;
  title: string;
  kind: "land" | "shop" | "other";
  description: string | null;
  purchaseDate: string;
  cost: number;
  capitalizedCosts: number;
  /** cost + extra costs, added up from the two stored amounts (whole cents) */
  basis: number;
  status: "held" | "sold";
  saleDate: string | null;
  saleAmount: number | null;
  /** sale amount minus basis: both stored amounts, subtracted in whole cents (null while held) */
  result: number | null;
};

export async function loadInvestments(supabase: SupabaseClient) {
  const { data, error } = await supabase
    .from("investments")
    .select("id, title, kind, description, purchase_date, cost, capitalized_costs, status, sale_date, sale_amount")
    .order("purchase_date", { ascending: false })
    .order("created_at", { ascending: false });
  if (error) console.error("investments error code:", error.code ?? "unknown");
  const rows: Investment[] = ((data ?? []) as RawRequest[]).map((r) => {
    const basisC = toCents(r.cost as number) + toCents(r.capitalized_costs as number);
    const sold = r.status === "sold";
    return {
      id: String(r.id),
      title: String(r.title),
      kind: r.kind as Investment["kind"],
      description: (r.description as string | null) ?? null,
      purchaseDate: String(r.purchase_date),
      cost: Number(r.cost),
      capitalizedCosts: Number(r.capitalized_costs ?? 0),
      basis: fromCents(basisC),
      status: sold ? "sold" : "held",
      saleDate: (r.sale_date as string | null) ?? null,
      saleAmount: r.sale_amount == null ? null : Number(r.sale_amount),
      result: sold && r.sale_amount != null ? fromCents(toCents(r.sale_amount as number) - basisC) : null,
    };
  });
  return { rows, failed: !!error };
}

export type IncomeRow = {
  id: string;
  investmentId: string;
  amount: number;
  receivedOn: string;
  note: string | null;
  reversesIncomeId: string | null;
  createdBy: string | null;
  approvedBy: string | null;
};

export async function loadIncome(supabase: SupabaseClient) {
  const { data, error } = await supabase
    .from("investment_income")
    .select("id, investment_id, amount, received_on, note, reverses_income_id, created_by, approved_by")
    .order("received_on", { ascending: false });
  if (error) console.error("income error code:", error.code ?? "unknown");
  const rows: IncomeRow[] = ((data ?? []) as RawRequest[]).map((r) => ({
    id: String(r.id),
    investmentId: String(r.investment_id),
    amount: Number(r.amount),
    receivedOn: String(r.received_on),
    note: (r.note as string | null) ?? null,
    reversesIncomeId: (r.reverses_income_id as string | null) ?? null,
    createdBy: (r.created_by as string | null) ?? null,
    approvedBy: (r.approved_by as string | null) ?? null,
  }));
  return rows;
}

/** Total income (reversals are negative rows) per investment, added up in whole cents. */
export function incomeTotals(rows: IncomeRow[]) {
  const by = new Map<string, number[]>();
  for (const r of rows) by.set(r.investmentId, [...(by.get(r.investmentId) ?? []), r.amount]);
  return new Map([...by].map(([id, v]) => [id, fromCents(sumCents(v))]));
}

export type ExpenseRow = {
  id: string;
  title: string;
  amount: number;
  spentOn: string;
  categoryId: number | null;
  investmentId: string | null;
  description: string | null;
  spentBy: string | null;
  hasReceipt: boolean;
  receiptIsPdf: boolean;
  reversesExpenseId: string | null;
  createdBy: string | null;
  approvedBy: string | null;
};

export async function loadExpenses(supabase: SupabaseClient, range?: [number, number]) {
  let q = supabase
    .from("expenses")
    .select(
      "id, title, amount, spent_on, category_id, investment_id, description, spent_by, receipt_path, reverses_expense_id, created_by, approved_by",
      { count: "exact" },
    )
    .eq("status", "approved")
    .order("spent_on", { ascending: false })
    .order("created_at", { ascending: false });
  if (range) q = q.range(range[0], range[1]);
  const { data, count, error } = await q;
  if (error) console.error("expenses error code:", error.code ?? "unknown");
  const rows: ExpenseRow[] = ((data ?? []) as RawRequest[]).map((r) => ({
    id: String(r.id),
    title: String(r.title),
    amount: Number(r.amount),
    spentOn: String(r.spent_on),
    categoryId: (r.category_id as number | null) ?? null,
    investmentId: (r.investment_id as string | null) ?? null,
    description: (r.description as string | null) ?? null,
    spentBy: (r.spent_by as string | null) ?? null,
    hasReceipt: !!r.receipt_path,
    receiptIsPdf: typeof r.receipt_path === "string" && r.receipt_path.toLowerCase().endsWith(".pdf"),
    reversesExpenseId: (r.reverses_expense_id as string | null) ?? null,
    createdBy: (r.created_by as string | null) ?? null,
    approvedBy: (r.approved_by as string | null) ?? null,
  }));
  return { rows, count: count ?? 0 };
}

export async function loadCategories(supabase: SupabaseClient) {
  const { data } = await supabase.from("expense_categories").select("id, name").order("id");
  return ((data ?? []) as { id: number; name: string }[]).map((c) => ({ id: c.id, name: c.name }));
}

/** First names are not needed: id -> "full name" for the people shown as maker / checker (admins only). */
export async function loadPeople(supabase: SupabaseClient) {
  const { data } = await supabase.from("profiles").select("id, full_name, email, member_no");
  return new Map(
    ((data ?? []) as { id: string; full_name: string | null; email: string | null; member_no: number }[]).map((p) => [
      p.id,
      p.full_name || p.email || `No. ${p.member_no}`,
    ]),
  );
}
