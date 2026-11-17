import type { Metadata } from "next";
import Link from "next/link";
import { MemberRing } from "@/components/MemberRing";
import { Alert, Card } from "@/components/ui";
import { fromCents, sumCents } from "@/lib/money";
import { loadCategories } from "@/lib/moneyData";
import { isAdminRole, requireActiveMember } from "@/lib/auth";
import { loadFundSummary, loadLedger, loadMemberTotals, signAvatars } from "@/lib/dashboard";
import { currentMonthDhaka, daysUntil, formatDay, formatMonth, formatTaka, monthDeadlineDhaka } from "@/lib/format";
import { getI18n } from "@/lib/i18n/server";
import { loadSettings } from "@/lib/settings";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Home" };

/** Member home: the fund numbers, this month's collection and a ring of member photos. */
export default async function HomePage() {
  const [{ t, lang }, profile] = await Promise.all([getI18n(), requireActiveMember()]);
  const supabase = await createClient();
  const isAdmin = isAdminRole(profile.role);

  // Everything below comes from the RPCs / RLS with the member's own session.
  const monthStart = currentMonthDhaka();
  const [fund, totals, ledger, settings, categories, monthExpenses, investmentRows] = await Promise.all([
    loadFundSummary(supabase),
    loadMemberTotals(supabase),
    loadLedger(supabase),
    loadSettings(supabase),
    loadCategories(supabase),
    // this month's approved expenses (reversals are negative rows, so the sums are net)
    supabase.from("expenses").select("amount, category_id").eq("status", "approved").gte("spent_on", monthStart),
    supabase.from("investments").select("status"),
  ]);

  // Expenses by category: the stored amounts added up in whole cents (display only).
  const catName = new Map(categories.map((c) => [c.id, c.name]));
  const byCat = new Map<string, number[]>();
  for (const e of (monthExpenses.data ?? []) as { amount: number; category_id: number | null }[]) {
    const key = e.category_id === null ? "" : String(e.category_id);
    byCat.set(key, [...(byCat.get(key) ?? []), Number(e.amount)]);
  }
  const categoryRows = [...byCat]
    .map(([key, v]) => ({ name: key === "" ? t.money.uncategorized : (catName.get(Number(key)) ?? t.money.uncategorized), total: fromCents(sumCents(v)) }))
    .filter((r) => r.total !== 0)
    .sort((a, b) => b.total - a.total);
  const maxCategory = Math.max(1, ...categoryRows.map((r) => Math.abs(r.total)));
  const heldCount = ((investmentRows.data ?? []) as { status: string }[]).filter((i) => i.status === "held").length;
  const soldCount = ((investmentRows.data ?? []) as { status: string }[]).filter((i) => i.status === "sold").length;

  const active = (totals ?? []).filter((m) => m.status === "active");
  const avatars = await signAvatars(supabase, active);
  const ringMembers = active.map((m) => ({ id: m.id, name: m.name || "—", photoUrl: avatars.get(m.id) ?? null }));

  // If members may not see each other, a normal member only gets their own row from the RPCs,
  // so "how many paid" and "total collected" would be wrong: hide that card for them.
  const canSeeAll = isAdmin || settings.membersCanSeeOthers;
  const month = currentMonthDhaka();
  const paidCount = active.filter((m) => m.paidThisMonth).length;
  const collected = (ledger ?? [])
    .filter((r) => r.kind === "monthly" && r.periodMonth === month)
    .reduce((sum, r) => sum + r.amount, 0);
  const target = fund ? fund.monthlyAmount * fund.memberCount : 0;
  const percent = target > 0 ? Math.max(0, Math.min(100, Math.round((collected / target) * 100))) : 0;
  const deadline = monthDeadlineDhaka();
  const left = daysUntil(deadline);
  const leftText = left <= 0 ? t.home.lastDay : left === 1 ? t.home.oneDayLeft : `${left} ${t.home.daysLeft}`;

  const bigNumbers = fund
    ? [
        { label: t.home.totalFund, value: fund.totalFund, hint: null, tone: "text-fg" },
        { label: t.home.invested, value: fund.invested, hint: t.home.investedHint, tone: "text-fg" },
        { label: t.home.cashAvailable, value: fund.cashAvailable, hint: t.home.cashHint, tone: "text-accent" },
      ]
    : [];

  return (
    <div className="mx-auto w-full max-w-6xl space-y-6 px-4 py-8 sm:py-10">
      <div>
        <p className="text-sm font-medium text-accent">{t.home.greeting}</p>
        <h1 className="mt-1 text-3xl font-bold tracking-tight">{profile.fullName || profile.email}</h1>
      </div>

      {/* Fund numbers */}
      <Card className="space-y-5">
        <h2 className="text-lg font-bold">{t.home.fundTitle}</h2>
        {fund ? (
          <>
            <div className="grid gap-4 sm:grid-cols-3">
              {bigNumbers.map((n) => (
                <div key={n.label} className="min-w-0 rounded-2xl border border-border bg-surface-strong/60 p-4">
                  <p className="text-sm font-medium text-muted">{n.label}</p>
                  <p className={`mt-1 truncate text-2xl font-bold tracking-tight sm:text-3xl ${n.tone}`}>
                    {formatTaka(n.value)}
                  </p>
                  {n.hint && <p className="mt-1 text-xs text-muted">{n.hint}</p>}
                </div>
              ))}
            </div>
            <div className="space-y-1 text-xs text-muted">
              <p>{t.home.formulaFund}</p>
              <p>{t.home.formulaCash}</p>
            </div>

            {/* Breakdown exactly as fund_summary() returns it; the reserve is already inside the total */}
            <details className="rounded-2xl border border-border bg-surface-strong/40 px-4 py-3 text-sm">
              <summary className="cursor-pointer font-semibold">{t.money.fundBreakdown}</summary>
              <dl className="mt-3 grid gap-x-8 gap-y-1.5 sm:grid-cols-2">
                {[
                  [t.money.capitalLabel, fund.capital],
                  [t.money.lateFeesLabel, fund.lateFees],
                  [t.money.incomeLabel, fund.investmentIncome],
                  [t.money.profitLabel, fund.realizedProfit],
                  [t.money.expensesLabel, -fund.expenses],
                ].map(([label, value]) => (
                  <div key={String(label)} className="flex justify-between gap-3">
                    <dt className="text-muted">{label}</dt>
                    <dd className="font-medium">{formatTaka(Number(value))}</dd>
                  </div>
                ))}
              </dl>
              <div className="mt-4 rounded-2xl bg-fg/5 px-4 py-3">
                <p className="font-semibold">{t.money.reserveTitle}: {formatTaka(fund.reserve)}</p>
                <p className="mt-0.5 text-xs text-muted">{t.money.reserveNote}</p>
                <dl className="mt-2 grid gap-y-1 text-xs sm:grid-cols-3">
                  <div><dt className="text-muted">{t.money.reserveLate}</dt><dd className="font-medium">{formatTaka(fund.reserveLateFees)}</dd></div>
                  <div><dt className="text-muted">{t.money.reserveRounding}</dt><dd className="font-medium">{formatTaka(fund.reserveRounding)}</dd></div>
                  <div><dt className="text-muted">{t.money.reserveOther}</dt><dd className="font-medium">{formatTaka(fund.reserveOther)}</dd></div>
                </dl>
              </div>
            </details>
          </>
        ) : (
          <Alert>{t.home.loadError}</Alert>
        )}
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        {/* Rotating ring */}
        <Card className="flex flex-col items-center gap-4 overflow-hidden">
          <h2 className="self-start text-lg font-bold">{t.home.ringTitle}</h2>
          {totals ? (
            <MemberRing
              members={ringMembers}
              centerValue={String(fund?.memberCount ?? ringMembers.length)}
              centerLabel={t.home.ringMembers}
            />
          ) : (
            <Alert>{t.directory.loadError}</Alert>
          )}
          <Link href="/members" className="text-sm font-semibold text-accent hover:underline">
            {t.home.seeAllMembers} →
          </Link>
        </Card>

        {/* This month's collection */}
        <Card className="space-y-4">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <h2 className="text-lg font-bold">{t.home.collectionTitle}</h2>
            <p className="text-sm font-medium text-muted">{formatMonth(month, lang)}</p>
          </div>
          {canSeeAll && fund && totals && ledger ? (
            <>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <p className="text-sm text-muted">{t.home.paidCountLabel}</p>
                  <p className="mt-0.5 text-2xl font-bold">
                    {paidCount}
                    <span className="text-base font-medium text-muted"> / {active.length}</span>
                  </p>
                </div>
                <div>
                  <p className="text-sm text-muted">{t.home.collectedLabel}</p>
                  <p className="mt-0.5 truncate text-2xl font-bold">{formatTaka(collected)}</p>
                </div>
              </div>
              <div>
                <div
                  role="progressbar"
                  aria-valuemin={0}
                  aria-valuemax={100}
                  aria-valuenow={percent}
                  aria-label={t.home.collectionTitle}
                  className="h-3 overflow-hidden rounded-full bg-fg/10"
                >
                  <div className="h-full rounded-full bg-accent transition-[width]" style={{ width: `${percent}%` }} />
                </div>
                <div className="mt-2 flex flex-wrap items-center justify-between gap-2 text-xs text-muted">
                  <span>
                    {percent}% · {t.home.targetLabel} {formatTaka(target)}
                  </span>
                </div>
              </div>
              <p className="rounded-2xl bg-gold/15 px-4 py-3 text-sm">
                <span className="font-semibold">{t.home.deadlineLabel}:</span> {formatDay(deadline, lang)}{" "}
                <span className="text-muted">· {leftText}</span>
              </p>
            </>
          ) : (
            <p className="rounded-2xl bg-fg/5 px-4 py-3 text-sm text-muted">{t.home.collectionHidden}</p>
          )}
        </Card>
      </div>

      {/* Expenses by category and investments */}
      <div className="grid gap-6 lg:grid-cols-2">
        <Card className="space-y-3">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <h2 className="text-lg font-bold">{t.home.expensesTitle}</h2>
            <p className="text-sm font-medium text-muted">{formatMonth(monthStart, lang)}</p>
          </div>
          {categoryRows.length === 0 ? (
            <p className="rounded-2xl border border-dashed border-border px-4 py-8 text-center text-sm text-muted">
              {t.money.noExpensesThisMonth}
            </p>
          ) : (
            <ul className="space-y-3">
              {categoryRows.map((r) => (
                <li key={r.name}>
                  <div className="flex items-baseline justify-between gap-3 text-sm">
                    <span className="truncate font-medium">{r.name}</span>
                    <span className="font-bold">{formatTaka(r.total)}</span>
                  </div>
                  <div className="mt-1 h-2 overflow-hidden rounded-full bg-fg/10" aria-hidden>
                    <div className="h-full rounded-full bg-accent" style={{ width: `${Math.max(3, Math.round((Math.abs(r.total) / maxCategory) * 100))}%` }} />
                  </div>
                </li>
              ))}
            </ul>
          )}
        </Card>
        <Card className="space-y-3">
          <h2 className="text-lg font-bold">{t.home.investmentsTitle}</h2>
          {fund && heldCount + soldCount === 0 ? (
            <p className="rounded-2xl border border-dashed border-border px-4 py-8 text-center text-sm text-muted">
              {t.money.noInvestments}
            </p>
          ) : fund ? (
            <dl className="grid grid-cols-2 gap-3 text-sm">
              <div className="rounded-2xl border border-border bg-surface-strong/60 p-3">
                <dt className="text-xs text-muted">{t.money.heldInvestments}</dt>
                <dd className="mt-0.5 text-lg font-bold">{heldCount}</dd>
              </div>
              <div className="rounded-2xl border border-border bg-surface-strong/60 p-3">
                <dt className="text-xs text-muted">{t.money.heldCost}</dt>
                <dd className="mt-0.5 truncate text-lg font-bold">{formatTaka(fund.invested)}</dd>
              </div>
              <div className="rounded-2xl border border-border bg-surface-strong/60 p-3">
                <dt className="text-xs text-muted">{t.money.soldInvestments}</dt>
                <dd className="mt-0.5 text-lg font-bold">{soldCount}</dd>
              </div>
              <div className="rounded-2xl border border-border bg-surface-strong/60 p-3">
                <dt className="text-xs text-muted">{t.money.realizedProfit}</dt>
                <dd className={`mt-0.5 truncate text-lg font-bold ${fund.realizedProfit < 0 ? "text-danger" : ""}`}>{formatTaka(fund.realizedProfit)}</dd>
              </div>
            </dl>
          ) : (
            <Alert>{t.home.loadError}</Alert>
          )}
          <Link href="/investments" className="inline-block text-sm font-semibold text-accent hover:underline">
            {t.money.seeInvestments} →
          </Link>
        </Card>
      </div>

      {/* Quick links */}
      <div>
        <h2 className="mb-3 text-lg font-bold">{t.home.quickLinks}</h2>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <Link href="/deposits" className="group block">
            <Card className="h-full p-5 transition group-hover:border-accent sm:p-5">
              <p className="font-bold">{t.home.depositsCardTitle}</p>
              <p className="mt-1 text-sm text-muted">{t.home.depositsCardBody}</p>
            </Card>
          </Link>
          <Link href="/profile" className="group block">
            <Card className="h-full p-5 transition group-hover:border-accent sm:p-5">
              <p className="font-bold">{t.home.profileCardTitle}</p>
              <p className="mt-1 text-sm text-muted">{t.home.profileCardBody}</p>
            </Card>
          </Link>
          {isAdmin && (
            <>
              <Link href="/admin/members" className="group block">
                <Card className="h-full p-5 transition group-hover:border-accent sm:p-5">
                  <p className="font-bold">{t.admin.membersCardTitle}</p>
                  <p className="mt-1 text-sm text-muted">{t.admin.membersCardBody}</p>
                </Card>
              </Link>
              <Link href="/admin/deposits" className="group block">
                <Card className="h-full p-5 transition group-hover:border-accent sm:p-5">
                  <p className="font-bold">{t.admin.depositsCardTitle}</p>
                  <p className="mt-1 text-sm text-muted">{t.admin.depositsCardBody}</p>
                </Card>
              </Link>
              <Link href="/admin/expenses" className="group block">
                <Card className="h-full p-5 transition group-hover:border-accent sm:p-5">
                  <p className="font-bold">{t.admin.expensesCardTitle}</p>
                  <p className="mt-1 text-sm text-muted">{t.admin.expensesCardBody}</p>
                </Card>
              </Link>
              <Link href="/admin/investments" className="group block">
                <Card className="h-full p-5 transition group-hover:border-accent sm:p-5">
                  <p className="font-bold">{t.admin.investmentsCardTitle}</p>
                  <p className="mt-1 text-sm text-muted">{t.admin.investmentsCardBody}</p>
                </Card>
              </Link>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
