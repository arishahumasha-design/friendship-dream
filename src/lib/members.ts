import type { SupabaseClient } from "@supabase/supabase-js";
import type { MemberStatus, UserRole } from "./auth";

/** Files kept in the private 'documents' bucket (the member photo lives in 'avatars'). */
export const DOC_KINDS = [
  "nid_front",
  "nid_back",
  "signature",
  "passport",
  "nominee_photo",
  "nominee_nid",
] as const;
export type DocKind = (typeof DOC_KINDS)[number];

/** An upload slot on the form: the member photo or one of the documents. */
export type FileSlot = "photo" | DocKind;

export const REQUIRED_FILES: FileSlot[] = [
  "photo",
  "nid_front",
  "nid_back",
  "signature",
  "nominee_photo",
  "nominee_nid",
];

/** Slots where a PDF is accepted as well as an image. */
export const PDF_SLOTS: FileSlot[] = ["nid_front", "nid_back", "passport"];

export const MAX_FILE_BYTES = 5 * 1024 * 1024;
export const SIGNED_URL_SECONDS = 60;

/** A stored file as the UI sees it. The storage path never leaves the server. */
export type FileRef = {
  /** member_documents.id, or "avatar" for the member photo */
  id: string;
  url: string | null;
  isPdf: boolean;
  uploadedAt: string | null;
};

export type MemberProfile = {
  id: string;
  memberNo: number;
  email: string | null;
  fullName: string;
  fullNameBn: string;
  fatherName: string;
  motherName: string;
  dob: string;
  phone: string;
  addressPresent: string;
  addressPermanent: string;
  role: UserRole;
  status: MemberStatus;
  joinedOn: string | null;
  reviewNote: string | null;
  createdAt: string;
};

export type Nominee = {
  name: string;
  relation: string;
  phone: string;
  address: string;
  nidNumber: string;
};

export type MemberRecord = {
  profile: MemberProfile;
  nominee: Nominee | null;
  files: Partial<Record<FileSlot, FileRef>>;
  /** older replaced versions per document kind (admin view) */
  olderFiles: Partial<Record<DocKind, FileRef[]>>;
  missing: MissingItem[];
};

export type MissingItem = "personal" | "nominee" | FileSlot;

const PROFILE_COLUMNS =
  "id, member_no, email, full_name, full_name_bn, father_name, mother_name, dob, phone, address_present, address_permanent, photo_path, role, status, joined_on, review_note, created_at";

export const PERSONAL_REQUIRED = [
  "fullName",
  "fullNameBn",
  "fatherName",
  "motherName",
  "dob",
  "phone",
  "addressPresent",
  "addressPermanent",
] as const satisfies readonly (keyof MemberProfile)[];

export const NOMINEE_REQUIRED: (keyof Nominee)[] = ["name", "relation", "phone", "address", "nidNumber"];

export function isPdfPath(path: string) {
  return path.toLowerCase().endsWith(".pdf");
}

/** What is still missing before an admin can approve. */
export function findMissing(
  profile: Pick<MemberProfile, (typeof PERSONAL_REQUIRED)[number]>,
  nominee: Nominee | null,
  present: Iterable<FileSlot>,
): MissingItem[] {
  const have = new Set(present);
  const missing: MissingItem[] = [];
  if (PERSONAL_REQUIRED.some((k) => !String(profile[k] ?? "").trim())) missing.push("personal");
  if (!nominee || NOMINEE_REQUIRED.some((k) => !nominee[k].trim())) missing.push("nominee");
  for (const slot of REQUIRED_FILES) if (!have.has(slot)) missing.push(slot);
  return missing;
}

type ProfileRow = {
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
  joined_on: string | null;
  review_note: string | null;
  created_at: string;
};

type DocRow = { id: string; kind: DocKind; storage_path: string; uploaded_at: string };

/**
 * Loads one member's profile, nominee and documents with the CALLER's session,
 * so Row Level Security decides what comes back (owner or admin only).
 * Thumbnails get short-lived signed URLs; paths are not returned.
 */
export async function loadMemberRecord(
  supabase: SupabaseClient,
  memberId: string,
  { withOlder = false } = {},
): Promise<MemberRecord | null> {
  const [{ data: pRow }, { data: n }, { data: dRows }] = await Promise.all([
    supabase.from("profiles").select(PROFILE_COLUMNS).eq("id", memberId).maybeSingle(),
    supabase
      .from("nominees")
      .select("name, relation, phone, address, nid_number")
      .eq("member_id", memberId)
      .maybeSingle(),
    supabase
      .from("member_documents")
      .select("id, kind, storage_path, uploaded_at")
      .eq("member_id", memberId)
      .order("uploaded_at", { ascending: false }),
  ]);
  if (!pRow) return null;
  const p = pRow as ProfileRow;
  const d = (dRows ?? []) as DocRow[];

  const profile: MemberProfile = {
    id: p.id,
    memberNo: p.member_no,
    email: p.email,
    fullName: p.full_name ?? "",
    fullNameBn: p.full_name_bn ?? "",
    fatherName: p.father_name ?? "",
    motherName: p.mother_name ?? "",
    dob: p.dob ?? "",
    phone: p.phone ?? "",
    addressPresent: p.address_present ?? "",
    addressPermanent: p.address_permanent ?? "",
    role: p.role,
    status: p.status,
    joinedOn: p.joined_on,
    reviewNote: p.review_note,
    createdAt: p.created_at,
  };

  const nominee: Nominee | null = n
    ? {
        name: n.name ?? "",
        relation: n.relation ?? "",
        phone: n.phone ?? "",
        address: n.address ?? "",
        nidNumber: n.nid_number ?? "",
      }
    : null;

  // newest first: the first row of each kind is the current one
  const latest = new Map<DocKind, DocRow>();
  const older = new Map<DocKind, DocRow[]>();
  for (const row of d) {
    if (!latest.has(row.kind)) latest.set(row.kind, row);
    else if (withOlder) older.set(row.kind, [...(older.get(row.kind) ?? []), row]);
  }

  const docRows = [...latest.values(), ...[...older.values()].flat()];
  const signed = new Map<string, string | null>();
  if (docRows.length) {
    const { data: urls } = await supabase.storage
      .from("documents")
      .createSignedUrls(
        docRows.map((r) => r.storage_path),
        SIGNED_URL_SECONDS,
      );
    (urls ?? []).forEach((u, i) => signed.set(docRows[i].id, u.signedUrl ?? null));
  }
  const toRef = (r: DocRow): FileRef => ({
    id: r.id,
    url: signed.get(r.id) ?? null,
    isPdf: isPdfPath(r.storage_path),
    uploadedAt: r.uploaded_at,
  });

  const files: Partial<Record<FileSlot, FileRef>> = {};
  for (const [kind, row] of latest) files[kind] = toRef(row);
  if (p.photo_path) {
    const { data: a } = await supabase.storage
      .from("avatars")
      .createSignedUrl(p.photo_path, SIGNED_URL_SECONDS);
    files.photo = { id: "avatar", url: a?.signedUrl ?? null, isPdf: false, uploadedAt: null };
  }

  const olderFiles: Partial<Record<DocKind, FileRef[]>> = {};
  for (const [kind, rows] of older) olderFiles[kind] = rows.map(toRef);

  const missing = findMissing(profile, nominee, Object.keys(files) as FileSlot[]);
  return { profile, nominee, files, olderFiles, missing };
}

/** Today's date in Bangladesh, as YYYY-MM-DD. */
export function todayInDhaka() {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Dhaka" }).format(new Date());
}
