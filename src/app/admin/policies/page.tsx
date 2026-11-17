import type { Metadata } from "next";
import Link from "next/link";
import { PolicyAdminRow, PolicyEditor } from "@/components/ContentForms";
import { Card } from "@/components/ui";
import { requireSuperAdmin } from "@/lib/auth";
import { loadPolicies } from "@/lib/content";
import { todayInDhakaPlain } from "@/lib/format";
import { getI18n } from "@/lib/i18n/server";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Manage policies" };

/** Super admin only: add, edit, reorder and hide policies. Nothing is ever deleted; every change is audit-logged. */
export default async function AdminPoliciesPage() {
  const [{ t, lang }] = await Promise.all([getI18n(), requireSuperAdmin()]);
  const { rows } = await loadPolicies(await createClient(), { includeHidden: true });
  const today = todayInDhakaPlain();

  return (
    <div className="mx-auto w-full max-w-3xl px-4 py-8 sm:py-10">
      <Link href="/admin" className="text-sm font-semibold text-accent hover:underline">
        ← {t.admin.title}
      </Link>
      <h1 className="mt-2 text-3xl font-bold tracking-tight">{t.content.policiesAdminTitle}</h1>
      <p className="mt-1.5 text-sm text-muted">{t.content.policiesAdminSubtitle}</p>

      <div className="mt-6 space-y-4">
        <Card className="space-y-4">
          <h2 className="text-lg font-bold">{t.content.addPolicy}</h2>
          <PolicyEditor today={today} />
        </Card>
        <ul className="space-y-3">
          {rows.map((p, i) => (
            <li key={p.id}>
              <PolicyAdminRow policy={p} number={i + 1} first={i === 0} last={i === rows.length - 1} today={today} lang={lang} />
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
