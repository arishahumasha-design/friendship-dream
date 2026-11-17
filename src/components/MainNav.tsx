"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useI18n } from "./I18nProvider";
import { cn } from "./ui";

/**
 * Main menu for logged-in ACTIVE members. A scrollable strip under the header, so it works
 * on phones too. The current section is highlighted.
 */
export function MainNav({ isAdmin, pinnedNotices = 0 }: { isAdmin: boolean; pinnedNotices?: number }) {
  const { t } = useI18n();
  const pathname = usePathname();

  const items = [
    { href: "/home", label: t.nav.home },
    { href: "/members", label: t.nav.members },
    { href: "/deposits", label: t.nav.deposits },
    { href: "/investments", label: t.nav.investments },
    { href: "/policies", label: t.nav.policies },
    { href: "/notices", label: t.nav.notices },
    { href: "/about", label: t.nav.about },
    { href: "/profile", label: t.nav.profile },
    ...(isAdmin ? [{ href: "/admin", label: t.common.admin }] : []),
  ];

  return (
    <nav aria-label="Main" className="border-t border-border/60">
      <ul className="mx-auto flex max-w-6xl gap-1 overflow-x-auto px-3 py-1.5">
        {items.map((item) => {
          const current = pathname === item.href || pathname.startsWith(item.href + "/");
          return (
            <li key={item.href} className="shrink-0">
              <Link
                href={item.href}
                aria-current={current ? "page" : undefined}
                className={cn(
                  "inline-flex h-9 items-center rounded-full px-3.5 text-sm font-medium transition",
                  current ? "bg-accent text-accent-fg" : "text-fg hover:bg-accent-soft",
                )}
              >
                {item.label}
                {item.href === "/notices" && pinnedNotices > 0 && (
                  <span
                    role="img"
                    aria-label={t.nav.pinnedBadge.replace("{n}", String(pinnedNotices))}
                    className="ms-1.5 inline-flex h-5 min-w-5 items-center justify-center rounded-full bg-gold px-1.5 text-xs font-bold leading-none text-black"
                  >
                    {pinnedNotices > 99 ? "99+" : pinnedNotices}
                  </span>
                )}
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
