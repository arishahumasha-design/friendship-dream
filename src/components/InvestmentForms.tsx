"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState, type FormEvent, type ReactNode } from "react";
import { addInvestmentCost, previewSale, proposeInvestment, proposeSale, recordIncome } from "@/app/actions/money";
import { formatTaka } from "@/lib/format";
import { useI18n } from "./I18nProvider";
import { Alert, Button, Card, Field, Select, TextArea } from "./ui";

type Msg = { tone: "error" | "success"; text: string } | null;
type Option = { id: string; label: string };

/** A collapsible form card with one submit that calls a server action. */
function FormCard({
  title,
  hint,
  children,
  onSubmit,
  busy,
  msg,
  submitLabel,
}: {
  title: string;
  hint?: string;
  children: ReactNode;
  onSubmit: (e: FormEvent) => void;
  busy: boolean;
  msg: Msg;
  submitLabel: string;
}) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  if (!open) {
    return (
      <Card className="flex items-center justify-between gap-3 p-4 sm:p-5">
        <div className="min-w-0">
          <h3 className="font-bold">{title}</h3>
          {msg?.tone === "success" && <p className="mt-0.5 text-xs font-medium text-accent">{msg.text}</p>}
        </div>
        <Button type="button" variant="secondary" onClick={() => setOpen(true)} className="h-10 shrink-0">
          {t.money.open}
        </Button>
      </Card>
    );
  }
  return (
    <Card className="space-y-4 p-4 sm:p-6">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h3 className="text-lg font-bold">{title}</h3>
          {hint && <p className="mt-0.5 text-sm text-muted">{hint}</p>}
        </div>
        <Button type="button" variant="ghost" onClick={() => setOpen(false)} className="h-9 px-3">
          {t.money.close}
        </Button>
      </div>
      <form onSubmit={onSubmit} className="space-y-4" noValidate>
        {children}
        {msg && <Alert tone={msg.tone}>{msg.text}</Alert>}
        <Button type="submit" disabled={busy} className="w-full sm:w-auto sm:min-w-44">
          {busy ? t.money.working : submitLabel}
        </Button>
      </form>
    </Card>
  );
}

function useSubmit(
  run: () => Promise<{ ok: true } | { ok: false; message: string }>,
  successText: string,
  reset: () => void,
) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<Msg>(null);
  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setMsg(null);
    const res = await run();
    setBusy(false);
    if (!res.ok) return setMsg({ tone: "error", text: res.message });
    reset();
    setMsg({ tone: "success", text: successText });
    router.refresh();
  }
  return { busy, msg, onSubmit };
}

export function PurchaseForm({ today }: { today: string }) {
  const { t } = useI18n();
  const empty = { title: "", kind: "land", location: "", size: "", cost: "", date: today, note: "" };
  const [f, setF] = useState(empty);
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((s) => ({ ...s, [k]: e.target.value }));
  const { busy, msg, onSubmit } = useSubmit(() => proposeInvestment(f), t.money.purchaseSent, () => setF(empty));
  return (
    <FormCard title={t.money.proposePurchase} hint={t.money.purchaseHint} onSubmit={onSubmit} busy={busy} msg={msg} submitLabel={t.money.submitPurchase}>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field id="p-title" label={t.money.plotName} value={f.title} onChange={set("title")} maxLength={200} />
        <Select id="p-kind" label={t.money.plotKind} value={f.kind} onChange={set("kind")}>
          {(["land", "shop", "other"] as const).map((k) => (
            <option key={k} value={k}>
              {t.money[`kind_${k}`]}
            </option>
          ))}
        </Select>
        <Field id="p-loc" label={t.money.plotLocation} hint={t.money.optional} value={f.location} onChange={set("location")} maxLength={300} />
        <Field id="p-size" label={t.money.plotSize} hint={t.money.plotSizeHint} value={f.size} onChange={set("size")} maxLength={100} />
        <Field id="p-cost" label={t.money.plotCost} inputMode="decimal" value={f.cost} onChange={set("cost")} autoComplete="off" />
        <Field id="p-date" type="date" label={t.money.plotDate} value={f.date} onChange={set("date")} />
      </div>
      <TextArea id="p-note" label={t.money.plotNote} hint={t.money.optional} value={f.note} maxLength={1000} onChange={set("note")} />
    </FormCard>
  );
}

/** target = a purchase that is still waiting, or a held investment. */
export function CostForm({ today, targets }: { today: string; targets: (Option & { pending: boolean })[] }) {
  const { t } = useI18n();
  const empty = { target: "", title: "", amount: "", date: today, note: "" };
  const [f, setF] = useState(empty);
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((s) => ({ ...s, [k]: e.target.value }));
  const { busy, msg, onSubmit } = useSubmit(() => addInvestmentCost(f), t.money.costSent, () => setF(empty));
  const chosen = targets.find((x) => x.id === f.target);
  return (
    <FormCard title={t.money.addCostTitle} hint={t.money.costHint} onSubmit={onSubmit} busy={busy} msg={msg} submitLabel={t.money.submitCost}>
      <Select id="c-target" label={t.money.costTarget} hint={chosen ? (chosen.pending ? t.money.costHintPending : t.money.costHintHeld) : undefined} value={f.target} onChange={set("target")}>
        <option value="">{t.money.chooseInvestment}</option>
        {targets.map((x) => (
          <option key={x.id} value={x.id}>
            {x.pending ? `${t.money.waitingPurchase}: ` : ""}
            {x.label}
          </option>
        ))}
      </Select>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field id="c-title" label={t.money.costTitleLabel} value={f.title} onChange={set("title")} maxLength={200} />
        <Field id="c-amount" label={t.money.costAmountLabel} inputMode="decimal" value={f.amount} onChange={set("amount")} autoComplete="off" />
        <Field id="c-date" type="date" label={t.money.costDateLabel} value={f.date} onChange={set("date")} />
      </div>
      <TextArea id="c-note" label={t.money.costNoteLabel} hint={t.money.optional} value={f.note} maxLength={1000} onChange={set("note")} />
    </FormCard>
  );
}

/** Propose a sale. The expected result is worked out by the SERVER (previewSale), never in the browser. */
export function SaleForm({ today, investments }: { today: string; investments: Option[] }) {
  const { t } = useI18n();
  const empty = { investmentId: "", proceeds: "", date: today, note: "" };
  const [f, setF] = useState(empty);
  const [preview, setPreview] = useState<{ basis: number; result: number } | null>(null);
  const [previewErr, setPreviewErr] = useState<string | null>(null);
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((s) => ({ ...s, [k]: e.target.value }));
  const { busy, msg, onSubmit } = useSubmit(() => proposeSale(f), t.money.saleSent, () => {
    setF(empty);
    setPreview(null);
  });

  useEffect(() => {
    if (!f.investmentId || !f.proceeds.trim()) return;
    let cancelled = false;
    const timer = setTimeout(async () => {
      const res = await previewSale(f.investmentId, f.proceeds);
      if (cancelled) return;
      if (res.ok) {
        setPreview({ basis: res.basis, result: res.result });
        setPreviewErr(null);
      } else {
        setPreview(null);
        setPreviewErr(res.message);
      }
    }, 450);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [f.investmentId, f.proceeds]);

  const showing = f.investmentId && f.proceeds.trim();
  return (
    <FormCard title={t.money.proposeSaleTitle} hint={t.money.saleHint} onSubmit={onSubmit} busy={busy} msg={msg} submitLabel={t.money.submitSale}>
      <Select id="s-inv" label={t.money.saleInvestment} value={f.investmentId} onChange={set("investmentId")}>
        <option value="">{t.money.chooseInvestment}</option>
        {investments.map((x) => (
          <option key={x.id} value={x.id}>
            {x.label}
          </option>
        ))}
      </Select>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field id="s-proceeds" label={t.money.saleProceeds} inputMode="decimal" value={f.proceeds} onChange={set("proceeds")} autoComplete="off" />
        <Field id="s-date" type="date" label={t.money.saleDateLabel} value={f.date} onChange={set("date")} />
      </div>
      {showing && (preview || previewErr) && (
        <div aria-live="polite" className="rounded-2xl border border-border bg-fg/5 px-4 py-3 text-sm">
          {preview ? (
            <>
              <p className="font-semibold">{t.money.salePreview}</p>
              <p className="mt-1 text-muted">
                {t.money.saleBasis}: {formatTaka(preview.basis)}
              </p>
              <p className={`mt-1 text-lg font-bold ${preview.result < 0 ? "text-danger" : "text-accent"}`}>
                {preview.result < 0 ? t.money.lossWord : preview.result > 0 ? t.money.profitWord : t.money.noGainLoss}: {formatTaka(Math.abs(preview.result))}
              </p>
              <p className="mt-1 text-xs text-muted">{t.money.previewNote}</p>
            </>
          ) : (
            <p className="text-danger">{previewErr}</p>
          )}
        </div>
      )}
      <TextArea id="s-note" label={t.money.saleNote} hint={t.money.optional} value={f.note} maxLength={1000} onChange={set("note")} />
    </FormCard>
  );
}

export function IncomeForm({ today, investments }: { today: string; investments: Option[] }) {
  const { t } = useI18n();
  const empty = { investmentId: "", amount: "", date: today, note: "" };
  const [f, setF] = useState(empty);
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((s) => ({ ...s, [k]: e.target.value }));
  const { busy, msg, onSubmit } = useSubmit(() => recordIncome(f), t.money.incomeSent, () => setF(empty));
  return (
    <FormCard title={t.money.recordIncomeTitle} hint={t.money.incomeHint} onSubmit={onSubmit} busy={busy} msg={msg} submitLabel={t.money.submitIncome}>
      <Select id="i-inv" label={t.money.incomeInvestment} value={f.investmentId} onChange={set("investmentId")}>
        <option value="">{t.money.chooseInvestment}</option>
        {investments.map((x) => (
          <option key={x.id} value={x.id}>
            {x.label}
          </option>
        ))}
      </Select>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field id="i-amount" label={t.money.incomeAmountLabel} inputMode="decimal" value={f.amount} onChange={set("amount")} autoComplete="off" />
        <Field id="i-date" type="date" label={t.money.incomeDateLabel} value={f.date} onChange={set("date")} />
      </div>
      <TextArea id="i-note" label={t.money.incomeNote} hint={t.money.optional} value={f.note} maxLength={1000} onChange={set("note")} />
    </FormCard>
  );
}

/** Reverse one income entry completely (the amount is taken from the database; a second admin approves). */
export function ReverseIncome({ investmentId, incomeId, today }: { investmentId: string; incomeId: string; today: string }) {
  const { t } = useI18n();
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<Msg>(null);
  const [confirming, setConfirming] = useState(false);
  async function send() {
    setBusy(true);
    const res = await recordIncome({ investmentId, reverses: incomeId, date: today, note: "" });
    setBusy(false);
    setConfirming(false);
    if (!res.ok) return setMsg({ tone: "error", text: res.message });
    setMsg({ tone: "success", text: t.money.incomeReversalSent });
    router.refresh();
  }
  return (
    <div className="space-y-2">
      {msg && <Alert tone={msg.tone}>{msg.text}</Alert>}
      {confirming ? (
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-sm font-medium">{t.money.reverseIncomeConfirm}</span>
          <Button type="button" disabled={busy} onClick={send} className="h-9 px-4">
            {busy ? t.money.working : t.money.confirmReverse}
          </Button>
          <Button type="button" variant="secondary" disabled={busy} onClick={() => setConfirming(false)} className="h-9 px-4">
            {t.money.cancel}
          </Button>
        </div>
      ) : (
        <Button type="button" variant="secondary" onClick={() => setConfirming(true)} className="h-9 px-4">
          {t.money.reverseIncome}
        </Button>
      )}
    </div>
  );
}
