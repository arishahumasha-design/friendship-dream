"use client";

import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";
import { saveSettings, type SettingsResult } from "@/app/actions/settings";
import { formatTaka } from "@/lib/format";
import type { AppSettings } from "@/lib/settings";
import { useI18n } from "./I18nProvider";
import { Alert, Button, Card, Field, cn } from "./ui";

export function SettingsForm({ initial }: { initial: AppSettings }) {
  const { t } = useI18n();
  const router = useRouter();
  const [values, setValues] = useState({
    monthlyAmount: String(initial.monthlyAmount),
    yearlySaving: String(initial.yearlySaving),
    lateFee: String(initial.lateFee),
    shareValue: String(initial.shareValue),
  });
  const [seeOthers, setSeeOthers] = useState(initial.membersCanSeeOthers);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<SettingsResult | null>(null);

  const set = (k: keyof typeof values) => (e: { target: { value: string } }) =>
    setValues((v) => ({ ...v, [k]: e.target.value }));

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setResult(null);
    const res = await saveSettings({ ...values, membersCanSeeOthers: seeOthers });
    setBusy(false);
    setResult(res);
    if (res.ok) router.refresh();
  }

  const errorText = (r: Extract<SettingsResult, { ok: false }>) =>
    r.error in t.settings
      ? t.settings[r.error as keyof typeof t.settings]
      : t.deposits[r.error as keyof typeof t.deposits];
  const bad = (field: keyof AppSettings) => result && !result.ok && result.field === field;
  const num = (v: string) => (Number.isFinite(Number(v)) ? formatTaka(Number(v)) : "");

  return (
    <Card className="space-y-5">
      <form onSubmit={onSubmit} className="space-y-5" noValidate>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field
            id="monthlyAmount"
            label={t.settings.monthlyAmount}
            hint={t.settings.monthlyAmountHint}
            inputMode="decimal"
            value={values.monthlyAmount}
            onChange={set("monthlyAmount")}
            aria-invalid={bad("monthlyAmount") || undefined}
            autoComplete="off"
          />
          <Field
            id="shareValue"
            label={t.settings.shareValue}
            hint={t.settings.shareValueHint}
            inputMode="decimal"
            value={values.shareValue}
            onChange={set("shareValue")}
            aria-invalid={bad("shareValue") || undefined}
            autoComplete="off"
          />
          <Field
            id="yearlySaving"
            label={t.settings.yearlySaving}
            hint={t.settings.yearlySavingHint}
            inputMode="decimal"
            value={values.yearlySaving}
            onChange={set("yearlySaving")}
            aria-invalid={bad("yearlySaving") || undefined}
            autoComplete="off"
          />
          <Field
            id="lateFee"
            label={t.settings.lateFee}
            hint={t.settings.lateFeeHint}
            inputMode="decimal"
            value={values.lateFee}
            onChange={set("lateFee")}
            aria-invalid={bad("lateFee") || undefined}
            autoComplete="off"
          />
        </div>
        <p className="text-xs text-muted">
          {num(values.monthlyAmount)} · {num(values.shareValue)}
        </p>

        <fieldset className="space-y-2">
          <legend className="text-sm font-medium">{t.settings.membersSee}</legend>
          <div role="radiogroup" className="inline-flex rounded-full border border-border bg-surface p-1">
            {[
              { on: true, label: t.settings.on },
              { on: false, label: t.settings.off },
            ].map((o) => (
              <button
                key={String(o.on)}
                type="button"
                role="radio"
                aria-checked={seeOthers === o.on}
                onClick={() => setSeeOthers(o.on)}
                className={cn(
                  "h-9 min-w-20 rounded-full px-4 text-sm font-semibold transition",
                  seeOthers === o.on ? "bg-accent text-accent-fg" : "hover:bg-accent-soft",
                )}
              >
                {o.label}
              </button>
            ))}
          </div>
          <p className="text-xs text-muted">{t.settings.membersSeeHint}</p>
        </fieldset>

        {result?.ok && (
          <Alert tone="success">{result.changed ? t.settings.saved : t.settings.nothingChanged}</Alert>
        )}
        {result && !result.ok && <Alert>{errorText(result)}</Alert>}

        <Button type="submit" disabled={busy} className="w-full sm:w-auto sm:min-w-44">
          {busy ? t.settings.saving : t.settings.save}
        </Button>
      </form>
    </Card>
  );
}
