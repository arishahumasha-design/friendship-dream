import type { Metadata } from "next";
import Link from "next/link";
import { DepositForm, type DepositPrefill } from "@/components/DepositForm";
import { Pager } from "@/components/Pager";
import { depositTone } from "@/components/MemberBits";
import { ReceiptButton } from "@/components/ReceiptButton";
import { Alert, Card, Chip, ButtonLink } from "@/components/ui";
import { requireActiveMember } from "@/lib/auth";
import { DEPOSIT_COLUMNS, mapDeposit, type RawDeposit } from "@/lib/deposits";
import { formatDateTime, formatMonth, formatTaka } from "@/lib/format";
import { getI18n } from "@/lib/i18n/server";
import { loadSettings } from "@/lib/settings";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "My deposits" };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PAGE_SIZE = 100;

/** Active members submit deposits and see their own history. */
export default async function DepositsPage({ searchParams }: PageProps<"/deposits">) {
  const [{ t, lang }, me] = await Promise.all([getI18n(), requireActiveMember()]);
  const sp = await searchParams;
  const supabase = await createClient();

  const page = Math.max(1, Math.floor(Number(typeof sp.page === "string" ? sp.page : 1)) || 1);
  const againId = typeof sp.again === "string" && UUID_RE.test(sp.again) ? sp.again : null;
  const [settings, { data, count }, again] = await Promise.all([
    loadSettings(supabase),
    supabase
      .from("deposits")
      .select(DEPOSIT_COLUMNS, { count: "exact" })
      .eq("member_id", me.id)
      .order("period_month", { ascending: false })
      .order("kind")
      .order("submitted_at", { ascending: false })
      .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1),
    againId
      ? supabase.from("deposits").select(DEPOSIT_COLUMNS).eq("id", againId).eq("member_id", me.id).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);
  const deposits = ((data ?? []) as RawDeposit[]).map(mapDeposit);
  const totalPages = Math.max(1, Math.ceil((count ?? 0) / PAGE_SIZE));

  // "Submit again" copies a REJECTED deposit into the form (the old row stays as it is).
  const againRow = again.data ? mapDeposit(again.data as RawDeposit) : undefined;
  const source = againRow?.status === "rejected" ? againRow : undefined;
  const prefill: DepositPrefill | undefined = source
    ? { amount: source.amount, periodMonth: source.periodMonth, kind: source.kind, method: source.method }
    : undefined;

  return (
    <div className="mx-auto w-full max-w-4xl px-4 py-8 sm:py-10">
      <h1 className="text-3xl font-bold tracking-tight">{t.deposits.title}</h1>
      <p className="mt-1.5 text-sm text-muted">{t.deposits.subtitle}</p>

      <div className="mt-6 space-y-6">
        {sp.sent && <Alert tone="success">{t.deposits.submitted}</Alert>}
        <DepositForm
          key={source?.id ?? "new"}
          memberId={me.id}
          monthlyAmount={settings.monthlyAmount}
          prefill={prefill}
        />

        <Card className="p-4 sm:p-6">
          <h2 className="px-2 text-lg font-bold">{t.deposits.historyTitle}</h2>
          {deposits.length === 0 ? (
            <p className="p-4 text-sm text-muted">{t.deposits.historyEmpty}</p>
          ) : (
            <ul className="mt-3 divide-y divide-border">
              {deposits.map((d) => (
                <li key={d.id} className="space-y-2 px-2 py-4">
                  <div className="flex flex-wrap items-start justify-between gap-2">
                    <div>
                      <p className="font-semibold">{formatMonth(d.periodMonth, lang)}</p>
                      <p className="text-xs text-muted">
                        {t.deposits[`kind_${d.kind}`]} · {t.deposits[`method_${d.method}`]}
                      </p>
                    </div>
                    <div className="text-right">
                      <p className="text-lg font-bold">{formatTaka(d.amount)}</p>
                      <Chip tone={depositTone(d.status)}>{t.deposits[`status_${d.status}`]}</Chip>
                    </div>
                  </div>

                  <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-muted">
                    {d.transactionRef && (
                      <span>
                        {t.deposits.transaction}: <span className="font-mono text-fg">{d.transactionRef}</span>
                      </span>
                    )}
                    <span>
                      {t.deposits.submittedOn}: {formatDateTime(d.submittedAt, lang)}
                    </span>
                    {d.reviewedAt && (
                      <span>
                        {t.deposits.reviewedOn}: {formatDateTime(d.reviewedAt, lang)}
                      </span>
                    )}
                    {d.isHistorical && <Chip>{t.deposits.oldRecord}</Chip>}
                    {d.correctsDepositId && <Chip>{t.deposits.correction}</Chip>}
                  </div>

                  {d.note && <p className="whitespace-pre-line text-sm text-muted">{d.note}</p>}

                  {d.status === "rejected" && d.rejectReason && (
                    <div className="rounded-2xl bg-danger-soft px-4 py-3 text-sm text-danger">
                      <span className="font-semibold">{t.deposits.rejectReasonLabel}:</span>{" "}
                      <span className="whitespace-pre-line">{d.rejectReason}</span>
                    </div>
                  )}

                  <div className="flex flex-wrap items-center gap-4">
                    {d.hasReceipt ? (
                      <ReceiptButton depositId={d.id} isPdf={d.receiptIsPdf} label={t.deposits.viewReceipt} />
                    ) : (
                      <span className="text-xs text-muted">{t.deposits.noReceipt}</span>
                    )}
                    {d.status === "rejected" && (
                      <ButtonLink href={`/deposits?again=${d.id}`} variant="secondary" className="h-9 px-4">
                        {t.deposits.resubmit}
                      </ButtonLink>
                    )}
                  </div>
                </li>
              ))}
            </ul>
          )}
          <Pager page={page} totalPages={totalPages} hrefFor={(p) => `/deposits?page=${p}`} />
        </Card>

        <Link href="/home" className="inline-block text-sm font-semibold text-accent hover:underline">
          ← {t.common.home}
        </Link>
      </div>
    </div>
  );
}
