import type { Metadata } from "next";
import Link from "next/link";
import { NoticeAdminRow, NoticeForm } from "@/components/ContentForms";
import { Card } from "@/components/ui";
import { requireAdmin } from "@/lib/auth";
import { loadNotices } from "@/lib/content";
import { formatDateTime } from "@/lib/format";
import { getI18n } from "@/lib/i18n/server";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Post a notice" };

/** Any admin can post a notice; members only read them in /notices. */
export default async function AdminNoticesPage() {
  const [{ t, lang }] = await Promise.all([getI18n(), requireAdmin()]);
  const { rows } = await loadNotices(await createClient(), [0, 19]);

  return (
    <div className="mx-auto w-full max-w-3xl px-4 py-8 sm:py-10">
      <Link href="/admin" className="text-sm font-semibold text-accent hover:underline">
        ← {t.admin.title}
      </Link>
      <h1 className="mt-2 text-3xl font-bold tracking-tight">{t.content.noticesAdminTitle}</h1>
      <p className="mt-1.5 text-sm text-muted">{t.content.noticesAdminSubtitle}</p>
      <div className="mt-6 space-y-4">
        <NoticeForm />
        <h2 className="pt-2 text-lg font-bold">{t.content.recentNotices}</h2>
        {rows.length === 0 ? (
          <Card className="text-center text-sm text-muted">{t.content.noNotices}</Card>
        ) : (
          <ul className="space-y-3">
            {rows.map((n) => (
              <li key={n.id}>
                <NoticeAdminRow notice={n} when={formatDateTime(n.createdAt, lang)} />
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
