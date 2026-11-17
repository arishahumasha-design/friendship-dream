"use server";

import { revalidatePath } from "next/cache";
import { getCurrentProfile, isAdminRole } from "@/lib/auth";
import {
  ADMIN_KINDS,
  METHODS,
  depositErrorKey,
  type DepositErrorKey,
  type DepositKind,
  type PayMethod,
} from "@/lib/deposits";
import { parseAmount } from "@/lib/format";
import { createClient } from "@/lib/supabase/server";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MONTH_RE = /^\d{4}-(0[1-9]|1[0-2])-01$/;
const MAX_AMOUNT = 10_000_000;

export type ReviewResult =
  | { ok: true; message: "approved" | "rejected" }
  | { ok: false; error: DepositErrorKey };

/**
 * Admin approves or rejects a PENDING deposit. Only the status (and the reject reason) is sent.
 * Nobody can approve their own deposit, and a normal admin cannot approve one they entered:
 * the database trigger enforces this; we check first to give a clear message.
 * Arguments come from the browser, so their types are checked before use.
 */
export async function reviewDeposit(
  depositId: unknown,
  action: unknown,
  options?: unknown,
): Promise<ReviewResult> {
  const me = await getCurrentProfile();
  if (!me || me.status !== "active" || !isAdminRole(me.role)) return { ok: false, error: "errNotAllowed" };
  if (typeof depositId !== "string" || !UUID_RE.test(depositId)) return { ok: false, error: "errNotFound" };
  if (action !== "approve" && action !== "reject") return { ok: false, error: "errGeneric" };
  const rawReason =
    options !== null && typeof options === "object" ? (options as { reason?: unknown }).reason : undefined;
  if (rawReason !== undefined && typeof rawReason !== "string") return { ok: false, error: "errGeneric" };

  const supabase = await createClient();
  const { data: dep } = await supabase
    .from("deposits")
    .select("member_id, entered_by, status")
    .eq("id", depositId)
    .maybeSingle();
  if (!dep) return { ok: false, error: "errNotFound" };
  if (dep.status !== "pending") return { ok: false, error: "errAlreadyReviewed" };

  if (action === "approve") {
    if (dep.member_id === me.id) return { ok: false, error: "errOwnDeposit" };
    if (dep.entered_by === me.id && me.role !== "super_admin") return { ok: false, error: "errOwnDeposit" };
  }

  let patch: Record<string, unknown>;
  if (action === "approve") {
    patch = { status: "approved" };
  } else {
    const reason = (rawReason ?? "").trim().slice(0, 500);
    if (!reason) return { ok: false, error: "errReasonRequired" };
    patch = { status: "rejected", reject_reason: reason };
  }

  const { data: saved, error } = await supabase
    .from("deposits")
    .update(patch)
    .eq("id", depositId)
    .eq("status", "pending")
    .select("status")
    .maybeSingle();
  if (error) return { ok: false, error: depositErrorKey(error) };
  if (!saved) return { ok: false, error: "errAlreadyReviewed" };

  revalidatePath("/admin/deposits");
  revalidatePath("/deposits");
  return { ok: true, message: action === "approve" ? "approved" : "rejected" };
}

export type ManualDepositInput = {
  /** one random id per form load: saving the same id twice is refused (double click) */
  requestId: string;
  memberId: string;
  periodMonth: string;
  kind: string;
  amount: string;
  method: string;
  transactionRef: string;
  note: string;
  isHistorical: boolean;
  correctsDepositId: string;
};

export type ManualResult =
  | { ok: true }
  | {
      ok: false;
      error:
        | DepositErrorKey
        | "errMember"
        | "errMonth"
        | "errAmount"
        | "errNote"
        | "errCorrection"
        | "errCorrectionPositive"
        | "errNegativeNoCorrection"
        | "errCorrectionMember";
    };

const isStr = (v: unknown): v is string => typeof v === "string";

/**
 * Super admin only: saves a deposit directly as approved (old records, late fees, corrections).
 * The argument comes from the browser, so every field's type is checked before use.
 */
export async function createManualDeposit(raw: unknown): Promise<ManualResult> {
  const me = await getCurrentProfile();
  if (!me || me.status !== "active" || me.role !== "super_admin") return { ok: false, error: "errSuperOnly" };

  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return { ok: false, error: "errGeneric" };
  const i = raw as Record<string, unknown>;
  if (
    !isStr(i.requestId) ||
    !isStr(i.memberId) ||
    !isStr(i.periodMonth) ||
    !isStr(i.kind) ||
    !isStr(i.amount) ||
    !isStr(i.method) ||
    !isStr(i.transactionRef) ||
    !isStr(i.note) ||
    !isStr(i.correctsDepositId) ||
    typeof i.isHistorical !== "boolean"
  ) {
    return { ok: false, error: "errGeneric" };
  }
  const input: ManualDepositInput = {
    requestId: i.requestId,
    memberId: i.memberId,
    periodMonth: i.periodMonth,
    kind: i.kind,
    amount: i.amount,
    method: i.method,
    transactionRef: i.transactionRef,
    note: i.note,
    isHistorical: i.isHistorical === true,
    correctsDepositId: i.correctsDepositId,
  };

  if (!UUID_RE.test(input.requestId)) return { ok: false, error: "errGeneric" };
  if (!UUID_RE.test(input.memberId)) return { ok: false, error: "errMember" };
  if (input.memberId === me.id) return { ok: false, error: "errSelfEntry" };
  if (!MONTH_RE.test(input.periodMonth)) return { ok: false, error: "errMonth" };
  const kind = input.kind as DepositKind;
  const method = input.method as PayMethod;
  if (!ADMIN_KINDS.includes(kind) || !METHODS.includes(method)) return { ok: false, error: "errGeneric" };

  const amount = parseAmount(input.amount, { allowNegative: true });
  if (amount === null || amount === 0 || Math.abs(amount) > MAX_AMOUNT) return { ok: false, error: "errAmount" };
  const note = input.note.trim().slice(0, 1000);
  if (!note) return { ok: false, error: "errNote" };
  const txn = input.transactionRef.trim().slice(0, 100);

  const supabase = await createClient();
  let corrects: string | null = null;
  // A correction always takes the type and month of the deposit it corrects (so totals stay right).
  let finalKind: DepositKind = kind;
  let finalMonth = input.periodMonth;
  if (amount < 0) {
    if (!UUID_RE.test(input.correctsDepositId)) return { ok: false, error: "errCorrection" };
    const { data: target } = await supabase
      .from("deposits")
      .select("member_id, status, amount, kind, period_month")
      .eq("id", input.correctsDepositId)
      .maybeSingle();
    if (!target || target.member_id !== input.memberId || target.status !== "approved" || Number(target.amount) <= 0) {
      return { ok: false, error: "errCorrectionMember" };
    }
    corrects = input.correctsDepositId;
    finalKind = target.kind as DepositKind;
    finalMonth = target.period_month as string;
  } else if (input.correctsDepositId) {
    return { ok: false, error: "errCorrectionPositive" };
  }

  const { error } = await supabase.from("deposits").insert({
    request_id: input.requestId,
    member_id: input.memberId,
    period_month: finalMonth,
    kind: finalKind,
    amount,
    method,
    transaction_ref: txn || null,
    note,
    status: "approved",
    is_historical: input.isHistorical,
    corrects_deposit_id: corrects,
  });
  // Same request id already saved (double click / retry): the entry exists, so this is a success.
  if (error && (error.code === "23505" || /duplicate key/.test(error.message)) && error.message.includes("deposits_request_id_unique")) {
    revalidatePath("/admin/deposits");
    return { ok: true };
  }
  if (error) return { ok: false, error: depositErrorKey(error) };

  revalidatePath("/admin/deposits");
  return { ok: true };
}

export type CorrectableDeposit = { id: string; periodMonth: string; kind: DepositKind; amount: number; method: PayMethod };

/** Approved, positive deposits of one member that a correction can point at (super admin only). */
export async function listCorrectable(memberId: string): Promise<CorrectableDeposit[]> {
  const me = await getCurrentProfile();
  if (!me || me.status !== "active" || me.role !== "super_admin" || !UUID_RE.test(memberId)) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from("deposits")
    .select("id, period_month, kind, amount, method")
    .eq("member_id", memberId)
    .eq("status", "approved")
    .gt("amount", 0)
    .order("period_month", { ascending: false })
    .limit(100);
  return (data ?? []).map((d) => ({
    id: d.id,
    periodMonth: d.period_month,
    kind: d.kind,
    amount: Number(d.amount),
    method: d.method,
  }));
}
