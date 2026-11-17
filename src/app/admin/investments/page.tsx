import type { Metadata } from "next";
import Link from "next/link";
import { CostForm, IncomeForm, PurchaseForm, ReverseIncome, SaleForm } from "@/components/InvestmentForms";
import { RequestActions } from "@/components/RequestActions";
import { Alert, Card, Chip, cn } from "@/components/ui";
import { requireAdmin } from "@/lib/auth";
import { formatDay, formatTaka, todayInDhakaPlain } from "@/lib/format";
import { getI18n } from "@/lib/i18n/server";
import { fromCents, sumCents, toCents, unpackDescription } from "@/lib/money";
import { incomeTotals, loadExpenses, loadIncome, loadInvestments, loadPeople, loadRequests, type Investment, type MoneyRequest } from "@/lib/moneyData";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Investments" };

const TABS = ["held", "sold"] as const;
type Tab = (typeof TABS)[number];

export default async function AdminInvestmentsPage({ searchParams }: PageProps<"/admin/investments">) {
  const [{ t, lang }, me] = await Promise.all([getI18n(), requireAdmin()]);
  const sp = await searchParams;
  const one = (v: string | string[] | undefined) => (typeof v === "string" ? v : "");
  const tab: Tab = one(sp.tab) === "sold" ? "sold" : "held";
  const flash = one(sp.flash);
  const supabase = await createClient();

  const [inv, income, people, pending, approvedCosts, expenses, partRes] = await Promise.all([
    loadInvestments(supabase),
    loadIncome(supabase),
    loadPeople(supabase),
    loadRequests(supabase, { kinds: ["purchase", "investment_cost", "sale", "income"], status: "pending" }),
    loadRequests(supabase, { kinds: ["investment_cost"], status: "approved" }),
    loadExpenses(supabase, [0, 999]),
    supabase.from("investment_participation").select("investment_id, member_id, contribution_delta"),
  ]);
  const who = (id: string | null) => (id ? (people.get(id) ?? "—") : "—");
  const invById = new Map(inv.rows.map((i) => [i.id, i]));
  const totals = incomeTotals(income);
  const today = todayInDhakaPlain();

  // contributions per investment and member, added up in whole cents for display
  const parts = new Map<string, Map<string, number[]>>();
  for (const r of (partRes.data ?? []) as { investment_id: string; member_id: string; contribution_delta: number }[]) {
    const m = parts.get(r.investment_id) ?? new Map<string, number[]>();
    m.set(r.member_id, [...(m.get(r.member_id) ?? []), Number(r.contribution_delta)]);
    parts.set(r.investment_id, m);
  }

  const purchases = pending.rows.filter((r) => r.kind === "purchase");
  const costItems = pending.rows.filter((r) => r.kind === "investment_cost");
  const pendingCostsOf = (purchaseId: string) => costItems.filter((c) => c.purchaseRequestId === purchaseId).length;
  const basisOf = (p: MoneyRequest) =>
    fromCents(toCents(p.amount) + sumCents(approvedCosts.rows.filter((c) => c.purchaseRequestId === p.id).map((c) => c.amount)));

  const label = (i: Investment) => `${i.title}`;
  const heldRows = inv.rows.filter((i) => i.status === "held");
  const shown = inv.rows.filter((i) => i.status === tab);
  const incomeReversed = new Set(income.filter((r) => r.reversesIncomeId).map((r) => r.reversesIncomeId as string));
  const incomeReversalWaiting = new Set(pending.rows.filter((r) => r.kind === "income" && r.reversesIncomeId).map((r) => r.reversesIncomeId as string));

  const details = (text: string | null) => {
    const d = unpackDescription(text);
    return [
      d.location && `${t.money.plotLocation}: ${d.location}`,
      d.size && `${t.money.plotSize}: ${d.size}`,
      d.note && `${t.money.plotNote}: ${d.note}`,
      d.rest,
    ].filter(Boolean) as string[];
  };

  const requestCard = (r: MoneyRequest) => {
    const target = r.investmentId ? invById.get(r.investmentId) : undefined;
    const purchaseTarget = r.purchaseRequestId ? purchases.find((p) => p.id === r.purchaseRequestId) : undefined;
    const isReversal = r.kind === "income" && r.reversesIncomeId;
    const resultPreview = r.kind === "sale" && target ? fromCents(toCents(r.amount) - toCents(target.basis)) : null;
    return (
      <li key={r.id}>
        <Card className="space-y-3 p-4 sm:p-5">
          <div className="flex flex-wrap items-start justify-between gap-2">
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-1.5">
                <Chip tone="gold">{t.money[`requestKind_${r.kind}`]}</Chip>
                {isReversal && <Chip>{t.money.reversalChip}</Chip>}
              </div>
              <p className="mt-1 font-semibold">
                {r.kind === "income" || r.kind === "sale" ? (target?.title ?? "—") : r.title}
              </p>
              <p className="text-xs text-muted">
                {formatDay(r.eventDate, lang)}
                {r.kind === "investment_cost" && ` · ${purchaseTarget ? `${t.money.waitingPurchase}: ${purchaseTarget.title}` : (target?.title ?? "")}`}
                {r.kind === "purchase" && r.investmentKind ? ` · ${t.money[`kind_${r.investmentKind}`]}` : ""}
              </p>
            </div>
            <p className={cn("text-xl font-bold", r.amount < 0 && "text-accent")}>{formatTaka(r.amount)}</p>
          </div>
          {r.kind === "purchase" && details(r.description).map((l) => <p key={l} className="whitespace-pre-line text-sm text-muted">{l}</p>)}
          {r.kind !== "purchase" && r.description && <p className="whitespace-pre-line text-sm text-muted">{r.description}</p>}
          {r.kind === "investment_cost" && <p className="text-xs text-muted">{purchaseTarget ? t.money.costHintPending : t.money.costHintHeld}</p>}
          {resultPreview !== null && (
            <p className="rounded-2xl bg-fg/5 px-4 py-2 text-sm">
              {t.money.saleBasis}: {formatTaka(target!.basis)} ·{" "}
              <span className={cn("font-bold", resultPreview < 0 ? "text-danger" : "text-accent")}>
                {resultPreview < 0 ? t.money.lossWord : resultPreview > 0 ? t.money.profitWord : t.money.noGainLoss}: {formatTaka(Math.abs(resultPreview))}
              </span>
            </p>
          )}
          <p className="text-xs text-muted">
            {t.money.maker}: {who(r.proposedBy)}
          </p>
          <RequestActions
            requestId={r.id}
            kind={r.kind}
            blocked={r.proposedBy === me.id}
            basis={r.kind === "purchase" ? basisOf(r) : undefined}
            approveDisabledNote={r.kind === "purchase" && pendingCostsOf(r.id) > 0 ? t.money.pendingCostsFirst : undefined}
          />
        </Card>
      </li>
    );
  };

  const card = (i: Investment) => {
    const p = parts.get(i.id);
    const costsHere = expenses.rows.filter((e) => e.investmentId === i.id);
    const incomeHere = income.filter((r) => r.investmentId === i.id);
    return (
      <li key={i.id}>
        <Card className="space-y-4 p-4 sm:p-5">
          <div className="flex flex-wrap items-start justify-between gap-2">
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-1.5">
                <Chip tone="accent">{t.money[`kind_${i.kind}`]}</Chip>
                <Chip tone={i.status === "held" ? "gold" : "neutral"}>{i.status === "held" ? t.money.held : t.money.sold}</Chip>
              </div>
              <h3 className="mt-1 text-lg font-bold">{i.title}</h3>
              <p className="text-xs text-muted">
                {t.money.purchasedOn} {formatDay(i.purchaseDate, lang)}
                {i.saleDate && ` · ${t.money.soldOn} ${formatDay(i.saleDate, lang)}`}
              </p>
            </div>
            <div className="text-right">
              <p className="text-xs text-muted">{t.money.costBasis}</p>
              <p className="whitespace-nowrap text-xl font-bold">{formatTaka(i.basis)}</p>
            </div>
          </div>
          {details(i.description).map((l) => (
            <p key={l} className="whitespace-pre-line text-sm text-muted">{l}</p>
          ))}
          <dl className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
            <Stat label={t.money.purchaseCost} value={formatTaka(i.cost)} />
            <Stat label={t.money.extraCosts} value={formatTaka(i.capitalizedCosts)} />
            <Stat label={t.money.totalIncome} value={formatTaka(totals.get(i.id) ?? 0)} />
            {i.status === "sold" && i.saleAmount !== null && i.result !== null && (
              <Stat
                label={t.money.soldFor}
                value={formatTaka(i.saleAmount)}
                sub={`${i.result < 0 ? t.money.lossWord : i.result > 0 ? t.money.profitWord : t.money.noGainLoss}: ${formatTaka(Math.abs(i.result))}`}
                tone={i.result < 0 ? "text-danger" : "text-accent"}
              />
            )}
          </dl>
          {p && (
            <details className="text-sm">
              <summary className="cursor-pointer font-semibold">{t.money.participantsLabel} ({p.size})</summary>
              <ul className="mt-2 grid gap-1 sm:grid-cols-2">
                {[...p].map(([mid, v]) => (
                  <li key={mid} className="flex justify-between gap-3 rounded-xl bg-fg/5 px-3 py-1.5">
                    <span className="truncate">{who(mid)}</span>
                    <span className="font-medium">{formatTaka(fromCents(sumCents(v)))}</span>
                  </li>
                ))}
              </ul>
            </details>
          )}
          {costsHere.length > 0 && (
            <details className="text-sm">
              <summary className="cursor-pointer font-semibold">{t.money.costItems} ({costsHere.length})</summary>
              <ul className="mt-2 space-y-1">
                {costsHere.map((e) => (
                  <li key={e.id} className="flex justify-between gap-3">
                    <span className="truncate">{e.title} · {formatDay(e.spentOn, lang)}</span>
                    <span className="font-medium">{formatTaka(e.amount)}</span>
                  </li>
                ))}
              </ul>
            </details>
          )}
          {incomeHere.length > 0 && (
            <details className="text-sm">
              <summary className="cursor-pointer font-semibold">{t.money.incomeEntries} ({incomeHere.length})</summary>
              <ul className="mt-2 space-y-3">
                {incomeHere.map((r) => {
                  const canReverse = r.amount > 0 && !incomeReversed.has(r.id) && !incomeReversalWaiting.has(r.id);
                  return (
                    <li key={r.id} className="space-y-1.5">
                      <div className="flex justify-between gap-3">
                        <span className="truncate">
                          {formatDay(r.receivedOn, lang)}
                          {r.note ? ` · ${r.note}` : ""}
                          {r.reversesIncomeId && ` · ${t.money.reversalChip}`}
                          {incomeReversed.has(r.id) && ` · ${t.money.reversedChip}`}
                        </span>
                        <span className={cn("font-medium", r.amount < 0 && "text-danger")}>{formatTaka(r.amount)}</span>
                      </div>
                      {canReverse && i.status === "held" && <ReverseIncome investmentId={i.id} incomeId={r.id} today={today} />}
                    </li>
                  );
                })}
              </ul>
            </details>
          )}
        </Card>
      </li>
    );
  };

  return (
    <div className="mx-auto w-full max-w-4xl px-4 py-8 sm:py-10">
      <Link href="/admin" className="text-sm font-semibold text-accent hover:underline">
        ← {t.admin.title}
      </Link>
      <h1 className="mt-2 text-3xl font-bold tracking-tight">{t.money.investmentsAdminTitle}</h1>
      <p className="mt-1.5 text-sm text-muted">{t.money.investmentsAdminSubtitle}</p>

      <div className="mt-6 space-y-4">
        {flash === "approved" && <Alert tone="success">{t.money.approvedMsg}</Alert>}
        {flash === "rejected" && <Alert tone="success">{t.money.rejectedMsg}</Alert>}
        {inv.failed && <Alert>{t.money.errGeneric}</Alert>}

        <section className="space-y-3">
          <h2 className="text-lg font-bold">
            {t.money.waitingTitle} {pending.rows.length > 0 && <span className="text-muted">({pending.rows.length})</span>}
          </h2>
          {pending.rows.length === 0 ? (
            <Card className="text-center text-sm text-muted">{t.money.waitingEmpty}</Card>
          ) : (
            <ul className="space-y-3">{pending.rows.map(requestCard)}</ul>
          )}
        </section>

        <section className="space-y-3">
          <PurchaseForm today={today} />
          <CostForm
            today={today}
            targets={[
              ...purchases.map((p) => ({ id: p.id, label: p.title ?? "—", pending: true })),
              ...heldRows.map((i) => ({ id: i.id, label: label(i), pending: false })),
            ]}
          />
          <SaleForm today={today} investments={heldRows.map((i) => ({ id: i.id, label: label(i) }))} />
          <IncomeForm today={today} investments={heldRows.map((i) => ({ id: i.id, label: label(i) }))} />
        </section>

        <nav className="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1" aria-label={t.money.investmentsAdminTitle}>
          {TABS.map((k) => (
            <Link
              key={k}
              href={`/admin/investments?tab=${k}`}
              aria-current={tab === k ? "page" : undefined}
              className={cn(
                "inline-flex h-10 shrink-0 items-center gap-2 rounded-full border px-4 text-sm font-semibold transition",
                tab === k ? "border-accent bg-accent text-accent-fg" : "border-border bg-surface hover:bg-accent-soft",
              )}
            >
              {k === "held" ? t.money.tabHeld : t.money.tabSold}
              <span className={cn("rounded-full px-1.5 text-xs", tab === k ? "bg-black/15" : "bg-fg/8")}>
                {inv.rows.filter((i) => i.status === k).length}
              </span>
            </Link>
          ))}
        </nav>

        {shown.length === 0 ? (
          <Card className="text-center text-sm text-muted">{t.money.noInvestments}</Card>
        ) : (
          <ul className="space-y-3">{shown.map(card)}</ul>
        )}
      </div>
    </div>
  );
}

function Stat({ label, value, sub, tone }: { label: string; value: string; sub?: string; tone?: string }) {
  return (
    <div className="min-w-0 rounded-2xl border border-border bg-surface-strong/60 p-3">
      <dt className="text-xs text-muted">{label}</dt>
      <dd className="mt-0.5 truncate font-bold">{value}</dd>
      {sub && <p className={cn("mt-0.5 text-xs font-semibold", tone)}>{sub}</p>}
    </div>
  );
}
