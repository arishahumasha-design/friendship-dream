import type { Metadata } from "next";
import Link from "next/link";
import { Pager } from "@/components/Pager";
import { Alert, Card, Chip } from "@/components/ui";
import { isAdminRole, requireActiveMember } from "@/lib/auth";
import { loadNotices } from "@/lib/content";
import { formatDateTime } from "@/lib/format";
import { getI18n } from "@/lib/i18n/server";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Notices" };

const PAGE_SIZE = 20;

/** Notices for all active members (read only; admins post them in /admin/notices). */
export default async function NoticesPage({ searchParams }: PageProps<"/notices">) {
  const [{ t, lang }, me] = await Promise.all([getI18n(), requireActiveMember()]);
  const sp = await searchParams;
  const page = Math.max(1, Math.floor(Number(typeof sp.page === "string" ? sp.page : 1)) || 1);
  const { rows, count, failed } = await loadNotices(await createClient(), [(page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1]);

  return (
    <div className="mx-auto w-full max-w-3xl px-4 py-8 sm:py-10">
      <h1 className="text-3xl font-bold tracking-tight">{t.content.noticesTitle}</h1>
      <p className="mt-1.5 text-sm text-muted">{t.content.noticesSubtitle}</p>
      {isAdminRole(me.role) && (
        <Link href="/admin/notices" className="mt-3 inline-block text-sm font-semibold text-accent hover:underline">
          {t.content.postNotice} →
        </Link>
      )}
      <div className="mt-6 space-y-4">
        {failed && <Alert>{t.content.errGeneric}</Alert>}
        {!failed && rows.length === 0 && <Card className="text-center text-sm text-muted">{t.content.noNotices}</Card>}
        <ul className="space-y-3">
          {rows.map((n) => (
            <li key={n.id}>
              <Card className={n.pinned ? "space-y-2 border-gold p-5 sm:p-6" : "space-y-2 p-5 sm:p-6"}>
                <div className="flex flex-wrap items-start gap-2">
                  <h2 className="min-w-0 flex-1 break-words text-lg font-bold leading-snug">{n.title}</h2>
                  {n.pinned && <Chip tone="gold">{t.content.pinnedChip}</Chip>}
                </div>
                <p className="text-xs text-muted">{formatDateTime(n.createdAt, lang)}</p>
                <p className="whitespace-pre-line break-words text-[0.95rem] leading-relaxed">{n.body}</p>
              </Card>
            </li>
          ))}
        </ul>
        <Pager page={page} totalPages={Math.max(1, Math.ceil(count / PAGE_SIZE))} hrefFor={(p) => `/notices?page=${p}`} />
      </div>
    </div>
  );
}
