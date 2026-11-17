import type { Metadata } from "next";
import Link from "next/link";
import { Avatar, statusTone } from "@/components/MemberBits";
import { Card, Chip, cn } from "@/components/ui";
import { requireAdmin, type MemberStatus, type UserRole } from "@/lib/auth";
import { getI18n } from "@/lib/i18n/server";
import { findMissing, SIGNED_URL_SECONDS, type DocKind, type FileSlot, type Nominee } from "@/lib/members";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Members" };

const TABS = ["pending", "active", "suspended", "all"] as const;
type Tab = (typeof TABS)[number];

type Row = {
  id: string;
  member_no: number;
  email: string | null;
  full_name: string | null;
  full_name_bn: string | null;
  father_name: string | null;
  mother_name: string | null;
  dob: string | null;
  phone: string | null;
  address_present: string | null;
  address_permanent: string | null;
  photo_path: string | null;
  role: UserRole;
  status: MemberStatus;
  review_note: string | null;
};

export default async function AdminMembersPage({ searchParams }: PageProps<"/admin/members">) {
  const [{ t }] = await Promise.all([getI18n(), requireAdmin()]);
  const sp = await searchParams;
  const supabase = await createClient();

  const [{ data: rows }, { data: docs }, { data: nominees }] = await Promise.all([
    supabase
      .from("profiles")
      .select(
        "id, member_no, email, full_name, full_name_bn, father_name, mother_name, dob, phone, address_present, address_permanent, photo_path, role, status, review_note",
      )
      .order("member_no"),
    supabase.from("member_documents").select("member_id, kind"),
    supabase.from("nominees").select("member_id, name, relation, phone, address, nid_number"),
  ]);
  const all = (rows ?? []) as Row[];

  const counts = {
    pending: all.filter((r) => r.status === "pending").length,
    active: all.filter((r) => r.status === "active").length,
    suspended: all.filter((r) => r.status === "suspended").length,
    all: all.length,
  };
  const requested = typeof sp.tab === "string" && (TABS as readonly string[]).includes(sp.tab) ? (sp.tab as Tab) : null;
  const tab: Tab = requested ?? (counts.pending > 0 ? "pending" : "active");
  const list = tab === "all" ? all : all.filter((r) => r.status === tab);

  // Which files / nominee each member has (for the "complete" chip).
  const docKinds = new Map<string, Set<FileSlot>>();
  for (const d of (docs ?? []) as { member_id: string; kind: DocKind }[]) {
    if (!docKinds.has(d.member_id)) docKinds.set(d.member_id, new Set());
    docKinds.get(d.member_id)!.add(d.kind);
  }
  const nomineeOf = new Map<string, Nominee>();
  for (const n of nominees ?? []) {
    nomineeOf.set(n.member_id, {
      name: n.name ?? "",
      relation: n.relation ?? "",
      phone: n.phone ?? "",
      address: n.address ?? "",
      nidNumber: n.nid_number ?? "",
    });
  }

  // Short-lived signed URLs for photos.
  const withPhoto = list.filter((r) => r.photo_path);
  const photoUrl = new Map<string, string>();
  if (withPhoto.length) {
    const { data: urls } = await supabase.storage
      .from("avatars")
      .createSignedUrls(
        withPhoto.map((r) => r.photo_path!),
        SIGNED_URL_SECONDS,
      );
    (urls ?? []).forEach((u, i) => u.signedUrl && photoUrl.set(withPhoto[i].id, u.signedUrl));
  }

  const tabLabel: Record<Tab, string> = {
    pending: t.members.tabPending,
    active: t.members.tabActive,
    suspended: t.members.tabSuspended,
    all: t.members.tabAll,
  };

  return (
    <div className="mx-auto w-full max-w-5xl px-4 py-8 sm:py-10">
      <Link href="/admin" className="text-sm font-semibold text-accent hover:underline">
        ← {t.admin.title}
      </Link>
      <h1 className="mt-2 text-3xl font-bold tracking-tight">{t.members.title}</h1>
      <p className="mt-1.5 text-sm text-muted">{t.members.subtitle}</p>

      <nav className="-mx-4 mt-6 flex gap-2 overflow-x-auto px-4 pb-1" aria-label={t.members.title}>
        {TABS.map((k) => (
          <Link
            key={k}
            href={`/admin/members?tab=${k}`}
            aria-current={tab === k ? "page" : undefined}
            className={cn(
              "inline-flex h-10 shrink-0 items-center gap-2 rounded-full border px-4 text-sm font-semibold transition",
              tab === k
                ? "border-accent bg-accent text-accent-fg"
                : "border-border bg-surface hover:bg-accent-soft",
            )}
          >
            {tabLabel[k]}
            <span
              className={cn(
                "rounded-full px-1.5 text-xs",
                tab === k ? "bg-black/15" : k === "pending" && counts.pending ? "bg-gold/30" : "bg-fg/8",
              )}
            >
              {counts[k]}
            </span>
          </Link>
        ))}
      </nav>

      <Card className="mt-4 p-2 sm:p-3">
        {list.length === 0 ? (
          <p className="p-6 text-center text-sm text-muted">{t.members.empty}</p>
        ) : (
          <ul className="divide-y divide-border">
            {list.map((r) => {
              const name = r.full_name || r.email || "—";
              const files: FileSlot[] = [...(docKinds.get(r.id) ?? [])];
              if (r.photo_path) files.push("photo");
              const missing = findMissing(
                {
                  fullName: r.full_name ?? "",
                  fullNameBn: r.full_name_bn ?? "",
                  fatherName: r.father_name ?? "",
                  motherName: r.mother_name ?? "",
                  dob: r.dob ?? "",
                  phone: r.phone ?? "",
                  addressPresent: r.address_present ?? "",
                  addressPermanent: r.address_permanent ?? "",
                },
                nomineeOf.get(r.id) ?? null,
                files,
              );
              return (
                <li key={r.id}>
                  <Link
                    href={`/admin/members/${r.id}`}
                    className="flex items-center gap-3 rounded-2xl p-3 transition hover:bg-accent-soft"
                  >
                    <Avatar url={photoUrl.get(r.id)} name={name} />
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold">{name}</p>
                      <p className="truncate text-xs text-muted">
                        {t.members.memberNo} {r.member_no}
                        {r.full_name_bn ? ` · ${r.full_name_bn}` : ""}
                      </p>
                      <div className="mt-1.5 flex flex-wrap gap-1.5">
                        <Chip tone={statusTone(r.status)}>{t.members[`status_${r.status}`]}</Chip>
                        {r.role !== "member" && <Chip>{t.members[`role_${r.role}`]}</Chip>}
                        {r.status === "pending" && (
                          <Chip tone={missing.length ? "danger" : "accent"}>
                            {missing.length ? t.members.incomplete : t.members.complete}
                          </Chip>
                        )}
                        {r.status === "pending" && r.review_note && <Chip>{t.members.noteSent}</Chip>}
                      </div>
                    </div>
                    <span aria-hidden className="text-muted">
                      ›
                    </span>
                  </Link>
                </li>
              );
            })}
          </ul>
        )}
      </Card>
    </div>
  );
}
