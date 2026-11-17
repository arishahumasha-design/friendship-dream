"use client";

import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";
import { proposeExpense, proposeExpenseReversal } from "@/app/actions/money";
import { newRequestId } from "@/lib/deposits";
import { createClient } from "@/lib/supabase/client";
import { acceptFor, prepareFile, type PreparedFile } from "@/lib/upload";
import { useI18n } from "./I18nProvider";
import { Alert, Button, Card, Field, Select, TextArea } from "./ui";

type Option = { id: string; name: string };

/** Propose an expense (general, or for one investment). Another admin approves it. */
export function ExpenseForm({
  adminId,
  today,
  categories,
  investments,
}: {
  adminId: string;
  today: string;
  categories: { id: number; name: string }[];
  investments: Option[];
}) {
  const { t } = useI18n();
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ tone: "error" | "success"; text: string } | null>(null);
  const [f, setF] = useState({ title: "", amount: "", date: today, category: "", investment: "", description: "", spentBy: "" });
  const [file, setFile] = useState<{ name: string; prepared: PreparedFile } | null>(null);
  const [fileKey, setFileKey] = useState(0);
  const [fileError, setFileError] = useState<string | null>(null);
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((s) => ({ ...s, [k]: e.target.value }));

  async function onPick(input: HTMLInputElement) {
    const picked = input.files?.[0];
    input.value = "";
    if (!picked) return;
    setFileError(null);
    const res = await prepareFile("receipt", picked);
    if (!res.ok) {
      setFile(null);
      return setFileError(t.errors[res.error]);
    }
    setFile({ name: picked.name, prepared: res.file });
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    setMsg(null);
    setBusy(true);
    let receiptPath = "";
    if (file) {
      // private 'receipts' bucket, your own folder, a fresh random name every time
      receiptPath = `${adminId}/${newRequestId()}.${file.prepared.ext}`;
      const { error } = await createClient()
        .storage.from("receipts")
        .upload(receiptPath, file.prepared.blob, { contentType: file.prepared.contentType, upsert: false });
      if (error) {
        setBusy(false);
        return setMsg({ tone: "error", text: t.errors.uploadFailed });
      }
    }
    const res = await proposeExpense({
      title: f.title,
      amount: f.amount,
      date: f.date,
      categoryId: f.category,
      investmentId: f.investment,
      description: f.description,
      spentBy: f.spentBy,
      receiptPath,
    });
    setBusy(false);
    if (!res.ok) return setMsg({ tone: "error", text: res.message });
    setF({ title: "", amount: "", date: today, category: "", investment: "", description: "", spentBy: "" });
    setFile(null);
    setFileKey((k) => k + 1);
    setMsg({ tone: "success", text: t.money.expenseSent });
    router.refresh();
  }

  if (!open) {
    return (
      <Button type="button" onClick={() => setOpen(true)}>
        {t.money.newExpense}
      </Button>
    );
  }
  return (
    <Card className="space-y-4">
      <div className="flex items-start justify-between gap-3">
        <h2 className="text-lg font-bold">{t.money.newExpense}</h2>
        <Button type="button" variant="ghost" onClick={() => setOpen(false)} className="h-9 px-3">
          {t.money.cancel}
        </Button>
      </div>
      <form onSubmit={onSubmit} className="space-y-4" noValidate>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field id="e-title" label={t.money.expenseTitleLabel} value={f.title} onChange={set("title")} maxLength={200} />
          <Field id="e-amount" label={t.money.expenseAmount} inputMode="decimal" value={f.amount} onChange={set("amount")} autoComplete="off" />
          <Field id="e-date" type="date" label={t.money.expenseDate} value={f.date} onChange={set("date")} />
          <Select id="e-cat" label={t.money.expenseCategory} value={f.category} onChange={set("category")}>
            <option value="">{t.money.noCategory}</option>
            {categories.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </Select>
        </div>
        <Select
          id="e-inv"
          label={t.money.expenseFor}
          hint={f.investment ? t.money.splitInvestment : t.money.splitGeneral}
          value={f.investment}
          onChange={set("investment")}
        >
          <option value="">{t.money.expenseGeneral}</option>
          {investments.map((i) => (
            <option key={i.id} value={i.id}>
              {i.name}
            </option>
          ))}
        </Select>
        <Field id="e-by" label={t.money.spentBy} hint={t.money.optional} value={f.spentBy} onChange={set("spentBy")} maxLength={200} />
        <TextArea id="e-desc" label={t.money.expenseDescription} hint={t.money.optional} value={f.description} maxLength={1000} onChange={set("description")} />
        <div className="space-y-1.5">
          <span className="text-sm font-medium">{t.money.receiptLabel}</span>
          <label htmlFor="e-receipt" className="flex h-11 cursor-pointer items-center justify-center rounded-full border border-border bg-surface px-4 text-sm font-semibold transition hover:bg-accent-soft">
            {file ? t.money.changeFile : t.money.chooseFile}
          </label>
          <input key={fileKey} id="e-receipt" type="file" accept={acceptFor("receipt")} className="sr-only" onChange={(e) => onPick(e.currentTarget)} />
          {file && <p className="truncate text-xs text-accent">{file.name}</p>}
          {fileError && <p className="text-xs text-danger">{fileError}</p>}
          <p className="text-xs text-muted">
            {t.money.optional}. {t.money.receiptHint}
          </p>
        </div>
        {msg && <Alert tone={msg.tone}>{msg.text}</Alert>}
        <Button type="submit" disabled={busy} className="w-full sm:w-auto sm:min-w-44">
          {busy ? t.money.working : t.money.submitExpense}
        </Button>
      </form>
    </Card>
  );
}

/** Reverse an approved expense: a reason, then a second admin approves the reversal. */
export function ReverseExpense({ expenseId }: { expenseId: string }) {
  const { t } = useI18n();
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ tone: "error" | "success"; text: string } | null>(null);

  async function send() {
    setBusy(true);
    const res = await proposeExpenseReversal(expenseId, reason);
    setBusy(false);
    if (!res.ok) return setMsg({ tone: "error", text: res.message });
    setOpen(false);
    setReason("");
    setMsg({ tone: "success", text: t.money.reversalSent });
    router.refresh();
  }

  if (!open) {
    return (
      <div className="space-y-2">
        {msg && <Alert tone={msg.tone}>{msg.text}</Alert>}
        <Button type="button" variant="secondary" onClick={() => setOpen(true)} className="h-9 px-4">
          {t.money.reverse}
        </Button>
      </div>
    );
  }
  return (
    <div className="space-y-2">
      {msg && <Alert tone={msg.tone}>{msg.text}</Alert>}
      <TextArea id={`rev-${expenseId}`} label={t.money.reverseReasonLabel} placeholder={t.money.reversePlaceholder} value={reason} maxLength={500} onChange={(e) => setReason(e.target.value)} />
      <div className="flex gap-2">
        <Button type="button" disabled={busy || !reason.trim()} onClick={send} className="h-10">
          {busy ? t.money.working : t.money.confirmReverse}
        </Button>
        <Button type="button" variant="secondary" disabled={busy} onClick={() => setOpen(false)} className="h-10">
          {t.money.cancel}
        </Button>
      </div>
    </div>
  );
}
