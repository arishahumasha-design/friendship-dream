"use server";

import { revalidatePath } from "next/cache";
import { getCurrentProfile, isAdminRole, type UserRole } from "@/lib/auth";
import { todayInDhaka } from "@/lib/members";
import { createClient } from "@/lib/supabase/server";

const MEMBER_ACTIONS = ["approve", "suspend", "reactivate", "incomplete"] as const;
export type MemberAction = (typeof MEMBER_ACTIONS)[number];

export type ActionResult =
  | { ok: true; message: "approved" | "suspended" | "reactivated" | "noteSaved" | "roleChanged" }
  | {
      ok: false;
      error: "notAllowed" | "wrongState" | "noteRequired" | "notFound" | "failed" | "activateSuperOnly";
    };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Admin changes a member's status. RLS + the protect_profile_fields trigger
 * are the real lock; we re-read the saved row to confirm the change applied.
 */
export async function changeMemberStatus(
  rawMemberId: unknown,
  rawAction: unknown,
  rawNote?: unknown,
): Promise<ActionResult> {
  const me = await getCurrentProfile();
  if (!me || me.status !== "active" || !isAdminRole(me.role)) return { ok: false, error: "notAllowed" };
  // Arguments come from the browser: check their types before using them.
  if (typeof rawMemberId !== "string" || !UUID_RE.test(rawMemberId)) return { ok: false, error: "notFound" };
  if (rawNote !== undefined && typeof rawNote !== "string") return { ok: false, error: "failed" };
  if (!MEMBER_ACTIONS.includes(rawAction as MemberAction)) return { ok: false, error: "failed" };
  const memberId = rawMemberId.toLowerCase();
  const action = rawAction as MemberAction;
  const note = rawNote;
  if (memberId === me.id.toLowerCase()) return { ok: false, error: "notAllowed" };

  const supabase = await createClient();
  const { data: target } = await supabase
    .from("profiles")
    .select("status, role, joined_on")
    .eq("id", memberId)
    .maybeSingle();
  if (!target) return { ok: false, error: "notFound" };

  if (isAdminRole(target.role as UserRole) && me.role !== "super_admin") {
    return { ok: false, error: "notAllowed" };
  }
  // Making a member active (approve, or re-activate) is the super admin's decision only.
  if ((action === "approve" || action === "reactivate") && me.role !== "super_admin") {
    return { ok: false, error: "activateSuperOnly" };
  }

  let patch: Record<string, unknown>;
  let expectStatus: string;
  let message: Extract<ActionResult, { ok: true }>["message"];

  switch (action) {
    case "approve":
      if (target.status !== "pending") return { ok: false, error: "wrongState" };
      patch = { status: "active", joined_on: todayInDhaka(), review_note: null };
      expectStatus = "active";
      message = "approved";
      break;
    case "suspend":
      if (target.status !== "active") return { ok: false, error: "wrongState" };
      patch = { status: "suspended" };
      expectStatus = "suspended";
      message = "suspended";
      break;
    case "reactivate":
      if (target.status !== "suspended") return { ok: false, error: "wrongState" };
      patch = { status: "active", ...(target.joined_on ? {} : { joined_on: todayInDhaka() }) };
      expectStatus = "active";
      message = "reactivated";
      break;
    case "incomplete": {
      if (target.status !== "pending") return { ok: false, error: "wrongState" };
      const text = (note ?? "").trim().slice(0, 1000);
      if (!text) return { ok: false, error: "noteRequired" };
      patch = { review_note: text };
      expectStatus = "pending";
      message = "noteSaved";
      break;
    }
    default:
      return { ok: false, error: "failed" };
  }

  const { data: saved, error } = await supabase
    .from("profiles")
    .update(patch)
    .eq("id", memberId)
    .select("status")
    .maybeSingle();
  if (error && /super admin can activate/i.test(error.message)) return { ok: false, error: "activateSuperOnly" };
  if (error && /super admin can make this status change/i.test(error.message)) return { ok: false, error: "notAllowed" };
  if (error && /review note for a pending member/i.test(error.message)) return { ok: false, error: "wrongState" };
  if (error || !saved) return { ok: false, error: "failed" };
  if (saved.status !== expectStatus) return { ok: false, error: "notAllowed" };

  revalidatePath("/admin/members");
  revalidatePath(`/admin/members/${memberId}`);
  return { ok: true, message };
}

/** Only the super admin makes someone admin or back to member (the database enforces this too). */
export async function changeMemberRole(
  rawMemberId: unknown,
  role: unknown,
): Promise<ActionResult> {
  const me = await getCurrentProfile();
  if (!me || me.status !== "active" || me.role !== "super_admin") return { ok: false, error: "notAllowed" };
  if (typeof rawMemberId !== "string" || !UUID_RE.test(rawMemberId)) return { ok: false, error: "notFound" };
  const memberId = rawMemberId.toLowerCase();
  if (memberId === me.id.toLowerCase()) return { ok: false, error: "notAllowed" };
  if (role !== "admin" && role !== "member") return { ok: false, error: "failed" };

  const supabase = await createClient();
  const { data: target } = await supabase
    .from("profiles")
    .select("status, role")
    .eq("id", memberId)
    .maybeSingle();
  if (!target) return { ok: false, error: "notFound" };
  if (target.role === "super_admin" || target.status !== "active" || target.role === role) {
    return { ok: false, error: "wrongState" };
  }

  const { data: saved, error } = await supabase
    .from("profiles")
    .update({ role })
    .eq("id", memberId)
    .select("role")
    .maybeSingle();
  if (error || !saved) return { ok: false, error: "failed" };
  if (saved.role !== role) return { ok: false, error: "notAllowed" };

  revalidatePath("/admin/members");
  revalidatePath(`/admin/members/${memberId}`);
  return { ok: true, message: "roleChanged" };
}
