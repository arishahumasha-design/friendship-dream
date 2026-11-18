import type { Metadata } from "next";
import Link from "next/link";
import { FileThumb } from "@/components/FileThumb";
import { Avatar, statusTone } from "@/components/MemberBits";
import { Card, Chip } from "@/components/ui";
import { isAdminRole, requireAdmin } from "@/lib/auth";
import { getI18n } from "@/lib/i18n/server";
import { DOC_KINDS, loadMemberRecord, type FileSlot } from "@/lib/members";
import { createClient } from "@/lib/supabase/server";
import { MemberActions } from "./MemberActions";

export const metadata: Metadata = { title: "Member details" };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function AdminMemberPage({ params }: PageProps<"/admin/members/[id]">) {
  const [{ t, lang }, me] = await Promise.all([getI18n(), requireAdmin()]);
  const { id } = await params;
  const record = UUID_RE.test(id)
    ? await loadMemberRecord(await createClient(), id, { withOlder: true })
    : null;

  if (!record) {
    return (
      <div className="mx-auto w-full max-w-5xl px-4 py-10">
        <Link href="/admin/members" className="text-sm font-semibold text-accent hover:underline">
          ← {t.members.back}
        </Link>
        <h1 className="mt-4 text-2xl font-bold">{t.members.notFoundTitle}</h1>
      </div>
    );
  }

  const { profile: p, nominee: n, files, olderFiles, missing } = record;
  const name = p.fullName || p.email || "—";
  const isSelf = p.id === me.id;
  const protectedAdmin = isAdminRole(p.role) && me.role !== "super_admin";
  const fmtDate = (d: string | null) =>
    d ? new Date(d).toLocaleDateString(lang === "bn" ? "bn-BD" : "en-GB", { timeZone: "Asia/Dhaka" }) : "—";

  const personal: [string, string][] = [
    [t.profile.fullNameEn, p.fullName],
    [t.profile.fullNameBn, p.fullNameBn],
    [t.profile.fatherName, p.fatherName],
    [t.profile.motherName, p.motherName],
    [t.profile.dob, p.dob ? fmtDate(p.dob) : ""],
    [t.profile.phone, p.phone],
    [t.members.email, p.email ?? ""],
    [t.profile.addressPresent, p.addressPresent],
    [t.profile.addressPermanent, p.addressPermanent],
    [t.members.signedUp, fmtDate(p.createdAt)],
    [t.profile.joinedOn, p.joinedOn ? fmtDate(p.joinedOn) : ""],
  ];
  const nomineeRows: [string, string][] = n
    ? [
        [t.profile.nomineeName, n.name],
        [t.profile.nomineeRelation, n.relation],
        [t.profile.nomineePhone, n.phone],
        [t.profile.nomineeNid, n.nidNumber],
        [t.profile.nomineeAddress, n.address],
      ]
    : [];
  const slots: FileSlot[] = ["photo", ...DOC_KINDS];
  const missingLabel = (m: (typeof missing)[number]) =>
    m === "personal" ? t.profile.missingPersonal : m === "nominee" ? t.profile.missingNominee : t.files[m];

  return (
    <div className="mx-auto w-full max-w-5xl px-4 py-8 sm:py-10">
      <Link href="/admin/members" className="text-sm font-semibold text-accent hover:underline">
        ← {t.members.back}
      </Link>

      <div className="mt-4 flex flex-wrap items-center gap-4">
        <Avatar url={files.photo?.url} name={name} size={72} zoom />
        <div className="min-w-0">
          <h1 className="truncate text-2xl font-bold tracking-tight sm:text-3xl">{name}</h1>
          <div className="mt-1.5 flex flex-wrap gap-1.5">
            <Chip tone="accent">
              {t.profile.memberNo} {p.memberNo}
            </Chip>
            <Chip tone={statusTone(p.status)}>{t.members[`status_${p.status}`]}</Chip>
            <Chip>{t.members[`role_${p.role}`]}</Chip>
          </div>
        </div>
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-[1fr_20rem]">
        <div className="min-w-0 space-y-6">
          {missing.length > 0 && (
            <div className="rounded-3xl border border-border bg-surface p-5 backdrop-blur">
              <p className="text-sm font-semibold">{t.members.missingList}</p>
              <ul className="mt-2 flex flex-wrap gap-2">
                {missing.map((m) => (
                  <li key={m}>
                    <Chip tone="gold">{missingLabel(m)}</Chip>
                  </li>
                ))}
              </ul>
            </div>
          )}

          <Card>
            <h2 className="text-lg font-bold">{t.members.personal}</h2>
            <InfoList rows={personal} />
          </Card>

          <Card>
            <h2 className="text-lg font-bold">{t.members.nominee}</h2>
            {n ? <InfoList rows={nomineeRows} /> : <p className="mt-3 text-sm text-muted">{t.members.noNominee}</p>}
          </Card>

          <Card>
            <h2 className="text-lg font-bold">{t.members.documents}</h2>
            <div className="mt-4 grid grid-cols-2 gap-4 sm:grid-cols-3">
              {slots.map((slot) => (
                <div key={slot} className="space-y-2">
                  <p className="text-sm font-medium">{t.files[slot]}</p>
                  <FileThumb memberId={p.id} file={files[slot] ?? null} label={t.files[slot]} />
                  {slot !== "photo" && (olderFiles[slot]?.length ?? 0) > 0 && (
                    <details className="text-xs text-muted">
                      <summary className="cursor-pointer">
                        {t.members.olderVersions} ({olderFiles[slot]!.length})
                      </summary>
                      <div className="mt-2 grid grid-cols-2 gap-2">
                        {olderFiles[slot]!.map((f) => (
                          <div key={f.id}>
                            <FileThumb memberId={p.id} file={f} label={`${t.files[slot]} · ${fmtDate(f.uploadedAt)}`} />
                            <p className="mt-0.5">{fmtDate(f.uploadedAt)}</p>
                          </div>
                        ))}
                      </div>
                    </details>
                  )}
                </div>
              ))}
            </div>
          </Card>
        </div>

        <aside className="lg:sticky lg:top-20 lg:self-start">
          <MemberActions
            memberId={p.id}
            status={p.status}
            role={p.role}
            reviewNote={p.reviewNote}
            incomplete={missing.length > 0}
            canActivate={me.role === "super_admin"}
            canChangeRole={me.role === "super_admin" && !isSelf && p.role !== "super_admin" && p.status === "active"}
            locked={isSelf ? "self" : protectedAdmin ? "admin" : null}
          />
        </aside>
      </div>
    </div>
  );
}

function InfoList({ rows }: { rows: [string, string][] }) {
  return (
    <dl className="mt-4 grid gap-x-6 gap-y-3 sm:grid-cols-2">
      {rows.map(([label, value]) => (
        <div key={label} className="min-w-0">
          <dt className="text-xs text-muted">{label}</dt>
          <dd className="mt-0.5 whitespace-pre-line break-words text-sm font-medium">{value || "—"}</dd>
        </div>
      ))}
    </dl>
  );
}
