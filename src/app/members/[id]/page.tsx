import type { Metadata } from "next";
import Link from "next/link";
import { Avatar } from "@/components/MemberBits";
import { Alert, Card, Chip, cn } from "@/components/ui";
import { isAdminRole, requireActiveMember } from "@/lib/auth";
import { loadLedger, loadMemberTotals, signAvatars } from "@/lib/dashboard";
import { DEPOSIT_COLUMNS, mapDeposit, type DepositKind, type RawDeposit } from "@/lib/deposits";
import { currentMonthDhaka, formatDate, formatMonth, formatTaka } from "@/lib/format";
import { getI18n } from "@/lib/i18n/server";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Member" };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** One line of the deposit history, whatever its source (table for owner/admin, RPC for others). */
type HistoryRow = {
  key: string;
  /** deposit id (owner/admin only) */
  id: string | null;
  /** id of the deposit this one corrects (owner/admin only) */
  correctsId: string | null;
  /** type of the original deposit, when known */
  originalKind: DepositKind | null;
  periodMonth: string;
  kind: DepositKind;
  amount: number;
  /** only known to the member themself and admins */
  approvedAt: string | null;
  transactionRef: string | null;
  /** amount of the original deposit when a correction points at it (owner/admin only) */
  originalAmount: number | null;
};

export default async function MemberDetailPage({ params }: PageProps<"/members/[id]">) {
  const [{ t, lang }, me] = await Promise.all([getI18n(), requireActiveMember()]);
  const { id: rawId } = await params;
  const id = rawId.toLowerCase();
  const supabase = await createClient();

  const back = (
    <Link href="/members" className="text-sm font-semibold text-accent hover:underline">
      ← {t.directory.back}
    </Link>
  );
  const notFound = (
    <div className="mx-auto w-full max-w-3xl px-4 py-10">
      {back}
      <Card className="mt-4">
        <h1 className="text-xl font-bold">{t.directory.notFoundTitle}</h1>
        <p className="mt-1 text-sm text-muted">{t.directory.notFoundBody}</p>
      </Card>
    </div>
  );
  if (!UUID_RE.test(id)) return notFound;

  // Only members the viewer may see come back (the RPC hides others when the setting is off).
  const totals = await loadMemberTotals(supabase);
  if (totals === null) {
    return (
      <div className="mx-auto w-full max-w-3xl px-4 py-10">
        {back}
        <div className="mt-4">
          <Alert>{t.directory.loadError}</Alert>
        </div>
      </div>
    );
  }
  const member = totals.find((m) => m.id === id);
  if (!member) return notFound;

  const isSelf = id === me.id.toLowerCase();
  const isAdmin = isAdminRole(me.role);
  const privileged = isSelf || isAdmin;

  // Deposit history. Owner and admins read the deposits table (RLS lets them), which has dates,
  // transaction IDs and the correction links. Everyone else only gets what deposit_ledger() exposes.
  let rows: HistoryRow[] = [];
  let historyFailed = false;
  if (privileged) {
    const { data, error } = await supabase
      .from("deposits")
      .select(DEPOSIT_COLUMNS)
      .eq("member_id", id)
      .eq("status", "approved")
      .order("period_month", { ascending: false })
      .order("reviewed_at", { ascending: false })
      .limit(500);
    if (error) {
      console.error("deposits history error code:", error.code ?? "unknown");
      historyFailed = true;
    }
    const deposits = ((data ?? []) as RawDeposit[]).map(mapDeposit);
    const byId = new Map(deposits.map((d) => [d.id, d]));
    rows = deposits.map((d) => ({
      key: d.id,
      id: d.id,
      correctsId: d.correctsDepositId,
      originalKind: d.correctsDepositId ? (byId.get(d.correctsDepositId)?.kind ?? null) : null,
      periodMonth: d.periodMonth,
      kind: d.kind,
      amount: d.amount,
      approvedAt: d.reviewedAt,
      transactionRef: d.transactionRef,
      originalAmount: d.correctsDepositId ? (byId.get(d.correctsDepositId)?.amount ?? null) : null,
    }));
  } else {
    const ledger = await loadLedger(supabase);
    if (ledger === null) historyFailed = true;
    rows = (ledger ?? [])
      .filter((r) => r.memberId === id)
      .map((r, i) => ({
        key: `${r.periodMonth}-${r.kind}-${i}`,
        id: null,
        correctsId: null,
        originalKind: null,
        periodMonth: r.periodMonth,
        kind: r.kind,
        amount: r.amount,
        approvedAt: null,
        transactionRef: null,
        originalAmount: null,
      }));
  }

  // Newest month first; inside a month, deposits first, then their corrections right below.
  // (A correction always has the same member, month and type as the deposit it corrects.)
  rows.sort(
    (a, b) =>
      b.periodMonth.localeCompare(a.periodMonth) ||
      a.kind.localeCompare(b.kind) ||
      Number(a.amount < 0) - Number(b.amount < 0),
  );

  // Owner/admin know exactly which deposit a correction points at: put it directly under that deposit.
  if (privileged) {
    const ids = new Set(rows.map((r) => r.id));
    const linked = new Map<string, HistoryRow[]>();
    for (const r of rows) {
      if (r.correctsId && ids.has(r.correctsId)) linked.set(r.correctsId, [...(linked.get(r.correctsId) ?? []), r]);
    }
    rows = rows
      .filter((r) => !(r.correctsId && ids.has(r.correctsId)))
      .flatMap((r) => [r, ...(r.id ? (linked.get(r.id) ?? []) : [])]);
  }

  const avatars = await signAvatars(supabase, [member]);
  const thisMonth = formatMonth(currentMonthDhaka(), lang);

  return (
    <div className="mx-auto w-full max-w-4xl px-4 py-8 sm:py-10">
      {back}

      <Card className="mt-4 space-y-5">
        <div className="flex flex-wrap items-center gap-4">
          <Avatar url={avatars.get(id)} name={member.name} size={84} zoom />
          <div className="min-w-0 flex-1">
            <h1 className="truncate text-2xl font-bold tracking-tight sm:text-3xl">{member.name || "—"}</h1>
            <div className="mt-1.5 flex flex-wrap items-center gap-1.5">
              <Chip tone="accent">
                {t.directory.memberNo} {member.memberNo}
              </Chip>
              {member.status === "suspended" && <Chip tone="danger">{t.directory.suspended}</Chip>}
              <Chip tone={member.paidThisMonth ? "accent" : "gold"}>
                {thisMonth}: {member.paidThisMonth ? t.directory.paid : t.directory.pending}
              </Chip>
            </div>
          </div>
        </div>

        <dl className="grid grid-cols-2 gap-4">
          <div className="rounded-2xl border border-border bg-surface-strong/60 p-4">
            <dt className="text-sm text-muted">{t.directory.capital}</dt>
            <dd className="mt-1 truncate text-2xl font-bold">{formatTaka(member.capital)}</dd>
          </div>
          <div className="rounded-2xl border border-border bg-surface-strong/60 p-4">
            <dt className="text-sm text-muted">{t.directory.shares}</dt>
            <dd className="mt-1 text-2xl font-bold">{member.shares}</dd>
          </div>
        </dl>

        {(isSelf || isAdmin) && (
          <div className="flex flex-wrap gap-4 text-sm font-semibold">
            {isSelf && (
              <Link href="/profile" className="text-accent hover:underline">
                {t.directory.myProfile} →
              </Link>
            )}
            {isAdmin && (
              <Link href={`/admin/members/${id}`} className="text-accent hover:underline">
                {t.directory.adminView} →
              </Link>
            )}
          </div>
        )}
      </Card>

      <Card className="mt-6 p-4 sm:p-6">
        <h2 className="px-2 text-lg font-bold">{t.directory.historyTitle}</h2>
        <p className="mt-1 px-2 text-xs text-muted">{t.directory.privacyNote}</p>

        {historyFailed ? (
          <div className="mt-3">
            <Alert>{t.directory.loadError}</Alert>
          </div>
        ) : rows.length === 0 ? (
          <p className="p-4 text-sm text-muted">{t.directory.historyEmpty}</p>
        ) : (
          <ul className="mt-3 divide-y divide-border">
            {rows.map((r) => {
              const isCorrection = r.amount < 0;
              return (
                <li key={r.key} className={cn("px-2 py-3", isCorrection && "ml-4 border-l-2 border-gold/60 pl-3 sm:ml-8")}>
                  <div className="flex flex-wrap items-start justify-between gap-2">
                    <div className="min-w-0">
                      <p className="font-semibold">
                        {isCorrection && (
                          <span aria-hidden className="mr-1 text-muted">
                            ↳
                          </span>
                        )}
                        {formatMonth(r.periodMonth, lang)}
                      </p>
                      <p className="text-xs text-muted">
                        {isCorrection
                          ? `${t.directory.correctionOf} ${t.deposits[`kind_${r.originalKind ?? r.kind}`]}${
                              r.originalAmount !== null ? ` (${formatTaka(r.originalAmount)})` : ""
                            }`
                          : t.deposits[`kind_${r.kind}`]}
                      </p>
                    </div>
                    <div className="text-right">
                      <p className={cn("text-lg font-bold", isCorrection && "text-danger")}>{formatTaka(r.amount)}</p>
                      {isCorrection && <Chip tone="gold">{t.directory.correction}</Chip>}
                    </div>
                  </div>
                  {(r.approvedAt || r.transactionRef) && (
                    <p className="mt-1 flex flex-wrap gap-x-4 gap-y-0.5 text-xs text-muted">
                      {r.approvedAt && (
                        <span>
                          {t.directory.approvedOn}: {formatDate(r.approvedAt, lang)}
                        </span>
                      )}
                      {r.transactionRef && (
                        <span>
                          {t.directory.transaction}: <span className="font-mono text-fg">{r.transactionRef}</span>
                        </span>
                      )}
                    </p>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </Card>
    </div>
  );
}
