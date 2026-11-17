"use client";

import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";
import { movePolicy, postNotice, savePolicy, saveSiteText, setNoticePinned, setPolicyHidden } from "@/app/actions/content";
import type { Notice, Policy } from "@/lib/content";
import { formatDay } from "@/lib/format";
import { useI18n } from "./I18nProvider";
import { Alert, Button, Card, Chip, Field, TextArea } from "./ui";

type Msg = { tone: "error" | "success"; text: string } | null;

/** Add a new policy, or edit an existing one (pass `policy`). Super admin only (also checked on the server). */
export function PolicyEditor({ policy, today, onDone }: { policy?: Policy; today: string; onDone?: () => void }) {
  const { t } = useI18n();
  const router = useRouter();
  const [f, setF] = useState({ title: policy?.title ?? "", body: policy?.body ?? "", effectiveFrom: policy?.effectiveFrom ?? today });
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<Msg>(null);
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((s) => ({ ...s, [k]: e.target.value }));

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setMsg(null);
    const res = await savePolicy({ id: policy?.id, ...f });
    setBusy(false);
    if (!res.ok) return setMsg({ tone: "error", text: res.message });
    if (!policy) setF({ title: "", body: "", effectiveFrom: today });
    setMsg({ tone: "success", text: t.content.saved });
    router.refresh();
    onDone?.();
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <Field id={`pt-${policy?.id ?? "new"}`} label={t.content.policyTitle} value={f.title} onChange={set("title")} maxLength={200} />
      <TextArea id={`pb-${policy?.id ?? "new"}`} label={t.content.policyBody} value={f.body} onChange={set("body")} rows={8} maxLength={5000} />
      <Field id={`pe-${policy?.id ?? "new"}`} type="date" label={t.content.effectiveFrom} value={f.effectiveFrom} onChange={set("effectiveFrom")} />
      {msg && <Alert tone={msg.tone}>{msg.text}</Alert>}
      <Button type="submit" disabled={busy} className="w-full sm:w-auto sm:min-w-40">
        {busy ? t.content.working : policy ? t.content.save : t.content.addPolicy}
      </Button>
    </form>
  );
}

/** One policy row in the admin list: move up / down, hide / show, edit. Never a delete button. */
export function PolicyAdminRow({ policy, number, first, last, today, lang }: { policy: Policy; number: number; first: boolean; last: boolean; today: string; lang: "en" | "bn" }) {
  const { t } = useI18n();
  const router = useRouter();
  const [editing, setEditing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<Msg>(null);

  async function run(fn: () => Promise<{ ok: true } | { ok: false; message: string }>, done: string) {
    setBusy(true);
    setMsg(null);
    const res = await fn();
    setBusy(false);
    if (!res.ok) return setMsg({ tone: "error", text: res.message });
    setMsg({ tone: "success", text: done });
    router.refresh();
  }

  return (
    <Card className="space-y-3 p-4 sm:p-5">
      <div className="flex items-start gap-3">
        <span className="mt-0.5 grid size-8 shrink-0 place-items-center rounded-full bg-accent-soft text-sm font-bold text-accent">{number}</span>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-1.5">
            <h3 className="font-bold leading-snug">{policy.title}</h3>
            {!policy.visible && <Chip tone="gold">{t.content.hiddenChip}</Chip>}
          </div>
          <p className="text-xs text-muted">
            {t.content.effectiveFrom} {formatDay(policy.effectiveFrom, lang)}
          </p>
        </div>
      </div>
      {!editing && <p className="line-clamp-3 whitespace-pre-line text-sm text-muted">{policy.body}</p>}
      {msg && <Alert tone={msg.tone}>{msg.text}</Alert>}
      {editing ? (
        <div className="space-y-3">
          <PolicyEditor policy={policy} today={today} onDone={() => setEditing(false)} />
          <Button type="button" variant="ghost" onClick={() => setEditing(false)} className="h-9 px-3">
            {t.content.cancel}
          </Button>
        </div>
      ) : (
        <div className="flex flex-wrap gap-2">
          <Button type="button" variant="secondary" disabled={busy} onClick={() => setEditing(true)} className="h-9 px-4">
            {t.content.edit}
          </Button>
          <Button type="button" variant="secondary" disabled={busy || first} onClick={() => run(() => movePolicy(policy.id, "up"), t.content.moved)} className="h-9 px-4" aria-label={t.content.moveUp}>
            ↑
          </Button>
          <Button type="button" variant="secondary" disabled={busy || last} onClick={() => run(() => movePolicy(policy.id, "down"), t.content.moved)} className="h-9 px-4" aria-label={t.content.moveDown}>
            ↓
          </Button>
          <Button
            type="button"
            variant="secondary"
            disabled={busy}
            onClick={() => run(() => setPolicyHidden(policy.id, policy.visible), policy.visible ? t.content.hiddenDone : t.content.shownDone)}
            className="h-9 px-4"
          >
            {policy.visible ? t.content.hide : t.content.show}
          </Button>
        </div>
      )}
    </Card>
  );
}

export function NoticeForm() {
  const { t } = useI18n();
  const router = useRouter();
  const [f, setF] = useState({ title: "", body: "", pinned: false });
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<Msg>(null);
  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setMsg(null);
    const res = await postNotice(f);
    setBusy(false);
    if (!res.ok) return setMsg({ tone: "error", text: res.message });
    setF({ title: "", body: "", pinned: false });
    setMsg({ tone: "success", text: t.content.noticePosted });
    router.refresh();
  }
  return (
    <Card className="space-y-4">
      <h2 className="text-lg font-bold">{t.content.postNotice}</h2>
      <form onSubmit={onSubmit} className="space-y-4" noValidate>
        <Field id="n-title" label={t.content.noticeTitle} value={f.title} onChange={(e) => setF((s) => ({ ...s, title: e.target.value }))} maxLength={200} />
        <TextArea id="n-body" label={t.content.noticeBody} value={f.body} onChange={(e) => setF((s) => ({ ...s, body: e.target.value }))} rows={6} maxLength={5000} />
        <label htmlFor="n-pinned" className="flex cursor-pointer items-start gap-3 rounded-xl border border-border px-4 py-3">
          <input
            id="n-pinned"
            type="checkbox"
            checked={f.pinned}
            onChange={(e) => setF((s) => ({ ...s, pinned: e.target.checked }))}
            className="mt-1 size-4 accent-[var(--color-accent)]"
          />
          <span>
            <span className="block text-sm font-semibold">{t.content.pinNotice}</span>
            <span className="block text-xs text-muted">{t.content.pinHint}</span>
          </span>
        </label>
        {msg && <Alert tone={msg.tone}>{msg.text}</Alert>}
        <Button type="submit" disabled={busy} className="w-full sm:w-auto sm:min-w-40">
          {busy ? t.content.working : t.content.postNotice}
        </Button>
      </form>
    </Card>
  );
}

/** One notice in the admin list, with a pin / unpin button (any admin). */
export function NoticeAdminRow({ notice, when }: { notice: Notice; when: string }) {
  const { t } = useI18n();
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<Msg>(null);
  async function toggle() {
    if (busy) return;
    setBusy(true);
    setMsg(null);
    const res = await setNoticePinned(notice.id, !notice.pinned);
    setBusy(false);
    if (!res.ok) return setMsg({ tone: "error", text: res.message });
    router.refresh();
  }
  return (
    <Card className="space-y-2 p-4 sm:p-5">
      <div className="flex flex-wrap items-center gap-2">
        <p className="min-w-0 flex-1 break-words font-bold">{notice.title}</p>
        {notice.pinned && <Chip tone="gold">{t.content.pinnedChip}</Chip>}
      </div>
      <p className="text-xs text-muted">{when}</p>
      <p className="line-clamp-3 whitespace-pre-line break-words text-sm text-muted">{notice.body}</p>
      {msg && <Alert tone={msg.tone}>{msg.text}</Alert>}
      <Button type="button" variant="secondary" disabled={busy} onClick={toggle} className="w-full sm:w-auto">
        {busy ? t.content.working : notice.pinned ? t.content.unpin : t.content.pin}
      </Button>
    </Card>
  );
}

/** One text of the public / about pages, in English and Bengali. */
export function SiteTextForm({ keyName, label, hint, en, bn, multiline }: { keyName: string; label: string; hint?: string; en: string; bn: string; multiline?: boolean }) {
  const { t } = useI18n();
  const router = useRouter();
  const [v, setV] = useState({ en, bn });
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<Msg>(null);
  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setMsg(null);
    const res = await saveSiteText(keyName, v.en, v.bn);
    setBusy(false);
    if (!res.ok) return setMsg({ tone: "error", text: res.message });
    setMsg({ tone: "success", text: t.content.saved });
    router.refresh();
  }
  return (
    <Card className="space-y-4 p-5 sm:p-6">
      <div>
        <h2 className="text-lg font-bold">{label}</h2>
        {hint && <p className="mt-0.5 text-sm text-muted">{hint}</p>}
      </div>
      <form onSubmit={onSubmit} className="space-y-4" noValidate>
        {multiline ? (
          <>
            <TextArea id={`${keyName}-en`} label={t.content.textEnglish} value={v.en} onChange={(e) => setV((s) => ({ ...s, en: e.target.value }))} maxLength={1500} />
            <TextArea id={`${keyName}-bn`} label={t.content.textBengali} value={v.bn} onChange={(e) => setV((s) => ({ ...s, bn: e.target.value }))} maxLength={1500} lang="bn" />
          </>
        ) : (
          <>
            <Field id={`${keyName}-en`} label={t.content.textEnglish} value={v.en} onChange={(e) => setV((s) => ({ ...s, en: e.target.value }))} maxLength={300} />
            <Field id={`${keyName}-bn`} label={t.content.textBengali} value={v.bn} onChange={(e) => setV((s) => ({ ...s, bn: e.target.value }))} maxLength={300} lang="bn" />
          </>
        )}
        {msg && <Alert tone={msg.tone}>{msg.text}</Alert>}
        <Button type="submit" disabled={busy} className="w-full sm:w-auto sm:min-w-40">
          {busy ? t.content.working : t.content.save}
        </Button>
      </form>
    </Card>
  );
}
