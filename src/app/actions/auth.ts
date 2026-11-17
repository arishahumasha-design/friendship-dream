"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import type { ErrorKey } from "@/lib/i18n/types";
import { safeNext } from "@/lib/safe-redirect";
import { siteUrl } from "@/lib/site-url";

export type AuthFormState = {
  error?: ErrorKey;
  checkEmail?: boolean;
  values?: { fullName?: string; email?: string };
};

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

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
  if (password.length < 8) return { error: "passwordShort", values };
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

export async function logout() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login?loggedOut=1");
}
