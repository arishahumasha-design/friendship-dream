import type { NextConfig } from "next";

// Security headers for every response.
// CSP notes:
//  - Next.js adds small inline scripts (and we have a tiny theme script), so script-src needs 'unsafe-inline'.
//    ('unsafe-eval' is added in development only: the dev tools need it.)
//  - Everything else is locked to this site and to the Supabase project (images from signed storage URLs,
//    API / realtime calls, and frames). Photos can also be previewed from blob: / data: URLs.
const isDev = process.env.NODE_ENV !== "production";

function supabaseOrigins(): { http: string; ws: string } | null {
  try {
    const u = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? "");
    return { http: u.origin, ws: `wss://${u.host}` };
  } catch {
    return null;
  }
}

function contentSecurityPolicy(): string {
  const sb = supabaseOrigins();
  const sbHttp = sb ? [sb.http] : [];
  const directives: Record<string, string[]> = {
    "default-src": ["'self'"],
    "script-src": ["'self'", "'unsafe-inline'", ...(isDev ? ["'unsafe-eval'"] : [])],
    "style-src": ["'self'", "'unsafe-inline'"],
    "img-src": ["'self'", "data:", "blob:", ...sbHttp],
    "font-src": ["'self'", "data:"],
    "connect-src": ["'self'", ...sbHttp, ...(sb ? [sb.ws] : []), ...(isDev ? ["ws://localhost:*", "http://localhost:*"] : [])],
    "frame-src": sbHttp.length ? sbHttp : ["'none'"],
    "frame-ancestors": ["'none'"],
    "object-src": ["'none'"],
    "base-uri": ["'self'"],
    "form-action": ["'self'"],
  };
  const parts = Object.entries(directives).map(([k, v]) => `${k} ${v.join(" ")}`);
  if (!isDev) parts.push("upgrade-insecure-requests");
  return parts.join("; ");
}

const securityHeaders = [
  { key: "Content-Security-Policy", value: contentSecurityPolicy() },
  { key: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  {
    key: "Permissions-Policy",
    value: "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()",
  },
];

// Cache Components is intentionally OFF: almost every page here depends on the
// logged-in user's session cookie, so classic dynamic rendering is simpler and safer.
const nextConfig: NextConfig = {
  poweredByHeader: false,
  async headers() {
    return [{ source: "/:path*", headers: securityHeaders }];
  },
  turbopack: {
    root: process.cwd(),
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

export default nextConfig;
