import type { SupabaseClient } from "@supabase/supabase-js";
import { SIGNED_URL_SECONDS } from "./members";

export const MEMBER_KINDS = ["monthly", "yearly", "other"] as const;
export const ADMIN_KINDS = ["monthly", "yearly", "late_fee", "other"] as const;
export const METHODS = ["bank", "bkash", "nagad", "rocket", "cash", "other"] as const;

export type DepositKind = (typeof ADMIN_KINDS)[number];
export type PayMethod = (typeof METHODS)[number];
export type ReviewStatus = "pending" | "approved" | "rejected";

/** A deposit as the UI sees it. The receipt storage path never leaves the server. */
export type DepositRow = {
  id: string;
  memberId: string;
  periodMonth: string;
  kind: DepositKind;
  amount: number;
  method: PayMethod;
  transactionRef: string | null;
  hasReceipt: boolean;
  receiptIsPdf: boolean;
  note: string | null;
  status: ReviewStatus;
  submittedAt: string;
  reviewedBy: string | null;
  reviewedAt: string | null;
  rejectReason: string | null;
  isHistorical: boolean;
  enteredBy: string | null;
  correctsDepositId: string | null;
};

export const DEPOSIT_COLUMNS =
  "id, member_id, period_month, kind, amount, method, transaction_ref, receipt_path, note, status, submitted_at, reviewed_by, reviewed_at, reject_reason, is_historical, entered_by, corrects_deposit_id";

export type RawDeposit = {
  id: string;
  member_id: string;
  period_month: string;
  kind: DepositKind;
  amount: number | string;
  method: PayMethod;
  transaction_ref: string | null;
  receipt_path: string | null;
  note: string | null;
  status: ReviewStatus;
  submitted_at: string;
  reviewed_by: string | null;
  reviewed_at: string | null;
  reject_reason: string | null;
  is_historical: boolean;
  entered_by: string | null;
  corrects_deposit_id: string | null;
};

export function mapDeposit(r: RawDeposit): DepositRow {
  return {
    id: r.id,
    memberId: r.member_id,
    periodMonth: r.period_month,
    kind: r.kind,
    amount: Number(r.amount),
    method: r.method,
    transactionRef: r.transaction_ref,
    hasReceipt: !!r.receipt_path,
    receiptIsPdf: !!r.receipt_path && r.receipt_path.toLowerCase().endsWith(".pdf"),
    note: r.note,
    status: r.status,
    submittedAt: r.submitted_at,
    reviewedBy: r.reviewed_by,
    reviewedAt: r.reviewed_at,
    rejectReason: r.reject_reason,
    isHistorical: r.is_historical,
    enteredBy: r.entered_by,
    correctsDepositId: r.corrects_deposit_id,
  };
}

/** Maps raw rows and attaches 60-second receipt links (made with the caller's own session). */
export async function mapDepositsWithReceipts(
  supabase: SupabaseClient,
  rows: RawDeposit[],
): Promise<{ deposit: DepositRow; receiptUrl: string | null }[]> {
  const withReceipt = rows.filter((r) => r.receipt_path);
  const urls = new Map<string, string>();
  if (withReceipt.length) {
    const { data } = await supabase.storage.from("receipts").createSignedUrls(
      withReceipt.map((r) => r.receipt_path!),
      SIGNED_URL_SECONDS,
    );
    (data ?? []).forEach((u, i) => u.signedUrl && urls.set(withReceipt[i].id, u.signedUrl));
  }
  return rows.map((r) => ({ deposit: mapDeposit(r), receiptUrl: urls.get(r.id) ?? null }));
}

export type DepositErrorKey =
  | "errDuplicateTxn"
  | "errDuplicateReceipt"
  | "errDuplicate"
  | "errNotAllowed"
  | "errAmountRange"
  | "errOwnDeposit"
  | "errAlreadyReviewed"
  | "errSuperOnly"
  | "errNoteRequired"
  | "errReasonRequired"
  | "errCorrectionRef"
  | "errCorrectionInvalid"
  | "errCorrectionExceeds"
  | "errSelfEntry"
  | "errAlreadySaved"
  | "errTxnRequired"
  | "errNotFound"
  | "errSettingsInvalid"
  | "errGeneric";

/** Turns a database error into a plain-language message key (raw SQL text is never shown). */
export function depositErrorKey(
  err: { code?: string; message?: string } | null | undefined,
): DepositErrorKey {
  const m = err?.message ?? "";
  const c = err?.code ?? "";
  if (c === "23505" || m.includes("duplicate key")) {
    if (m.includes("deposits_request_id_unique")) return "errAlreadySaved";
    if (m.includes("deposits_receipt_unique")) return "errDuplicateReceipt";
    if (m.includes("deposits_txn_unique")) return "errDuplicateTxn";
    return "errDuplicate";
  }
  if (m.includes("cannot approve your own")) return "errOwnDeposit";
  if (m.includes("reviewed deposit cannot be changed")) return "errAlreadyReviewed";
  if (m.includes("Only the super admin can enter")) return "errSuperOnly";
  if (m.includes("note is required")) return "errNoteRequired";
  if (m.includes("A correction must be")) return "errCorrectionInvalid";
  if (m.includes("Corrections cannot exceed the original deposit amount")) return "errCorrectionExceeds";
  if (m.includes("You cannot enter an approved or rejected deposit for yourself")) return "errSelfEntry";
  if (m.includes("Only admins can review")) return "errNotAllowed";
  if (c === "23514" || m.includes("check constraint")) {
    if (m.includes("deposits_reject_needs_reason")) return "errReasonRequired";
    if (m.includes("deposits_negative_needs_ref")) return "errCorrectionRef";
    if (m.includes("deposits_txn_ref_not_blank")) return "errTxnRequired";
    if (m.includes("deposits_sane_values")) return "errAmountRange";
    if (m.includes("app_settings_valid")) return "errSettingsInvalid";
  }
  if (c === "42501" || /row-level security|permission denied/i.test(m)) return "errNotAllowed";
  // Only the error CODE is logged, never row data (no transaction IDs, paths or names).
  console.error("database error code:", c || "unknown");
  return "errGeneric";
}

/** A random UUID (v4) that also works in browsers without crypto.randomUUID. */
export function newRequestId(): string {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
