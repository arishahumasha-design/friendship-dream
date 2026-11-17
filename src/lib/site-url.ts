const FALLBACK = "http://localhost:3000";

/**
 * The public address of this website, used in links inside emails (e.g. the signup confirmation).
 * Set NEXT_PUBLIC_SITE_URL in .env.local (and in Vercel), e.g. https://fd-samiti.vercel.app
 * It is never taken from request headers, which a visitor could fake.
 *
 * On Vercel production a missing or invalid address is an error (never the localhost fallback),
 * so a confirmation email can never point at localhost.
 */
export function siteUrl(): string {
  const production = process.env.VERCEL_ENV === "production";
  const raw = process.env.NEXT_PUBLIC_SITE_URL?.trim();
  if (!raw) {
    if (production) throw new Error("NEXT_PUBLIC_SITE_URL is not set (required in production).");
    return FALLBACK;
  }
  try {
    const u = new URL(raw);
    if (u.protocol !== "https:" && u.protocol !== "http:") throw new Error("bad protocol");
    if (production && u.protocol !== "https:") throw new Error("not https");
    return u.origin;
  } catch {
    if (production) throw new Error("NEXT_PUBLIC_SITE_URL must be a valid https address in production.");
    return FALLBACK;
  }
}
