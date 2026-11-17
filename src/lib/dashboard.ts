import type { SupabaseClient } from "@supabase/supabase-js";
import type { MemberStatus } from "./auth";
import type { DepositKind } from "./deposits";

/** How long member photo links stay valid. Longer than documents because lists load many at once. */
export const AVATAR_URL_SECONDS = 300;

export type FundSummary = {
  capital: number;
  lateFees: number;
  investmentIncome: number;
  realizedProfit: number;
  expenses: number;
  totalFund: number;
  invested: number;
  cashAvailable: number;
  memberCount: number;
  monthlyAmount: number;
  /** The samiti reserve, as fund_summary() returns it (already inside totalFund). */
  reserve: number;
  reserveLateFees: number;
  reserveRounding: number;
  reserveOther: number;
};

/** One row of member_totals(). `photoPath` stays on the server: pages only pass signed URLs on. */
export type MemberTotal = {
  id: string;
  memberNo: number;
  name: string;
  photoPath: string | null;
  status: MemberStatus;
  capital: number;
  shares: number;
  paidThisMonth: boolean;
};

export type LedgerRow = {
  memberId: string;
  periodMonth: string;
  kind: DepositKind;
  amount: number;
};

/** The three summary RPCs run with the viewer's own session; the database decides what is visible. */
export async function loadFundSummary(supabase: SupabaseClient): Promise<FundSummary | null> {
  const { data, error } = await supabase.rpc("fund_summary");
  if (error) {
    console.error("fund_summary error code:", error.code ?? "unknown");
    return null;
  }
  const r = Array.isArray(data) ? data[0] : data;
  if (!r) return null;
  return {
    capital: Number(r.capital),
    lateFees: Number(r.late_fees),
    investmentIncome: Number(r.investment_income),
    realizedProfit: Number(r.realized_profit),
    expenses: Number(r.expenses),
    totalFund: Number(r.total_fund),
    invested: Number(r.invested),
    cashAvailable: Number(r.cash_available),
    memberCount: Number(r.member_count),
    monthlyAmount: Number(r.monthly_amount),
    reserve: Number(r.reserve ?? 0),
    reserveLateFees: Number(r.reserve_late_fees ?? 0),
    reserveRounding: Number(r.reserve_rounding ?? 0),
    reserveOther: Number(r.reserve_other ?? 0),
  };
}

export async function loadMemberTotals(supabase: SupabaseClient): Promise<MemberTotal[] | null> {
  const { data, error } = await supabase.rpc("member_totals");
  if (error) {
    console.error("member_totals error code:", error.code ?? "unknown");
    return null;
  }
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    id: String(r.member_id),
    memberNo: Number(r.member_no),
    name: String(r.full_name ?? ""),
    photoPath: (r.photo_path as string | null) ?? null,
    status: r.status as MemberStatus,
    capital: Number(r.capital),
    shares: Number(r.shares),
    paidThisMonth: r.paid_this_month === true,
  }));
}

export async function loadLedger(supabase: SupabaseClient): Promise<LedgerRow[] | null> {
  const { data, error } = await supabase.rpc("deposit_ledger");
  if (error) {
    console.error("deposit_ledger error code:", error.code ?? "unknown");
    return null;
  }
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    memberId: String(r.member_id),
    periodMonth: String(r.period_month),
    kind: r.kind as DepositKind,
    amount: Number(r.amount),
  }));
}

/** Short-lived signed links for member photos (private bucket; never a public URL). */
export async function signAvatars(
  supabase: SupabaseClient,
  members: Pick<MemberTotal, "id" | "photoPath">[],
): Promise<Map<string, string>> {
  const withPhoto = members.filter((m) => m.photoPath);
  const urls = new Map<string, string>();
  if (!withPhoto.length) return urls;
  const { data } = await supabase.storage.from("avatars").createSignedUrls(
    withPhoto.map((m) => m.photoPath!),
    AVATAR_URL_SECONDS,
  );
  (data ?? []).forEach((u, i) => u.signedUrl && urls.set(withPhoto[i].id, u.signedUrl));
  return urls;
}
