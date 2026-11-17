import type { Metadata } from "next";
import Link from "next/link";
import { SettingsForm } from "@/components/SettingsForm";
import { requireSuperAdmin } from "@/lib/auth";
import { getI18n } from "@/lib/i18n/server";
import { loadSettings } from "@/lib/settings";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Settings" };

/** Super admin only (checked in the proxy, here, and by RLS on app_settings). */
export default async function AdminSettingsPage() {
  const [{ t }] = await Promise.all([getI18n(), requireSuperAdmin()]);
  const settings = await loadSettings(await createClient());

  return (
    <div className="mx-auto w-full max-w-3xl px-4 py-8 sm:py-10">
      <Link href="/admin" className="text-sm font-semibold text-accent hover:underline">
        ← {t.admin.title}
      </Link>
      <h1 className="mt-2 text-3xl font-bold tracking-tight">{t.settings.title}</h1>
      <p className="mt-1.5 mb-6 text-sm text-muted">{t.settings.subtitle}</p>
      <SettingsForm initial={settings} />
    </div>
  );
}
