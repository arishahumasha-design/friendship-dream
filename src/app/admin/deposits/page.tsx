import type { Metadata } from "next";
import Link from "next/link";
import { FileThumb } from "@/components/FileThumb";
import { ManualDepositForm, type MemberOption } from "@/components/ManualDepositForm";
import { Avatar, depositTone } from "@/components/MemberBits";
import { Pager } from "@/components/Pager";
import { ReviewActions } from "@/components/ReviewActions";
import { Alert, Button, Card, Chip, cn } from "@/components/ui";
import { signReceipt } from "@/app/actions/files";
import { requireAdmin } from "@/lib/auth";
import {
  DEPOSIT_COLUMNS,
  mapDepositsWithReceipts,
  type DepositRow,
  type RawDeposit,
} from "@/lib/deposits";
import { formatDateTime, formatMonth, formatTaka } from "@/lib/format";
import { getI18n } from "@/lib/i18n/server";
import { SIGNED_URL_SECONDS } from "@/lib/members";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Deposits" };

const TABS = ["pending", "approved", "rejected", "all"] as const;
type Tab = (typeof TABS)[number];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MONTH_RE = /^\d{4}-\d{2}-01$/;

const PAGE_SIZE = 100;

type Person = { id: string; full_name: string | null; email: string | null; member_no: number; photo_path: string | null; status: string };

export default async function AdminDepositsPage({ searchParams }: PageProps<"/admin/deposits">) {
  const [{ t, lang }, me] = await Promise.all([getI18n(), requireAdmin()]);
  const sp = await searchParams;
  const supabase = await createClient();
  const isSuper = me.role === "super_admin";

  const one = (v: string | string[] | undefined) => (typeof v === "string" ? v : "");
  const tab: Tab = (TABS as readonly string[]).includes(one(sp.tab)) ? (one(sp.tab) as Tab) : "pending";
  const monthFilter = MONTH_RE.test(one(sp.month)) ? one(sp.month) : "";
  const memberFilter = UUID_RE.test(one(sp.member)) ? one(sp.member) : "";
  const flash = one(sp.flash);

  // Newest month first, then kind, then submission time; the waiting queue stays oldest-first.
  // Paged (PAGE_SIZE per page) so no row is ever hidden behind a limit.
  const page = Math.max(1, Math.floor(Number(one(sp.page) || 1)) || 1);
  let query = supabase.from("deposits").select(DEPOSIT_COLUMNS, { count: "exact" });
  if (tab !== "all") query = query.eq("status", tab);
  if (monthFilter) query = query.eq("period_month", monthFilter);
  if (memberFilter) query = query.eq("member_id", memberFilter);
  const ordered =
    tab === "pending"
      ? query.order("submitted_at", { ascending: true })
      : query.order("period_month", { ascending: false }).order("kind").order("submitted_at", { ascending: false });
  const pageQuery = ordered.range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

  const count = (status: string) =>
    supabase.from("deposits").select("id", { count: "exact", head: true }).eq("status", status);

  const [{ data: raw, count: listCount }, { data: people }, { data: monthRows }, pendingC, approvedC, rejectedC] = await Promise.all([
    pageQuery,
    supabase.from("profiles").select("id, full_name, email, member_no, photo_path, status").order("member_no"),
    supabase.from("deposits").select("period_month").order("period_month", { ascending: false }).limit(5000),
    count("pending"),
    count("approved"),
    count("rejected"),
  ]);
  const counts: Record<Tab, number> = {
    pending: pendingC.count ?? 0,
    approved: approvedC.count ?? 0,
    rejected: rejectedC.count ?? 0,
    all: (pendingC.count ?? 0) + (approvedC.count ?? 0) + (rejectedC.count ?? 0),
  };

  const rows = await mapDepositsWithReceipts(supabase, (raw ?? []) as RawDeposit[]);
  const profiles = (people ?? []) as Person[];
  const byId = new Map(profiles.map((p) => [p.id, p]));
  const nameOf = (id: string | null) => {
    if (!id) return t.adminDeposits.unknownPerson;
    const p = byId.get(id);
    return p ? p.full_name || p.email || "—" : t.adminDeposits.unknownPerson;
  };
  const months = [...new Set((monthRows ?? []).map((r) => r.period_month as string))];
  if (monthFilter && !months.includes(monthFilter)) months.unshift(monthFilter);

  // Member photos (60-second links).
  const shown = [...new Set(rows.map((r) => r.deposit.memberId))]
    .map((id) => byId.get(id))
    .filter((p): p is Person => !!p?.photo_path);
  const photoUrl = new Map<string, string>();
  if (shown.length) {
    const { data } = await supabase.storage.from("avatars").createSignedUrls(
      shown.map((p) => p.photo_path!),
      SIGNED_URL_SECONDS,
    );
    (data ?? []).forEach((u, i) => u.signedUrl && photoUrl.set(shown[i].id, u.signedUrl));
  }

  // Warning: this member already has an approved deposit of the same type for the same month.
  const pendingRows = rows.filter((r) => r.deposit.status === "pending").map((r) => r.deposit);
  const existing = new Set<string>();
  if (pendingRows.length) {
    const { data } = await supabase
      .from("deposits")
      .select("member_id, period_month, kind")
      .eq("status", "approved")
      .in("member_id", [...new Set(pendingRows.map((d) => d.memberId))])
      .in("period_month", [...new Set(pendingRows.map((d) => d.periodMonth))]);
    for (const e of data ?? []) existing.add(`${e.member_id}|${e.period_month}|${e.kind}`);
  }

  // You can never enter an approved deposit for yourself, so you are not in the list.
  const memberOptions: MemberOption[] = profiles
    .filter((p) => (p.status === "active" || p.status === "suspended") && p.id !== me.id)
    .map((p) => ({ id: p.id, name: p.full_name || p.email || "—", memberNo: p.member_no }));

  const tabLabel: Record<Tab, string> = {
    pending: t.adminDeposits.tabPending,
    approved: t.adminDeposits.tabApproved,
    rejected: t.adminDeposits.tabRejected,
    all: t.adminDeposits.tabAll,
  };
  const keep = (extra: Record<string, string>) => {
    const p = new URLSearchParams();
    if (monthFilter) p.set("month", monthFilter);
    if (memberFilter) p.set("member", memberFilter);
    for (const [k, v] of Object.entries(extra)) p.set(k, v);
    return `/admin/deposits?${p.toString()}`;
  };

  // Nobody approves their own deposit; a normal admin also cannot approve one they entered.
  // The super admin may approve a row they entered for someone else, after a confirmation.
  const reviewMode = (d: DepositRow): "normal" | "blocked" | "own" => {
    if (d.memberId === me.id) return "blocked";
    if (d.enteredBy === me.id) return isSuper ? "own" : "blocked";
    return "normal";
  };

  return (
    <div className="mx-auto w-full max-w-5xl px-4 py-8 sm:py-10">
      <Link href="/admin" className="text-sm font-semibold text-accent hover:underline">
        ← {t.admin.title}
      </Link>
      <h1 className="mt-2 text-3xl font-bold tracking-tight">{t.adminDeposits.title}</h1>
      <p className="mt-1.5 text-sm text-muted">{t.adminDeposits.subtitle}</p>

      <div className="mt-6 space-y-4">
        {flash === "approved" && <Alert tone="success">{t.adminDeposits.approvedMsg}</Alert>}
        {flash === "rejected" && <Alert tone="success">{t.adminDeposits.rejectedMsg}</Alert>}
        {flash === "manual" && <Alert tone="success">{t.adminDeposits.manualSaved}</Alert>}
        {flash === "duplicate" && <Alert>{t.adminDeposits.manualDuplicate}</Alert>}

        {isSuper && <ManualDepositForm members={memberOptions} />}

        <nav className="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1" aria-label={t.adminDeposits.title}>
          {TABS.map((k) => (
            <Link
              key={k}
              href={keep({ tab: k })}
              aria-current={tab === k ? "page" : undefined}
              className={cn(
                "inline-flex h-10 shrink-0 items-center gap-2 rounded-full border px-4 text-sm font-semibold transition",
                tab === k ? "border-accent bg-accent text-accent-fg" : "border-border bg-surface hover:bg-accent-soft",
              )}
            >
              {tabLabel[k]}
              <span
                className={cn(
                  "rounded-full px-1.5 text-xs",
                  tab === k ? "bg-black/15" : k === "pending" && counts.pending ? "bg-gold/30" : "bg-fg/8",
                )}
              >
                {counts[k]}
              </span>
            </Link>
          ))}
        </nav>

        <form method="get" action="/admin/deposits" className="flex flex-wrap items-end gap-3">
          <input type="hidden" name="tab" value={tab} />
          <label className="min-w-40 flex-1 space-y-1 text-sm font-medium">
            {t.adminDeposits.filterMonth}
            <select
              name="month"
              defaultValue={monthFilter}
              className="block h-11 w-full rounded-2xl border border-border bg-surface-strong px-3 text-base font-normal"
            >
              <option value="">{t.adminDeposits.allMonths}</option>
              {months.map((m) => (
                <option key={m} value={m}>
                  {formatMonth(m, lang)}
                </option>
              ))}
            </select>
          </label>
          <label className="min-w-40 flex-1 space-y-1 text-sm font-medium">
            {t.adminDeposits.filterMember}
            <select
              name="member"
              defaultValue={memberFilter}
              className="block h-11 w-full rounded-2xl border border-border bg-surface-strong px-3 text-base font-normal"
            >
              <option value="">{t.adminDeposits.allMembers}</option>
              {profiles
                .filter((p) => p.status !== "pending")
                .map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.member_no}. {p.full_name || p.email}
                  </option>
                ))}
            </select>
          </label>
          <Button type="submit" variant="secondary">
            {t.adminDeposits.filter}
          </Button>
          {(monthFilter || memberFilter) && (
            <Link href={`/admin/deposits?tab=${tab}`} className="pb-3 text-sm font-semibold text-accent hover:underline">
              {t.adminDeposits.clear}
            </Link>
          )}
        </form>

        {rows.length === 0 ? (
          <Card className="text-center text-sm text-muted">{t.adminDeposits.empty}</Card>
        ) : (
          <ul className="space-y-3">
            {rows.map(({ deposit: d, receiptUrl }) => {
              const person = byId.get(d.memberId);
              const name = person?.full_name || person?.email || "—";
              const warn = d.status === "pending" && existing.has(`${d.memberId}|${d.periodMonth}|${d.kind}`);
              const enteredByMember = d.enteredBy === d.memberId;
              return (
                <li key={d.id}>
                  <Card className="space-y-4 p-4 sm:p-5">
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div className="flex min-w-0 items-center gap-3">
                        <Avatar url={photoUrl.get(d.memberId)} name={name} size={44} />
                        <div className="min-w-0">
                          <p className="truncate font-semibold">{name}</p>
                          <p className="text-xs text-muted">
                            {formatMonth(d.periodMonth, lang)} · {t.deposits[`kind_${d.kind}`]} ·{" "}
                            {t.deposits[`method_${d.method}`]}
                          </p>
                        </div>
                      </div>
                      <div className="text-right">
                        <p className="text-xl font-bold">{formatTaka(d.amount)}</p>
                        <Chip tone={depositTone(d.status)}>{t.deposits[`status_${d.status}`]}</Chip>
                      </div>
                    </div>

                    <div className="grid gap-4 sm:grid-cols-[9rem_1fr]">
                      <div>
                        {d.hasReceipt ? (
                          <FileThumb
                            file={{ id: d.id, url: receiptUrl, isPdf: d.receiptIsPdf, uploadedAt: null }}
                            sign={signReceipt.bind(null, d.id)}
                            label={t.adminDeposits.receipt}
                          />
                        ) : (
                          <p className="grid aspect-[4/3] place-items-center rounded-2xl border border-dashed border-border px-2 text-center text-xs text-muted">
                            {t.adminDeposits.noReceipt}
                          </p>
                        )}
                      </div>

                      <dl className="grid content-start gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
                        {d.transactionRef && (
                          <Info label={t.deposits.transaction}>
                            <span className="font-mono">{d.transactionRef}</span>
                          </Info>
                        )}
                        <Info label={t.deposits.submittedOn}>{formatDateTime(d.submittedAt, lang)}</Info>
                        <Info label={t.adminDeposits.enteredBy}>
                          {enteredByMember ? t.adminDeposits.selfSubmitted : nameOf(d.enteredBy)}
                        </Info>
                        {d.status !== "pending" && (
                          <Info label={d.status === "approved" ? t.adminDeposits.approvedBy : t.adminDeposits.rejectedBy}>
                            {nameOf(d.reviewedBy)}
                            {d.reviewedAt ? ` · ${formatDateTime(d.reviewedAt, lang)}` : ""}
                          </Info>
                        )}
                        {d.note && (
                          <Info label={t.deposits.note} wide>
                            <span className="whitespace-pre-line">{d.note}</span>
                          </Info>
                        )}
                        {d.status === "rejected" && d.rejectReason && (
                          <Info label={t.adminDeposits.rejectedReason} wide>
                            <span className="whitespace-pre-line">{d.rejectReason}</span>
                          </Info>
                        )}
                      </dl>
                    </div>

                    <div className="flex flex-wrap gap-1.5">
                      {d.isHistorical && <Chip>{t.adminDeposits.historical}</Chip>}
                      {d.correctsDepositId && <Chip tone="gold">{t.adminDeposits.correctionOf}</Chip>}
                    </div>

                    {warn && (
                      <p className="rounded-2xl bg-gold/15 px-4 py-3 text-sm font-medium">
                        <span aria-hidden>⚠ </span>
                        {t.adminDeposits.existingWarning}
                      </p>
                    )}

                    {d.status === "pending" && <ReviewActions depositId={d.id} mode={reviewMode(d)} />}
                  </Card>
                </li>
              );
            })}
          </ul>
        )}
        <Pager
          page={page}
          totalPages={Math.max(1, Math.ceil((listCount ?? 0) / PAGE_SIZE))}
          hrefFor={(p) => keep({ tab, page: String(p) })}
        />
      </div>
    </div>
  );
}

function Info({ label, children, wide }: { label: string; children: React.ReactNode; wide?: boolean }) {
  return (
    <div className={cn("min-w-0", wide && "sm:col-span-2")}>
      <dt className="text-xs text-muted">{label}</dt>
      <dd className="mt-0.5 break-words font-medium">{children}</dd>
    </div>
  );
}
