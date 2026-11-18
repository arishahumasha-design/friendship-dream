import type { Metadata } from "next";
import { AuthShell } from "@/components/AuthShell";
import { Alert, ButtonLink } from "@/components/ui";
import { getI18n } from "@/lib/i18n/server";
import { createClient } from "@/lib/supabase/server";
import { ResetForm } from "./ResetForm";

export const metadata: Metadata = { title: "Reset password" };

/** The reset link logs the person in (via /auth/callback) and lands here. No session = expired link. */
export default async function ResetPasswordPage() {
  const { t } = await getI18n();
  const supabase = await createClient();
  const { data } = await supabase.auth.getUser();

  if (!data.user) {
    return (
      <AuthShell title={t.auth.resetLinkExpiredTitle} subtitle="">
        <div className="space-y-4 text-center">
          <Alert>{t.errors.resetLinkExpired}</Alert>
          <ButtonLink href="/forgot-password" className="w-full">
            {t.auth.forgotButton}
          </ButtonLink>
        </div>
      </AuthShell>
    );
  }

  return (
    <AuthShell title={t.auth.resetTitle} subtitle={t.auth.resetSubtitle}>
      <ResetForm />
    </AuthShell>
  );
}
