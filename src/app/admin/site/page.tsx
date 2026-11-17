import type { Metadata } from "next";
import Link from "next/link";
import { SiteTextForm } from "@/components/ContentForms";
import { requireSuperAdmin } from "@/lib/auth";
import { loadSiteContent, SITE_KEYS } from "@/lib/content";
import { getI18n } from "@/lib/i18n/server";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Site content" };

/** Super admin only: the short messages on the public front page, and the About page texts. */
export default async function AdminSitePage() {
  const [{ t }] = await Promise.all([getI18n(), requireSuperAdmin()]);
  const texts = await loadSiteContent(await createClient(), [...SITE_KEYS.messages, SITE_KEYS.about, SITE_KEYS.aboutStart]);
  const get = (k: string) => texts.get(k) ?? { en: "", bn: "" };
  const labels = [t.content.message1, t.content.message2, t.content.message3];

  return (
    <div className="mx-auto w-full max-w-3xl px-4 py-8 sm:py-10">
      <Link href="/admin" className="text-sm font-semibold text-accent hover:underline">
        ← {t.admin.title}
      </Link>
      <h1 className="mt-2 text-3xl font-bold tracking-tight">{t.content.siteTitle}</h1>
      <p className="mt-1.5 text-sm text-muted">{t.content.siteSubtitle}</p>

      <div className="mt-6 space-y-4">
        <h2 className="text-xl font-bold">{t.content.landingMessages}</h2>
        <p className="text-sm text-muted">{t.content.landingHint}</p>
        {SITE_KEYS.messages.map((k, i) => (
          <SiteTextForm key={k} keyName={k} label={labels[i]} hint={i === 2 ? t.content.optionalEmpty : undefined} en={get(k).en} bn={get(k).bn} />
        ))}
        <h2 className="pt-4 text-xl font-bold">{t.content.aboutPageTexts}</h2>
        <SiteTextForm keyName={SITE_KEYS.about} label={t.content.aboutDescription} en={get(SITE_KEYS.about).en} bn={get(SITE_KEYS.about).bn} multiline />
        <SiteTextForm keyName={SITE_KEYS.aboutStart} label={t.content.projectStart} hint={t.content.projectStartHint} en={get(SITE_KEYS.aboutStart).en} bn={get(SITE_KEYS.aboutStart).bn} />
      </div>
    </div>
  );
}
