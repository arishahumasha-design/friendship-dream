import type { Metadata } from "next";
import Link from "next/link";
import { Logo } from "@/components/Logo";
import { Card } from "@/components/ui";
import { requireActiveMember } from "@/lib/auth";
import { loadSiteContent, pickText, SITE_KEYS } from "@/lib/content";
import { getI18n } from "@/lib/i18n/server";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "About" };

/** About the samiti: name and logo, a short description and the project start (editable by the super admin). */
export default async function AboutPage() {
  const [{ t, lang }, me] = await Promise.all([getI18n(), requireActiveMember()]);
  const texts = await loadSiteContent(await createClient(), [SITE_KEYS.about, SITE_KEYS.aboutStart]);
  const description = pickText(texts.get(SITE_KEYS.about), lang, t.content.aboutFallback);
  const start = pickText(texts.get(SITE_KEYS.aboutStart), lang, t.content.aboutStartFallback);

  return (
    <div className="mx-auto w-full max-w-3xl px-4 py-8 sm:py-10">
      <Card className="space-y-6 text-center sm:p-10">
        <Logo size={120} className="mx-auto drop-shadow-xl" />
        <div>
          <h1 className="text-3xl font-extrabold tracking-tight">
            {t.common.brand} <span className="text-accent">({t.common.brandShort})</span>
          </h1>
          <p className="mt-1 text-sm text-muted">{t.common.tagline}</p>
        </div>
        <p className="whitespace-pre-line text-lg leading-relaxed text-pretty">{description}</p>
        <div className="mx-auto inline-flex flex-col items-center rounded-2xl border border-border bg-surface-strong/60 px-6 py-3">
          <span className="text-xs text-muted">{t.content.projectStart}</span>
          <span className="text-lg font-bold">{start}</span>
        </div>
      </Card>
      {me.role === "super_admin" && (
        <Link href="/admin/site" className="mt-4 inline-block text-sm font-semibold text-accent hover:underline">
          {t.content.editSite} →
        </Link>
      )}
    </div>
  );
}
