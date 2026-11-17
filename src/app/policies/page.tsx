import type { Metadata } from "next";
import Link from "next/link";
import { PolicyList } from "@/components/PolicyList";
import { Alert, Card } from "@/components/ui";
import { requireActiveMember } from "@/lib/auth";
import { loadPolicies } from "@/lib/content";
import { getI18n } from "@/lib/i18n/server";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Policies" };

/** The samiti's policies, in their saved order, as stored (Bengali text is shown unchanged). */
export default async function PoliciesPage() {
  const [{ t }, me] = await Promise.all([getI18n(), requireActiveMember()]);
  const { rows, failed } = await loadPolicies(await createClient());

  return (
    <div className="mx-auto w-full max-w-3xl px-4 py-8 sm:py-10">
      <h1 className="text-3xl font-bold tracking-tight">{t.content.policiesTitle}</h1>
      <p className="mt-1.5 text-sm text-muted">{t.content.policiesSubtitle}</p>
      {me.role === "super_admin" && (
        <Link href="/admin/policies" className="mt-3 inline-block text-sm font-semibold text-accent hover:underline">
          {t.content.managePolicies} →
        </Link>
      )}
      <div className="mt-6">
        {failed && <Alert>{t.content.errGeneric}</Alert>}
        {!failed && rows.length === 0 ? (
          <Card className="text-center text-sm text-muted">{t.content.emptyPolicies}</Card>
        ) : (
          <PolicyList policies={rows} />
        )}
      </div>
    </div>
  );
}
