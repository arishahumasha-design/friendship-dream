import { redirect } from "next/navigation";
import { cache } from "react";
import { createClient } from "@/lib/supabase/server";

export type UserRole = "member" | "admin" | "super_admin";
export type MemberStatus = "pending" | "active" | "suspended" | "exited";

export type CurrentProfile = {
  id: string;
  email: string | null;
  fullName: string;
  role: UserRole;
  status: MemberStatus;
};

/**
 * The logged-in user's own profile, or null when not logged in.
 * RLS only lets a member read their own row, so this is safe.
 */
export const getCurrentProfile = cache(async (): Promise<CurrentProfile | null> => {
  const supabase = await createClient();
  const { data: claimsData } = await supabase.auth.getClaims();
  const userId = claimsData?.claims?.sub;
  if (!userId) return null;

  const { data } = await supabase
    .from("profiles")
    .select("id, email, full_name, role, status")
    .eq("id", userId)
    .maybeSingle();

  if (!data) {
    // Logged in, but the profile row is not readable/created yet: treat as pending.
    return { id: userId, email: null, fullName: "", role: "member", status: "pending" };
  }

  return {
    id: data.id,
    email: data.email,
    fullName: data.full_name,
    role: data.role as UserRole,
    status: data.status as MemberStatus,
  };
});

export function isAdminRole(role: UserRole) {
  return role === "admin" || role === "super_admin";
}

/** Page guard: logged in AND active. (The proxy checks this too; this is the second lock.) */
export async function requireActiveMember() {
  const profile = await getCurrentProfile();
  if (!profile) redirect("/login");
  if (profile.status !== "active") redirect("/pending");
  return profile;
}

/** Page guard: active super admin only. */
export async function requireSuperAdmin() {
  const profile = await requireActiveMember();
  if (profile.role !== "super_admin") redirect(isAdminRole(profile.role) ? "/admin" : "/home");
  return profile;
}

/** Page guard: active admin or super admin. */
export async function requireAdmin() {
  const profile = await requireActiveMember();
  if (!isAdminRole(profile.role)) redirect("/home");
  return profile;
}
