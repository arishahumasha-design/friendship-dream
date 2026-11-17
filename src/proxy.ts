import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { SUPABASE_PUBLISHABLE_KEY, SUPABASE_URL } from "@/lib/supabase/env";

// Pages that need an ACTIVE member.
const MEMBER_PATHS = [
  "/home",
  "/members",
  "/deposits",
  "/expenses",
  "/investments",
  "/policies",
  "/notices",
  "/profile",
];
const ADMIN_PATHS = ["/admin"];
const AUTH_PAGES = ["/login", "/signup"];

function matches(pathname: string, paths: string[]) {
  return paths.some((p) => pathname === p || pathname.startsWith(p + "/"));
}

export async function proxy(request: NextRequest) {
  let response = NextResponse.next({ request });

  const supabase = createServerClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet, headers) {
        cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        cookiesToSet.forEach(({ name, value, options }) =>
          response.cookies.set(name, value, options),
        );
        Object.entries(headers ?? {}).forEach(([key, value]) =>
          response.headers.set(key, value),
        );
      },
    },
  });

  // Refreshes the session cookie if needed and verifies the JWT.
  const { data: claimsData } = await supabase.auth.getClaims();
  const userId = claimsData?.claims?.sub as string | undefined;

  const { pathname, search } = request.nextUrl;
  const isMemberPath = matches(pathname, MEMBER_PATHS);
  const isAdminPath = matches(pathname, ADMIN_PATHS);
  const isPendingPath = pathname === "/pending";
  // Pending members fill in their profile here; active members use /profile instead.
  const isCompletePath = pathname === "/complete-profile";
  const isAuthPage = matches(pathname, AUTH_PAGES);

  // Redirect while keeping any refreshed auth cookies.
  const redirectTo = (path: string) => {
    const url = request.nextUrl.clone();
    const [p, q] = path.split("?");
    url.pathname = p;
    url.search = q ? `?${q}` : "";
    const res = NextResponse.redirect(url);
    response.cookies.getAll().forEach((c) => res.cookies.set(c));
    res.headers.set("Cache-Control", "private, no-store");
    return res;
  };

  if (!userId) {
    if (isMemberPath || isAdminPath || isPendingPath || isCompletePath) {
      return redirectTo(`/login?next=${encodeURIComponent(pathname + search)}`);
    }
    return response;
  }

  if (!(isMemberPath || isAdminPath || isPendingPath || isCompletePath || isAuthPage)) {
    return response;
  }

  // Own profile row only (RLS).
  const { data: profile } = await supabase
    .from("profiles")
    .select("role, status")
    .eq("id", userId)
    .maybeSingle();

  const isActive = profile?.status === "active";
  const isAdmin = isActive && (profile?.role === "admin" || profile?.role === "super_admin");

  if (isAuthPage) return redirectTo(isActive ? "/home" : "/pending");
  if (isPendingPath) return isActive ? redirectTo("/home") : response;
  if (isCompletePath) {
    if (isActive) return redirectTo("/profile");
    return profile?.status === "pending" ? response : redirectTo("/pending");
  }
  if (!isActive) return redirectTo("/pending");
  if (isAdminPath && !isAdmin) return redirectTo("/home");
  // Settings: super admin only.
  if (matches(pathname, ["/admin/settings"]) && profile?.role !== "super_admin") return redirectTo("/admin");

  return response;
}

export const config = {
  matcher: [
    // Everything except static files and images.
    "/((?!_next/static|_next/image|favicon.ico|icon.svg|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)",
  ],
};
