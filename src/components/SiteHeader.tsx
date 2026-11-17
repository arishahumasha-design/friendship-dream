import Link from "next/link";
import { logout } from "@/app/actions/auth";
import { getCurrentProfile, isAdminRole } from "@/lib/auth";
import { countPinnedNotices } from "@/lib/content";
import { getI18n } from "@/lib/i18n/server";
import { createClient } from "@/lib/supabase/server";
import { LanguageToggle } from "./LanguageToggle";
import { MainNav } from "./MainNav";
import { Logo } from "./Logo";
import { ThemeToggle } from "./ThemeToggle";
import { ButtonLink } from "./ui";

export async function SiteHeader() {
  const [{ t }, profile] = await Promise.all([getI18n(), getCurrentProfile()]);
  const active = profile?.status === "active";
  const pinned = profile && active ? await countPinnedNotices(await createClient()) : 0;

  return (
    <header className="sticky top-0 z-30 border-b border-border bg-bg/70 backdrop-blur-xl">
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between gap-3 px-4">
        <Link href={active ? "/home" : "/"} className="flex min-w-0 items-center gap-2.5">
          <Logo size={36} />
          <span className="truncate text-base font-bold tracking-tight">{t.common.brand}</span>
        </Link>

        <nav className="flex shrink-0 items-center gap-1.5 sm:gap-2">
          <LanguageToggle />
          <ThemeToggle />
          {profile ? (
            <form action={logout}>
              <button
                type="submit"
                className="inline-flex h-10 items-center whitespace-nowrap rounded-full px-3 text-sm font-medium text-fg hover:bg-accent-soft"
              >
                {t.common.logout}
              </button>
            </form>
          ) : (
            <ButtonLink href="/login" className="h-10 px-4">
              {t.common.login}
            </ButtonLink>
          )}
        </nav>
      </div>
      {profile && active && <MainNav isAdmin={isAdminRole(profile.role)} pinnedNotices={pinned} />}
    </header>
  );
}
