import type { Metadata } from "next";
import Link from "next/link";
import { Alert, Card, Chip, cn } from "@/components/ui";
import { isAdminRole, requireActiveMember } from "@/lib/auth";
import { formatDay, formatTaka } from "@/lib/format";
import { getI18n } from "@/lib/i18n/server";
import { fromCents, sumCents, unpackDescription } from "@/lib/money";
import { incomeTotals, loadIncome, loadInvestments } from "@/lib/moneyData";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Investments" };

/** Read-only list of the samiti's investments for every active member. */
export default async function InvestmentsPage() {
  const [{ t, lang }, me] = await Promise.all([getI18n(), requireActiveMember()]);
  const supabase = await createClient();
  const isAdmin = isAdminRole(me.role);

  const [inv, income, mine, results, all] = await Promise.all([
    loadInvestments(supabase),
    loadIncome(supabase),
    // RLS: a member only ever gets their own rows here; the filter keeps admins to their own too
    supabase.from("investment_participation").select("investment_id, contribution_delta").eq("member_id", me.id),
    supabase.from("allocations").select("event_id, amount").eq("member_id", me.id).eq("event_type", "sale").eq("basis", "capital"),
    // only admins can read everybody's participation (used for the participant count)
    isAdmin ? supabase.from("investment_participation").select("investment_id, member_id") : Promise.resolve({ data: null }),
  ]);

  const totals = incomeTotals(income);
  const own = new Map<string, number[]>();
  for (const r of (mine.data ?? []) as { investment_id: string; contribution_delta: number }[]) {
    own.set(r.investment_id, [...(own.get(r.investment_id) ?? []), Number(r.contribution_delta)]);
  }
  const ownResult = new Map(((results.data ?? []) as { event_id: string; amount: number }[]).map((r) => [r.event_id, Number(r.amount)]));
  const participants = new Map<string, Set<string>>();
  for (const r of (all.data ?? []) as { investment_id: string; member_id: string }[]) {
    participants.set(r.investment_id, (participants.get(r.investment_id) ?? new Set()).add(r.member_id));
  }

  const held = inv.rows.filter((i) => i.status === "held");
  const sold = inv.rows.filter((i) => i.status === "sold");

  const word = (n: number) => (n < 0 ? t.money.lossWord : n > 0 ? t.money.profitWord : t.money.noGainLoss);

  return (
    <div className="mx-auto w-full max-w-4xl px-4 py-8 sm:py-10">
      <h1 className="text-3xl font-bold tracking-tight">{t.money.memberInvestmentsTitle}</h1>
      <p className="mt-1.5 text-sm text-muted">{t.money.memberInvestmentsSubtitle}</p>
      {isAdmin && (
        <Link href="/admin/investments" className="mt-3 inline-block text-sm font-semibold text-accent hover:underline">
          {t.money.manageInvestments} →
        </Link>
      )}

      <div className="mt-6 space-y-6">
        {inv.failed && <Alert>{t.money.errGeneric}</Alert>}
        {inv.rows.length === 0 && !inv.failed && <Card className="text-center text-sm text-muted">{t.money.noInvestments}</Card>}

        {[
          { key: "held", title: t.money.tabHeld, rows: held },
          { key: "sold", title: t.money.tabSold, rows: sold },
        ]
          .filter((g) => g.rows.length > 0)
          .map((g) => (
            <section key={g.key} className="space-y-3">
              <h2 className="text-lg font-bold">
                {g.title} <span className="text-muted">({g.rows.length})</span>
              </h2>
              <ul className="grid gap-4 sm:grid-cols-2">
                {g.rows.map((i) => {
                  const d = unpackDescription(i.description);
                  const yours = own.get(i.id);
                  const yourResult = ownResult.get(i.id);
                  return (
                    <li key={i.id}>
                      <Card className="h-full space-y-3 p-5 sm:p-5">
                        <div className="flex items-start justify-between gap-2">
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
                            <p className="whitespace-nowrap text-lg font-bold">{formatTaka(i.basis)}</p>
                          </div>
                        </div>
                        {(d.location || d.size || d.note || d.rest) && (
                          <div className="space-y-0.5 text-sm text-muted">
                            {d.location && <p>{t.money.plotLocation}: {d.location}</p>}
                            {d.size && <p>{t.money.plotSize}: {d.size}</p>}
                            {d.note && <p className="whitespace-pre-line">{t.money.plotNote}: {d.note}</p>}
                            {d.rest && <p className="whitespace-pre-line">{d.rest}</p>}
                          </div>
                        )}
                        <dl className="grid grid-cols-2 gap-3 text-sm">
                          <div>
                            <dt className="text-xs text-muted">{t.money.totalIncome}</dt>
                            <dd className="font-bold">{formatTaka(totals.get(i.id) ?? 0)}</dd>
                          </div>
                          {isAdmin && (
                            <div>
                              <dt className="text-xs text-muted">{t.money.participantsLabel}</dt>
                              <dd className="font-bold">{participants.get(i.id)?.size ?? 0}</dd>
                            </div>
                          )}
                          {i.status === "sold" && i.saleAmount !== null && i.result !== null && (
                            <>
                              <div>
                                <dt className="text-xs text-muted">{t.money.soldFor}</dt>
                                <dd className="font-bold">{formatTaka(i.saleAmount)}</dd>
                              </div>
                              <div>
                                <dt className="text-xs text-muted">{t.money.resultLabel}</dt>
                                <dd className={cn("font-bold", i.result < 0 ? "text-danger" : "text-accent")}>
                                  {word(i.result)}: {formatTaka(Math.abs(i.result))}
                                </dd>
                              </div>
                            </>
                          )}
                        </dl>
                        <div className="rounded-2xl border border-border bg-surface-strong/60 px-4 py-3 text-sm">
                          {yours ? (
                            <>
                              <p>
                                {t.money.yourContribution}: <span className="font-bold">{formatTaka(fromCents(sumCents(yours)))}</span>
                              </p>
                              {i.status === "sold" && (
                                <p className="mt-1">
                                  {t.money.yourResult}:{" "}
                                  {yourResult === undefined ? (
                                    <span className="text-muted">—</span>
                                  ) : (
                                    <span className={cn("font-bold", yourResult < 0 ? "text-danger" : "text-accent")}>
                                      {word(yourResult)}: {formatTaka(Math.abs(yourResult))}
                                    </span>
                                  )}
                                </p>
                              )}
                              <p className="mt-1 text-xs text-muted">{t.money.byContribution}</p>
                            </>
                          ) : (
                            <p className="text-muted">{t.money.notParticipant}</p>
                          )}
                        </div>
                      </Card>
                    </li>
                  );
                })}
              </ul>
            </section>
          ))}
      </div>
    </div>
  );
}
