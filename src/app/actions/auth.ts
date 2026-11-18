"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import type { ErrorKey } from "@/lib/i18n/types";
import { safeNext } from "@/lib/safe-redirect";
import { siteUrl } from "@/lib/site-url";

export type AuthFormState = {
  error?: ErrorKey;
  checkEmail?: boolean;
  /** forgot password: shown with the SAME message whether the email exists or not */
  sent?: boolean;
  /** reset / change password finished */
  done?: boolean;
  values?: { fullName?: string; email?: string };
};

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MIN_PASSWORD = 10;
const MAX_PASSWORD = 72;   // bcrypt limit

function mapAuthError(code: string | undefined, message: string): ErrorKey {
  switch (code) {
    case "invalid_credentials":
      return "invalidCredentials";
    case "email_not_confirmed":
      return "emailNotConfirmed";
    case "user_already_exists":
    case "email_exists":
      return "userExists";
    case "weak_password":
      return "weakPassword";
    case "same_password":
      return "samePassword";
    case "over_email_send_rate_limit":
    case "over_request_rate_limit":
      return "rateLimit";
    case "email_address_invalid":
      return "invalidEmail";
  }
  if (/invalid login credentials/i.test(message)) return "invalidCredentials";
  return "generic";
}

export async function login(_prev: AuthFormState, formData: FormData): Promise<AuthFormState> {
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  const values = { email };

  if (!email || !password) return { error: "required", values };
  if (!EMAIL_RE.test(email)) return { error: "invalidEmail", values };

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) return { error: mapAuthError(error.code, error.message), values };

  // The proxy sends pending members to /pending automatically.
  redirect(safeNext(formData.get("next")));
}

export async function signup(_prev: AuthFormState, formData: FormData): Promise<AuthFormState> {
  const fullName = String(formData.get("fullName") ?? "").trim();
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  const confirm = String(formData.get("confirmPassword") ?? "");
  const values = { fullName, email };

  if (!fullName || !email || !password || !confirm) return { error: "required", values };
  if (!EMAIL_RE.test(email)) return { error: "invalidEmail", values };
  if (password.length < MIN_PASSWORD) return { error: "passwordShort", values };
  if (password.length > MAX_PASSWORD) return { error: "weakPassword", values };
  if (password !== confirm) return { error: "passwordMismatch", values };

  // A fixed site address, never one built from request headers (those can be faked).
  const origin = siteUrl();

  const supabase = await createClient();
  // The profile row is created by the database trigger (handle_new_user) from full_name.
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: {
      data: { full_name: fullName },
      emailRedirectTo: `${origin}/auth/callback?next=/complete-profile`,
    },
  });

  if (error) return { error: mapAuthError(error.code, error.message), values };

  // With email confirmation ON, an existing email returns a user with no identities.
  if (data.user && data.user.identities?.length === 0) return { error: "userExists", values };

  if (data.session) redirect("/complete-profile");
  return { checkEmail: true, values };
}

/** "Forgot password": ALWAYS the same answer, so nobody can find out which emails have an account. */
export async function requestPasswordReset(_prev: AuthFormState, formData: FormData): Promise<AuthFormState> {
  const email = String(formData.get("email") ?? "").trim();
  const values = { email };
  if (!email) return { error: "required", values };
  if (!EMAIL_RE.test(email) || email.length > 320) return { error: "invalidEmail", values };

  const supabase = await createClient();
  // The result is ignored on purpose (unknown email, rate limit, ...): the page always says the same thing.
  await supabase.auth.resetPasswordForEmail(email, { redirectTo: `${siteUrl()}/auth/callback?next=/reset-password` });
  return { sent: true, values };
}

/** Set a new password after the reset link (the link logs the person in, then lands on /reset-password). */
export async function resetPassword(_prev: AuthFormState, formData: FormData): Promise<AuthFormState> {
  const password = String(formData.get("password") ?? "");
  const confirm = String(formData.get("confirmPassword") ?? "");
  if (!password || !confirm) return { error: "required" };
  if (password.length < MIN_PASSWORD) return { error: "passwordShort" };
  if (password.length > MAX_PASSWORD) return { error: "weakPassword" };
  if (password !== confirm) return { error: "passwordMismatch" };

  const supabase = await createClient();
  const { data } = await supabase.auth.getUser();
  if (!data.user) return { error: "resetLinkExpired" };

  const { error } = await supabase.auth.updateUser({ password });
  if (error) return { error: mapAuthError(error.code, error.message) };
  return { done: true };
}

/** "Change password" in My profile: the current password is checked first. */
export async function changePassword(_prev: AuthFormState, formData: FormData): Promise<AuthFormState> {
  const current = String(formData.get("currentPassword") ?? "");
  const password = String(formData.get("password") ?? "");
  const confirm = String(formData.get("confirmPassword") ?? "");
  if (!current || !password || !confirm) return { error: "required" };
  if (password.length < MIN_PASSWORD) return { error: "passwordShort" };
  if (password.length > MAX_PASSWORD) return { error: "weakPassword" };
  if (password !== confirm) return { error: "passwordMismatch" };
  if (password === current) return { error: "samePassword" };

  const supabase = await createClient();
  const { data } = await supabase.auth.getUser();
  const email = data.user?.email;
  if (!email) return { error: "resetLinkExpired" };

  const check = await supabase.auth.signInWithPassword({ email, password: current });
  if (check.error) {
    const key = mapAuthError(check.error.code, check.error.message);
    return { error: key === "invalidCredentials" ? "currentPasswordWrong" : key };
  }

  const { error } = await supabase.auth.updateUser({ password });
  if (error) return { error: mapAuthError(error.code, error.message) };
  return { done: true };
}

export async function logout() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login?loggedOut=1");
}
