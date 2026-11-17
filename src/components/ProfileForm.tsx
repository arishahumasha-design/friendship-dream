"use client";

import { useRouter } from "next/navigation";
import { useId, useState, type FormEvent } from "react";
import type { ErrorKey } from "@/lib/i18n/types";
import {
  PDF_SLOTS,
  todayInDhaka,
  type FileSlot,
  type MemberRecord,
  type MissingItem,
  type Nominee,
} from "@/lib/members";
import { createClient } from "@/lib/supabase/client";
import { acceptFor, prepareFile } from "@/lib/upload";
import { FileThumb } from "./FileThumb";
import { useI18n } from "./I18nProvider";
import { Alert, Button, Card, Chip, Field, TextArea } from "./ui";

const PHONE_RE = /^01[3-9]\d{8}$/;
const NID_RE = /^(\d{10}|\d{13}|\d{17})$/;

/** "+880 1712-345678" → "01712345678" */
function normalizePhone(v: string) {
  const digits = v.replace(/[^\d]/g, "");
  return digits.startsWith("880") ? digits.slice(2) : digits;
}

/** Unique file path inside the member's own folder: <user-id>/<slot>-<time>.<ext> */
function storagePath(uid: string, slot: FileSlot, ext: string) {
  return `${uid}/${slot}-${Date.now()}.${ext}`;
}

type Personal = {
  fullName: string;
  fullNameBn: string;
  fatherName: string;
  motherName: string;
  dob: string;
  phone: string;
  addressPresent: string;
  addressPermanent: string;
};

type SlotState = { busy?: boolean; error?: ErrorKey; done?: boolean; localUrl?: string | null };

const MEMBER_SLOTS: FileSlot[] = ["photo", "nid_front", "nid_back", "signature", "passport"];
const NOMINEE_SLOTS: FileSlot[] = ["nominee_photo", "nominee_nid"];

export function ProfileForm({ record, mode }: { record: MemberRecord; mode: "complete" | "edit" }) {
  const { t } = useI18n();
  const router = useRouter();
  const uid = record.profile.id;
  const formId = useId();

  const [personal, setPersonal] = useState<Personal>({
    fullName: record.profile.fullName,
    fullNameBn: record.profile.fullNameBn,
    fatherName: record.profile.fatherName,
    motherName: record.profile.motherName,
    dob: record.profile.dob,
    phone: record.profile.phone,
    addressPresent: record.profile.addressPresent,
    addressPermanent: record.profile.addressPermanent,
  });
  const [nominee, setNominee] = useState<Nominee>(
    record.nominee ?? { name: "", relation: "", phone: "", address: "", nidNumber: "" },
  );
  const [sameAddress, setSameAddress] = useState(
    !!record.profile.addressPresent && record.profile.addressPresent === record.profile.addressPermanent,
  );
  const [saving, setSaving] = useState(false);
  const [result, setResult] = useState<{ ok: true } | { ok: false; error: ErrorKey } | null>(null);
  const [slots, setSlots] = useState<Partial<Record<FileSlot, SlotState>>>({});

  const setP = (k: keyof Personal) => (e: { target: { value: string } }) =>
    setPersonal((s) => ({ ...s, [k]: e.target.value }));
  const setN = (k: keyof Nominee) => (e: { target: { value: string } }) =>
    setNominee((s) => ({ ...s, [k]: e.target.value }));

  async function onSave(e: FormEvent) {
    e.preventDefault();
    setResult(null);

    const phone = normalizePhone(personal.phone);
    const nomineePhone = normalizePhone(nominee.phone);
    const nid = nominee.nidNumber.replace(/\s/g, "");
    const today = todayInDhaka();
    if (phone && !PHONE_RE.test(phone)) return setResult({ ok: false, error: "phoneInvalid" });
    if (nomineePhone && !PHONE_RE.test(nomineePhone)) return setResult({ ok: false, error: "phoneInvalid" });
    if (nid && !NID_RE.test(nid)) return setResult({ ok: false, error: "nidInvalid" });
    if (personal.dob && (personal.dob > today || personal.dob < "1900-01-01")) {
      return setResult({ ok: false, error: "dobInvalid" });
    }

    const clean = (v: string) => v.trim() || null;
    setSaving(true);
    const supabase = createClient();

    // role, status, joined_on are never sent; the database trigger blocks them anyway.
    const { data: saved, error } = await supabase
      .from("profiles")
      .update({
        full_name: personal.fullName.trim(),
        full_name_bn: clean(personal.fullNameBn),
        father_name: clean(personal.fatherName),
        mother_name: clean(personal.motherName),
        dob: personal.dob || null,
        phone: phone || null,
        address_present: clean(personal.addressPresent),
        address_permanent: clean(sameAddress ? personal.addressPresent : personal.addressPermanent),
      })
      .eq("id", uid)
      .select("id");

    let ok = !error && !!saved?.length;
    const anyNominee = Object.values(nominee).some((v) => v.trim());
    if (ok && (anyNominee || record.nominee)) {
      const { error: nErr } = await supabase.from("nominees").upsert(
        {
          member_id: uid,
          name: nominee.name.trim(),
          relation: clean(nominee.relation),
          phone: nomineePhone || null,
          address: clean(nominee.address),
          nid_number: nid || null,
        },
        { onConflict: "member_id" },
      );
      ok = !nErr;
    }
    setSaving(false);

    if (!ok) return setResult({ ok: false, error: "saveFailed" });
    setPersonal((s) => ({ ...s, phone, addressPermanent: sameAddress ? s.addressPresent : s.addressPermanent }));
    setNominee((s) => ({ ...s, phone: nomineePhone, nidNumber: nid }));
    setResult({ ok: true });
    router.refresh();
  }

  async function onPick(slot: FileSlot, input: HTMLInputElement) {
    const picked = input.files?.[0];
    input.value = "";
    if (!picked) return;

    setSlots((s) => ({ ...s, [slot]: { ...s[slot], busy: true, error: undefined, done: false } }));
    const prepared = await prepareFile(slot, picked);
    if (!prepared.ok) {
      setSlots((s) => ({ ...s, [slot]: { ...s[slot], busy: false, error: prepared.error } }));
      return;
    }
    const { blob, contentType, ext } = prepared.file;
    const supabase = createClient();
    const bucket = slot === "photo" ? "avatars" : "documents";
    // Path MUST start with the user id (storage policy).
    const path = storagePath(uid, slot, ext);

    const { error: upErr } = await supabase.storage
      .from(bucket)
      .upload(path, blob, { contentType, upsert: false });

    let error = !!upErr;
    if (!error) {
      if (slot === "photo") {
        const { data, error: e } = await supabase
          .from("profiles")
          .update({ photo_path: path })
          .eq("id", uid)
          .select("id");
        error = !!e || !data?.length;
      } else {
        const { error: e } = await supabase
          .from("member_documents")
          .insert({ member_id: uid, kind: slot, storage_path: path });
        error = !!e;
      }
    }

    if (error) {
      setSlots((s) => ({ ...s, [slot]: { ...s[slot], busy: false, error: "uploadFailed" } }));
      return;
    }
    const localUrl = contentType === "application/pdf" ? null : URL.createObjectURL(blob);
    setSlots((s) => {
      const old = s[slot]?.localUrl;
      if (old) URL.revokeObjectURL(old);
      return { ...s, [slot]: { busy: false, done: true, localUrl } };
    });
    router.refresh();
  }

  function renderSlot(slot: FileSlot) {
    const state = slots[slot] ?? {};
    const file = record.files[slot] ?? null;
    const has = !!file || state.done;
    const inputId = `${formId}-${slot}`;
    const showLocal = state.localUrl !== undefined;
    return (
      <div key={slot} className="space-y-2">
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="text-sm font-medium">{t.files[slot]}</span>
          {slot === "passport" && <Chip>{t.profile.optional}</Chip>}
          {PDF_SLOTS.includes(slot) && <Chip tone="accent">{t.profile.pdfAllowed}</Chip>}
        </div>
        <FileThumb
          memberId={uid}
          file={showLocal && state.localUrl === null && file && !file.isPdf ? { ...file, isPdf: true, url: null } : file}
          localUrl={showLocal ? state.localUrl : undefined}
          label={t.files[slot]}
        />
        <label
          htmlFor={inputId}
          aria-disabled={state.busy}
          className="flex h-10 cursor-pointer items-center justify-center rounded-full border border-border bg-surface px-4 text-sm font-semibold transition hover:bg-accent-soft aria-disabled:pointer-events-none aria-disabled:opacity-60"
        >
          {state.busy ? t.profile.uploading : has ? t.profile.replace : t.profile.upload}
        </label>
        <input
          id={inputId}
          type="file"
          accept={acceptFor(slot)}
          className="sr-only"
          disabled={state.busy}
          onChange={(e) => onPick(slot, e.currentTarget)}
        />
        {state.error && <p className="text-xs text-danger">{t.errors[state.error]}</p>}
        {state.done && !state.error && <p className="text-xs text-accent">{t.profile.uploaded}</p>}
      </div>
    );
  }

  const today = todayInDhaka();

  return (
    <div className="space-y-6">
      {record.profile.reviewNote && record.profile.status === "pending" && (
        <div className="rounded-3xl border border-gold/50 bg-gold/10 p-5">
          <p className="text-sm font-semibold">{t.profile.adminNoteTitle}</p>
          <p className="mt-1 whitespace-pre-line text-sm">{record.profile.reviewNote}</p>
        </div>
      )}

      {mode === "complete" && <Checklist missing={record.missing} />}

      <form onSubmit={onSave} className="space-y-6" noValidate>
        <Card className="space-y-5">
          <h2 className="text-lg font-bold">{t.profile.sectionPersonal}</h2>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field id="fullName" label={t.profile.fullNameEn} value={personal.fullName} onChange={setP("fullName")} autoComplete="name" lang="en" />
            <Field id="fullNameBn" label={t.profile.fullNameBn} value={personal.fullNameBn} onChange={setP("fullNameBn")} lang="bn" />
            <Field id="fatherName" label={t.profile.fatherName} value={personal.fatherName} onChange={setP("fatherName")} />
            <Field id="motherName" label={t.profile.motherName} value={personal.motherName} onChange={setP("motherName")} />
            <Field id="dob" type="date" label={t.profile.dob} value={personal.dob} onChange={setP("dob")} max={today} min="1900-01-01" />
            <Field id="phone" type="tel" inputMode="tel" label={t.profile.phone} hint={t.profile.phoneHint} value={personal.phone} onChange={setP("phone")} autoComplete="tel" />
          </div>
          <TextArea id="addressPresent" label={t.profile.addressPresent} value={personal.addressPresent} onChange={setP("addressPresent")} />
          <label className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={sameAddress}
              onChange={(e) => setSameAddress(e.target.checked)}
              className="size-4 accent-[var(--accent)]"
            />
            {t.profile.sameAsPresent}
          </label>
          {!sameAddress && (
            <TextArea id="addressPermanent" label={t.profile.addressPermanent} value={personal.addressPermanent} onChange={setP("addressPermanent")} />
          )}
        </Card>

        <Card className="space-y-5">
          <h2 className="text-lg font-bold">{t.profile.sectionNominee}</h2>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field id="nomineeName" label={t.profile.nomineeName} value={nominee.name} onChange={setN("name")} />
            <Field id="nomineeRelation" label={t.profile.nomineeRelation} hint={t.profile.nomineeRelationHint} value={nominee.relation} onChange={setN("relation")} />
            <Field id="nomineePhone" type="tel" inputMode="tel" label={t.profile.nomineePhone} hint={t.profile.phoneHint} value={nominee.phone} onChange={setN("phone")} />
            <Field id="nomineeNid" inputMode="numeric" label={t.profile.nomineeNid} hint={t.profile.nomineeNidHint} value={nominee.nidNumber} onChange={setN("nidNumber")} autoComplete="off" />
          </div>
          <TextArea id="nomineeAddress" label={t.profile.nomineeAddress} value={nominee.address} onChange={setN("address")} />
        </Card>

        <div className="sticky bottom-3 z-10 flex flex-col gap-2 rounded-3xl border border-border bg-surface-strong/90 p-3 shadow-lg backdrop-blur sm:flex-row sm:items-center sm:justify-between">
          <div className="min-h-5 px-2 text-sm" aria-live="polite">
            {result?.ok && <span className="font-medium text-accent">{t.profile.saved}</span>}
            {result && !result.ok && <span className="font-medium text-danger">{t.errors[result.error]}</span>}
          </div>
          <Button type="submit" disabled={saving} className="sm:min-w-40">
            {saving ? t.profile.saving : t.profile.save}
          </Button>
        </div>
      </form>

      <Card className="space-y-5">
        <div>
          <h2 className="text-lg font-bold">{t.profile.sectionFiles}</h2>
          <p className="mt-1 text-sm text-muted">{t.profile.filesHint}</p>
        </div>
        <div className="grid grid-cols-2 gap-4 sm:grid-cols-3">{MEMBER_SLOTS.map(renderSlot)}</div>
        <h3 className="pt-2 text-base font-bold">{t.profile.nomineeFilesTitle}</h3>
        <div className="grid grid-cols-2 gap-4 sm:grid-cols-3">{NOMINEE_SLOTS.map(renderSlot)}</div>
      </Card>
    </div>
  );
}

export function Checklist({ missing }: { missing: MissingItem[] }) {
  const { t } = useI18n();
  if (!missing.length) return <Alert tone="success">{t.profile.checklistDone}</Alert>;
  const label = (m: MissingItem) =>
    m === "personal" ? t.profile.missingPersonal : m === "nominee" ? t.profile.missingNominee : t.files[m];
  return (
    <div className="rounded-3xl border border-border bg-surface p-5 backdrop-blur">
      <p className="text-sm font-semibold">{t.profile.checklistTitle}</p>
      <ul className="mt-2 flex flex-wrap gap-2">
        {missing.map((m) => (
          <li key={m}>
            <Chip tone="gold">{label(m)}</Chip>
          </li>
        ))}
      </ul>
    </div>
  );
}
