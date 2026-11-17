import { Logo } from "@/components/Logo";
import { ButtonLink } from "@/components/ui";
import { loadSiteContent, pickText, SITE_KEYS } from "@/lib/content";
import { getI18n } from "@/lib/i18n/server";
import { createClient } from "@/lib/supabase/server";

/**
 * Public landing page: the logo, a few short messages from site_content (editable by the super admin)
 * and the Login / Sign up buttons. No member data, no numbers.
 */
export default async function LandingPage() {
  const { lang, t } = await getI18n();
  const texts = await loadSiteContent(await createClient(), [...SITE_KEYS.messages]);

  const message1 = pickText(texts.get("home_message_1"), lang, t.landing.fallback1);
  const message2 = pickText(texts.get("home_message_2"), lang, t.landing.fallback2);
  const message3 = pickText(texts.get("home_message_3"), lang); // optional: empty = not shown

  return (
    <div className="mx-auto w-full max-w-6xl px-4 pb-16 pt-10 sm:pt-16">
      <section className="grid items-center gap-10 lg:grid-cols-[1.2fr_1fr]">
        <div className="space-y-6">
          <p className="inline-flex items-center gap-2 rounded-full border border-border bg-surface px-3 py-1 text-xs font-semibold uppercase tracking-wide text-accent backdrop-blur">
            <span className="size-1.5 rounded-full bg-gold" />
            {t.landing.eyebrow}
          </p>
          <h1 className="text-4xl font-extrabold leading-tight tracking-tight text-balance sm:text-5xl">{message1}</h1>
          <p className="max-w-xl text-lg text-muted text-pretty">{message2}</p>
          {message3 && <p className="max-w-xl text-base font-medium text-pretty">{message3}</p>}
          <div className="flex flex-wrap gap-3">
            <ButtonLink href="/signup">{t.landing.ctaJoin}</ButtonLink>
            <ButtonLink href="/login" variant="secondary">
              {t.landing.ctaLogin}
            </ButtonLink>
          </div>
        </div>

        <div className="relative mx-auto grid aspect-square w-full max-w-xs place-items-center">
          <div className="absolute inset-0 rounded-full bg-accent-soft blur-2xl" />
          <div className="absolute inset-6 rounded-full border border-dashed border-border" />
          <Logo size={180} className="relative drop-shadow-xl" />
        </div>
      </section>
    </div>
  );
}
