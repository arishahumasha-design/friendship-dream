import type { EmailOtpType } from "@supabase/supabase-js";
import { NextResponse, type NextRequest } from "next/server";
import { safeNext } from "@/lib/safe-redirect";
import { createClient } from "@/lib/supabase/server";

// Only these link types are accepted from the confirmation email.
const OTP_TYPES = new Set<string>(["signup", "email", "magiclink", "recovery", "invite", "email_change"]);

/**
 * Email confirmation link lands here:
 *   - token_hash style (recommended, works when the link is opened on another device / browser):
 *       /auth/callback?token_hash=...&type=email&next=/complete-profile
 *   - PKCE style ("code"), used by the default Supabase template.
 */
export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl;
  const code = searchParams.get("code");
  const tokenHash = searchParams.get("token_hash");
  const type = searchParams.get("type");
  const next = safeNext(searchParams.get("next"), "/pending");

  const supabase = await createClient();
  let ok = false;

  if (code) {
    ok = !(await supabase.auth.exchangeCodeForSession(code)).error;
  } else if (tokenHash && type && OTP_TYPES.has(type)) {
    ok = !(await supabase.auth.verifyOtp({ type: type as EmailOtpType, token_hash: tokenHash })).error;
  }

  const url = request.nextUrl.clone();
  url.search = "";
  url.hash = "";
  if (ok) {
    // "next" may carry its own query ("/deposits?page=2"): split it, never put "?" into the pathname.
    const target = new URL(next, url.origin);
    url.pathname = target.pathname;
    url.search = target.search;
  } else {
    url.pathname = "/login";
    url.searchParams.set("error", "confirm");
  }
  return NextResponse.redirect(url);
}
