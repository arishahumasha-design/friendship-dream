"use client";

import { useRef, useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { depositErrorKey, METHODS, MEMBER_KINDS, type DepositKind, type PayMethod } from "@/lib/deposits";
import { currentMonthDhaka, formatMonth, monthOptions, parseAmount } from "@/lib/format";
import { createClient } from "@/lib/supabase/client";
import { acceptFor, prepareFile, type PreparedFile } from "@/lib/upload";
import { useI18n } from "./I18nProvider";
import { Alert, Button, Card, Chip, Field, Select, TextArea } from "./ui";

export type DepositPrefill = {
  amount: number;
  periodMonth: string;
  kind: DepositKind;
  method: PayMethod;
};

type Msg = { tone: "error" | "success"; text: string } | null;

/** Random file name that does not need a secure browser context. */
function randomName() {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export function DepositForm({
  memberId,
  monthlyAmount,
  prefill,
}: {
  memberId: string;
  monthlyAmount: number;
  prefill?: DepositPrefill;
}) {
  const { t, lang } = useI18n();
  const router = useRouter();

  const [amount, setAmount] = useState(String(prefill?.amount ?? monthlyAmount));
  const [month, setMonth] = useState(prefill?.periodMonth ?? currentMonthDhaka());
  const [kind, setKind] = useState<DepositKind>(prefill?.kind ?? "monthly");
  const [method, setMethod] = useState<PayMethod>(prefill?.method ?? "bkash");
  const [txn, setTxn] = useState("");
  const [note, setNote] = useState("");
  const [file, setFile] = useState<{ name: string; prepared: PreparedFile } | null>(null);
  const [fileError, setFileError] = useState<string | null>(null);
  const [fileKey, setFileKey] = useState(0);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<Msg>(null);
  // A receipt that was uploaded but whose deposit failed to save: reused on retry (no orphan files).
  const uploaded = useRef<{ prepared: PreparedFile; path: string } | null>(null);

  const months = monthOptions(12, 6);
  if (!months.includes(month)) months.push(month);
  const needsProof = method !== "cash";
  const fail = (text: string) => setMsg({ tone: "error", text });

  async function onPickFile(input: HTMLInputElement) {
    const picked = input.files?.[0];
    input.value = "";
    if (!picked) return;
    setFileError(null);
    const res = await prepareFile("receipt", picked);
    if (!res.ok) {
      setFile(null);
      setFileError(t.errors[res.error]);
      return;
    }
    uploaded.current = null;
    setFile({ name: picked.name, prepared: res.file });
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    setMsg(null);
    // Clear the "submitted" banner left from the previous deposit.
    if (window.location.search.includes("sent=")) router.replace("/deposits");

    const value = parseAmount(amount);
    if (value === null || value <= 0) return fail(t.deposits.errAmount);
    if (!month) return fail(t.deposits.errMonth);
    const txnId = txn.trim();
    if (needsProof && !txnId) return fail(t.deposits.errTxnMissing);
    if (needsProof && !file) return fail(t.deposits.errReceiptMissing);

    setBusy(true);
    const supabase = createClient();

    let receiptPath: string | null = null;
    if (file) {
      if (uploaded.current?.prepared === file.prepared) {
        receiptPath = uploaded.current.path;
      } else {
        const path = `${memberId}/${randomName()}.${file.prepared.ext}`;
        const { error } = await supabase.storage
          .from("receipts")
          .upload(path, file.prepared.blob, { contentType: file.prepared.contentType, upsert: false });
        if (error) {
          setBusy(false);
          return fail(t.errors.uploadFailed);
        }
        uploaded.current = { prepared: file.prepared, path };
        receiptPath = path;
      }
    }

    const { error } = await supabase.from("deposits").insert({
      member_id: memberId,
      period_month: month,
      kind,
      amount: value,
      method,
      transaction_ref: txnId || null,
      receipt_path: receiptPath,
      note: note.trim() || null,
      status: "pending",
    });
    setBusy(false);
    if (error) return fail(t.deposits[depositErrorKey(error)]);

    // Saved: clear the form for the next deposit.
    uploaded.current = null;
    setFile(null);
    setFileKey((k) => k + 1);
    setTxn("");
    setNote("");
    setAmount(String(monthlyAmount));
    router.replace("/deposits?sent=1");
    router.refresh();
  }

  return (
    <Card className="space-y-5">
      <h2 className="text-lg font-bold">{t.deposits.newTitle}</h2>
      {prefill && <Alert tone="success">{t.deposits.resubmitBanner}</Alert>}

      <form onSubmit={onSubmit} className="space-y-4" noValidate>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field
            id="amount"
            label={t.deposits.amount}
            inputMode="decimal"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            autoComplete="off"
          />
          <Select id="month" label={t.deposits.month} value={month} onChange={(e) => setMonth(e.target.value)}>
            {months.map((m) => (
              <option key={m} value={m}>
                {formatMonth(m, lang)}
              </option>
            ))}
          </Select>
          <Select id="kind" label={t.deposits.kind} value={kind} onChange={(e) => setKind(e.target.value as DepositKind)}>
            {MEMBER_KINDS.map((k) => (
              <option key={k} value={k}>
                {t.deposits[`kind_${k}`]}
              </option>
            ))}
          </Select>
          <Select id="method" label={t.deposits.method} value={method} onChange={(e) => setMethod(e.target.value as PayMethod)}>
            {METHODS.map((m) => (
              <option key={m} value={m}>
                {t.deposits[`method_${m}`]}
              </option>
            ))}
          </Select>
        </div>

        <Field
          id="txn"
          label={t.deposits.txnId}
          hint={needsProof ? t.deposits.txnIdHint : t.deposits.optional}
          value={txn}
          onChange={(e) => setTxn(e.target.value)}
          autoComplete="off"
          maxLength={100}
        />

        <div className="space-y-1.5">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-sm font-medium">{t.deposits.receipt}</span>
            {!needsProof && <Chip>{t.deposits.optional}</Chip>}
          </div>
          <label
            htmlFor="receipt"
            className="flex h-11 cursor-pointer items-center justify-center rounded-full border border-border bg-surface px-4 text-sm font-semibold transition hover:bg-accent-soft"
          >
            {file ? t.deposits.changeFile : t.deposits.chooseFile}
          </label>
          <input
            key={fileKey}
            id="receipt"
            type="file"
            accept={acceptFor("receipt")}
            className="sr-only"
            onChange={(e) => onPickFile(e.currentTarget)}
          />
          {file && (
            <p className="truncate text-xs text-accent">
              {t.deposits.receiptChosen}: {file.name}
            </p>
          )}
          {fileError && <p className="text-xs text-danger">{fileError}</p>}
          <p className="text-xs text-muted">{t.deposits.receiptHint}</p>
        </div>

        <TextArea
          id="note"
          label={t.deposits.note}
          hint={t.deposits.noteHint}
          value={note}
          maxLength={500}
          onChange={(e) => setNote(e.target.value)}
        />

        {msg && <Alert tone={msg.tone}>{msg.text}</Alert>}
        <Button type="submit" disabled={busy} className="w-full sm:w-auto sm:min-w-44">
          {busy ? t.deposits.submitting : t.deposits.submit}
        </Button>
      </form>
    </Card>
  );
}
