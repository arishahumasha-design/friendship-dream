"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState, type FormEvent } from "react";
import {
  createManualDeposit,
  listCorrectable,
  type CorrectableDeposit,
} from "@/app/actions/deposits";
import { ADMIN_KINDS, METHODS, newRequestId } from "@/lib/deposits";
import type { Dictionary } from "@/lib/i18n/types";
import { currentMonthDhaka, formatMonth, formatTaka, monthOptions, parseAmount } from "@/lib/format";
import { useI18n } from "./I18nProvider";
import { Alert, Button, Card, Field, Select, TextArea } from "./ui";

export type MemberOption = { id: string; name: string; memberNo: number };

/** Error keys that live in the adminDeposits section (all others live in deposits). Checked by TypeScript. */
const ADMIN_ERROR_KEYS = [
  "errMember",
  "errMonth",
  "errAmount",
  "errNote",
  "errCorrection",
  "errCorrectionPositive",
  "errNegativeNoCorrection",
  "errCorrectionMember",
] as const satisfies readonly (keyof Dictionary["adminDeposits"])[];
type AdminErrorKey = (typeof ADMIN_ERROR_KEYS)[number];
const isAdminErrorKey = (k: string): k is AdminErrorKey => (ADMIN_ERROR_KEYS as readonly string[]).includes(k);

/** Super admin only: a deposit saved directly as approved (old records, late fees, corrections). */
export function ManualDepositForm({ members }: { members: MemberOption[] }) {
  const { t, lang } = useI18n();
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [memberId, setMemberId] = useState("");
  const [month, setMonth] = useState(currentMonthDhaka());
  const [kind, setKind] = useState("monthly");
  const [amount, setAmount] = useState("");
  const [method, setMethod] = useState("cash");
  const [txn, setTxn] = useState("");
  const [note, setNote] = useState("");
  const [historical, setHistorical] = useState(false);
  const [corrects, setCorrects] = useState("");
  // One id per form load: if the same entry is sent twice (double click), the second is refused.
  const [requestId, setRequestId] = useState(newRequestId);
  const [correctable, setCorrectable] = useState<CorrectableDeposit[] | null>(null);

  const parsed = parseAmount(amount, { allowNegative: true });
  const isCorrection = parsed !== null && parsed < 0;
  const months = monthOptions(72, 6);
  // While a correction points at a deposit, month and type follow that deposit.
  const locked = isCorrection && !!corrects;

  // Load this member's approved deposits when a correction (negative amount) is being entered.
  useEffect(() => {
    if (!isCorrection || !memberId) return;
    let cancelled = false;
    listCorrectable(memberId).then((rows) => {
      if (!cancelled) setCorrectable(rows);
    });
    return () => {
      cancelled = true;
    };
  }, [isCorrection, memberId]);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    setError(null);
    setBusy(true);
    const res = await createManualDeposit({
      requestId,
      memberId,
      periodMonth: month,
      kind,
      amount,
      method,
      transactionRef: txn,
      note,
      isHistorical: historical,
      correctsDepositId: isCorrection ? corrects : "",
    });
    setBusy(false);
    if (!res.ok) {
      if (res.error === "errAlreadySaved") {
        // The first click already saved it: show the list instead of an error.
        setOpen(false);
        setRequestId(newRequestId());
        router.replace("/admin/deposits?flash=duplicate");
        router.refresh();
        return;
      }
      setError(isAdminErrorKey(res.error) ? t.adminDeposits[res.error] : t.deposits[res.error]);
      return;
    }
    setRequestId(newRequestId());
    setAmount("");
    setKind("monthly");
    setMonth(currentMonthDhaka());
    setMethod("cash");
    setTxn("");
    setNote("");
    setCorrects("");
    setHistorical(false);
    setOpen(false);
    router.replace("/admin/deposits?flash=manual");
    router.refresh();
  }

  if (!open) {
    return (
      <Card className="flex flex-wrap items-center justify-between gap-3 p-5 sm:p-6">
        <div className="min-w-0">
          <h2 className="text-lg font-bold">{t.adminDeposits.manualTitle}</h2>
          <p className="mt-0.5 text-sm text-muted">{t.adminDeposits.manualBody}</p>
        </div>
        <Button type="button" variant="secondary" onClick={() => setOpen(true)}>
          {t.adminDeposits.manualOpen}
        </Button>
      </Card>
    );
  }

  return (
    <Card className="space-y-4">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-lg font-bold">{t.adminDeposits.manualTitle}</h2>
          <p className="mt-0.5 text-sm text-muted">{t.adminDeposits.manualBody}</p>
        </div>
        <Button type="button" variant="ghost" onClick={() => setOpen(false)} className="h-9 px-3">
          {t.adminDeposits.manualClose}
        </Button>
      </div>

      <form onSubmit={onSubmit} className="space-y-4" noValidate>
        <div className="grid gap-4 sm:grid-cols-2">
          <Select
            id="m-member"
            label={t.adminDeposits.member}
            value={memberId}
            onChange={(e) => {
              setMemberId(e.target.value);
              setCorrects("");
              setCorrectable(null);
            }}
          >
            <option value="">{t.adminDeposits.chooseMember}</option>
            {members.map((m) => (
              <option key={m.id} value={m.id}>
                {m.memberNo}. {m.name}
              </option>
            ))}
          </Select>
          <Select
            id="m-month"
            label={t.adminDeposits.month}
            value={month}
            disabled={locked}
            onChange={(e) => setMonth(e.target.value)}
          >
            {months.map((m) => (
              <option key={m} value={m}>
                {formatMonth(m, lang)}
              </option>
            ))}
          </Select>
          <Select
            id="m-kind"
            label={t.adminDeposits.kind}
            value={kind}
            disabled={locked}
            onChange={(e) => setKind(e.target.value)}
          >
            {ADMIN_KINDS.map((k) => (
              <option key={k} value={k}>
                {t.deposits[`kind_${k}`]}
              </option>
            ))}
          </Select>
          <Field
            id="m-amount"
            label={t.adminDeposits.amount}
            hint={t.adminDeposits.amountHint}
            inputMode="decimal"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            autoComplete="off"
          />
          <Select id="m-method" label={t.adminDeposits.method} value={method} onChange={(e) => setMethod(e.target.value)}>
            {METHODS.map((m) => (
              <option key={m} value={m}>
                {t.deposits[`method_${m}`]}
              </option>
            ))}
          </Select>
          <Field
            id="m-txn"
            label={t.adminDeposits.txnId}
            hint={t.adminDeposits.optional}
            value={txn}
            onChange={(e) => setTxn(e.target.value)}
            autoComplete="off"
            maxLength={100}
          />
        </div>

        {isCorrection && (
          <div className="space-y-1.5">
            <p className="text-xs text-muted">{t.adminDeposits.correctionFollows}</p>
            {correctable && correctable.length === 0 ? (
              <Alert>{t.adminDeposits.noCorrectable}</Alert>
            ) : (
              <Select
                id="m-corrects"
                label={t.adminDeposits.corrects}
                value={corrects}
                onChange={(e) => {
                  setCorrects(e.target.value);
                  const d = (correctable ?? []).find((x) => x.id === e.target.value);
                  if (d) {
                    setKind(d.kind);
                    setMonth(d.periodMonth);
                  }
                }}
              >
                <option value="">{t.adminDeposits.chooseDeposit}</option>
                {(correctable ?? []).map((d) => (
                  <option key={d.id} value={d.id}>
                    {formatMonth(d.periodMonth, lang)} · {t.deposits[`kind_${d.kind}`]} · {formatTaka(d.amount)} ·{" "}
                    {t.deposits[`method_${d.method}`]}
                  </option>
                ))}
              </Select>
            )}
          </div>
        )}

        <TextArea
          id="m-note"
          label={t.adminDeposits.reason}
          hint={t.adminDeposits.reasonHint}
          value={note}
          maxLength={1000}
          onChange={(e) => setNote(e.target.value)}
        />

        <label className="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={historical}
            onChange={(e) => setHistorical(e.target.checked)}
            className="size-4 accent-[var(--accent)]"
          />
          {t.adminDeposits.historicalLabel}
        </label>

        {error && <Alert>{error}</Alert>}
        <Button type="submit" disabled={busy} className="w-full sm:w-auto sm:min-w-52">
          {busy ? t.adminDeposits.saving : t.adminDeposits.saveManual}
        </Button>
      </form>
    </Card>
  );
}
