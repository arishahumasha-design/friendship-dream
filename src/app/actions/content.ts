"use server";

import { revalidatePath } from "next/cache";
import { getCurrentProfile, isAdminRole } from "@/lib/auth";
import { SITE_KEYS } from "@/lib/content";
import { getI18n } from "@/lib/i18n/server";
import { createClient } from "@/lib/supabase/server";

/**
 * Content actions run with the signed-in user's own session; RLS and the audit triggers on
 * policies / site_content do the rest. Policies are never deleted: "hide" sets is_current = false.
 * Who may do what (super admin for policies and site texts, any admin for notices) is checked here,
 * because the database policies allow every admin to write these tables.
 */
export type ContentResult = { ok: true } | { ok: false; message: string };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const isStr = (v: unknown): v is string => typeof v === "string";
const isUuid = (v: unknown): v is string => isStr(v) && UUID_RE.test(v);
const isDate = (v: unknown): v is string => isStr(v) && /^\d{4}-\d{2}-\d{2}$/.test(v) && !Number.isNaN(Date.parse(v));

async function who(level: "admin" | "super") {
  const { t } = await getI18n();
  const me = await getCurrentProfile();
  const ok = !!me && me.status === "active" && (level === "super" ? me.role === "super_admin" : isAdminRole(me.role));
  if (!ok) return { ok: false as const, message: level === "super" ? t.content.errSuperOnly : t.content.errAdminOnly };
  return { ok: true as const, t, supabase: await createClient() };
}

function fail(t: Awaited<ReturnType<typeof getI18n>>["t"], error: { code?: string } | null): ContentResult {
  if (error?.code === "42501") return { ok: false, message: t.content.errNotAllowed };
  console.error("content error code:", error?.code ?? "unknown");
  return { ok: false, message: t.content.errGeneric };
}

export async function savePolicy(input: unknown): Promise<ContentResult> {
  const a = await who("super");
  if (!a.ok) return a;
  if (input === null || typeof input !== "object") return { ok: false, message: a.t.content.errGeneric };
  const i = input as Record<string, unknown>;
  const title = isStr(i.title) ? i.title.trim() : "";
  const body = isStr(i.body) ? i.body.trim() : "";
  if (!title || title.length > 200) return { ok: false, message: a.t.content.errTitle };
  if (!body || body.length > 5000) return { ok: false, message: a.t.content.errBody };
  if (!isDate(i.effectiveFrom)) return { ok: false, message: a.t.content.errDate };

  if (isUuid(i.id)) {
    const { data, error } = await a.supabase
      .from("policies")
      .update({ title, body, effective_from: i.effectiveFrom })
      .eq("id", i.id)
      .select("id")
      .maybeSingle();
    if (error) return fail(a.t, error);
    if (!data) return { ok: false, message: a.t.content.errNotFound };
  } else {
    const { data: last } = await a.supabase.from("policies").select("sort_order").order("sort_order", { ascending: false }).limit(1);
    const next = (last?.[0]?.sort_order ?? 0) + 1;
    const { error } = await a.supabase.from("policies").insert({ title, body, effective_from: i.effectiveFrom, sort_order: next, is_current: true });
    if (error) return fail(a.t, error);
  }
  revalidatePath("/policies");
  revalidatePath("/admin/policies");
  return { ok: true };
}

/** Swap the place of a policy with its neighbour (only the two rows change, both are audit-logged). */
export async function movePolicy(id: unknown, direction: unknown): Promise<ContentResult> {
  const a = await who("super");
  if (!a.ok) return a;
  if (!isUuid(id) || (direction !== "up" && direction !== "down")) return { ok: false, message: a.t.content.errGeneric };
  const { data } = await a.supabase.from("policies").select("id, sort_order").order("sort_order").order("created_at");
  const rows = (data ?? []) as { id: string; sort_order: number }[];
  const at = rows.findIndex((r) => r.id === id);
  const other = rows[direction === "up" ? at - 1 : at + 1];
  if (at < 0 || !other) return { ok: false, message: a.t.content.errGeneric };
  const mine = rows[at];
  // equal numbers would make a swap do nothing: give the mover a number just past its neighbour
  const moverNew = mine.sort_order === other.sort_order ? other.sort_order + (direction === "up" ? -1 : 1) : other.sort_order;
  const otherNew = mine.sort_order;
  const r1 = await a.supabase.from("policies").update({ sort_order: moverNew }).eq("id", mine.id);
  if (r1.error) return fail(a.t, r1.error);
  const r2 = await a.supabase.from("policies").update({ sort_order: otherNew }).eq("id", other.id);
  if (r2.error) return fail(a.t, r2.error);
  revalidatePath("/policies");
  revalidatePath("/admin/policies");
  return { ok: true };
}

export async function setPolicyHidden(id: unknown, hidden: unknown): Promise<ContentResult> {
  const a = await who("super");
  if (!a.ok) return a;
  if (!isUuid(id) || typeof hidden !== "boolean") return { ok: false, message: a.t.content.errGeneric };
  const { data, error } = await a.supabase.from("policies").update({ is_current: !hidden }).eq("id", id).select("id").maybeSingle();
  if (error) return fail(a.t, error);
  if (!data) return { ok: false, message: a.t.content.errNotFound };
  revalidatePath("/policies");
  revalidatePath("/admin/policies");
  return { ok: true };
}

export async function postNotice(input: unknown): Promise<ContentResult> {
  const a = await who("admin");
  if (!a.ok) return a;
  if (input === null || typeof input !== "object") return { ok: false, message: a.t.content.errGeneric };
  const i = input as Record<string, unknown>;
  const title = isStr(i.title) ? i.title.trim() : "";
  const body = isStr(i.body) ? i.body.trim() : "";
  if (!title || title.length > 200) return { ok: false, message: a.t.content.errTitle };
  if (!body || body.length > 5000) return { ok: false, message: a.t.content.errBody };
  const pinned = i.pinned === true;
  const { error } = await a.supabase.from("notices").insert({ title, body, pinned });
  if (error) return fail(a.t, error);
  revalidatePath("/notices");
  revalidatePath("/admin/notices");
  return { ok: true };
}

/** Pin or unpin a notice (any admin). The database sets pinned_at and refuses non-admins. */
export async function setNoticePinned(id: unknown, pinned: unknown): Promise<ContentResult> {
  const a = await who("admin");
  if (!a.ok) return a;
  if (!isUuid(id) || typeof pinned !== "boolean") return { ok: false, message: a.t.content.errGeneric };
  const { data, error } = await a.supabase.from("notices").update({ pinned }).eq("id", id).select("id");
  if (error) return fail(a.t, error);
  if (!data || data.length === 0) return { ok: false, message: a.t.content.errNotFound };
  revalidatePath("/notices");
  revalidatePath("/admin/notices");
  return { ok: true };
}

const EDITABLE = new Set<string>([...SITE_KEYS.messages, SITE_KEYS.about, SITE_KEYS.aboutStart]);

/** Save one public / about text in both languages (super admin only). An empty text hides an optional message. */
export async function saveSiteText(key: unknown, en: unknown, bn: unknown): Promise<ContentResult> {
  const a = await who("super");
  if (!a.ok) return a;
  if (!isStr(key) || !EDITABLE.has(key) || !isStr(en) || !isStr(bn)) return { ok: false, message: a.t.content.errGeneric };
  const clean = (s: string) => s.trim();
  if (clean(en).length > 1500 || clean(bn).length > 1500) return { ok: false, message: a.t.content.errBody };
  const { error } = await a.supabase
    .from("site_content")
    .upsert({ key, body_en: clean(en) || null, body_bn: clean(bn) || null, updated_at: new Date().toISOString() }, { onConflict: "key" });
  if (error) return fail(a.t, error);
  for (const p of ["/", "/about", "/admin/site"]) revalidatePath(p);
  return { ok: true };
}
