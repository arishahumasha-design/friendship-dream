import type { SupabaseClient } from "@supabase/supabase-js";
import type { Lang } from "./i18n/types";

export type Policy = {
  id: string;
  sortOrder: number;
  title: string;
  body: string;
  effectiveFrom: string;
  /** false = hidden from members (policies are never deleted, only hidden) */
  visible: boolean;
};

/** Policies in their saved order. Members only get the visible ones (RLS lets every active member read all rows). */
export async function loadPolicies(supabase: SupabaseClient, { includeHidden = false } = {}) {
  let q = supabase
    .from("policies")
    .select("id, sort_order, title, body, effective_from, is_current")
    .order("sort_order", { ascending: true })
    .order("created_at", { ascending: true });
  if (!includeHidden) q = q.eq("is_current", true);
  const { data, error } = await q;
  if (error) console.error("policies error code:", error.code ?? "unknown");
  const rows: Policy[] = ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    id: String(r.id),
    sortOrder: Number(r.sort_order),
    title: String(r.title),
    body: String(r.body),
    effectiveFrom: String(r.effective_from),
    visible: r.is_current === true,
  }));
  return { rows, failed: !!error };
}

export type Notice = { id: string; title: string; body: string; createdAt: string; pinned: boolean };

export async function loadNotices(supabase: SupabaseClient, range: [number, number]) {
  const { data, count, error } = await supabase
    .from("notices")
    .select("id, title, body, created_at, pinned", { count: "exact" })
    .order("pinned", { ascending: false })
    .order("pinned_at", { ascending: false, nullsFirst: false })
    .order("created_at", { ascending: false })
    .range(range[0], range[1]);
  if (error) console.error("notices error code:", error.code ?? "unknown");
  const rows: Notice[] = ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    id: String(r.id),
    title: String(r.title),
    body: String(r.body),
    createdAt: String(r.created_at),
    pinned: r.pinned === true,
  }));
  return { rows, count: count ?? 0, failed: !!error };
}

/** Number of pinned notices (for the nav badge). 0 if the query fails. */
export async function countPinnedNotices(supabase: SupabaseClient): Promise<number> {
  const { count, error } = await supabase.from("notices").select("id", { count: "exact", head: true }).eq("pinned", true);
  if (error) return 0;
  return count ?? 0;
}

export type SiteText = { en: string; bn: string };

/** Public page texts (site_content is readable by everyone, also logged-out visitors). */
export async function loadSiteContent(supabase: SupabaseClient, keys: string[]) {
  const { data } = await supabase.from("site_content").select("key, body_en, body_bn").in("key", keys);
  return new Map(
    ((data ?? []) as { key: string; body_en: string | null; body_bn: string | null }[]).map((r) => [
      r.key,
      { en: r.body_en ?? "", bn: r.body_bn ?? "" } as SiteText,
    ]),
  );
}

/** The text in the viewer's language, falling back to the other language, then to `fallback`. */
export function pickText(row: SiteText | undefined, lang: Lang, fallback = "") {
  const first = lang === "bn" ? row?.bn : row?.en;
  const second = lang === "bn" ? row?.en : row?.bn;
  return (first?.trim() || second?.trim() || fallback).trim();
}

/** Keys used by the editable public / about texts. */
export const SITE_KEYS = {
  messages: ["home_message_1", "home_message_2", "home_message_3"],
  about: "about",
  aboutStart: "about_start",
} as const;
