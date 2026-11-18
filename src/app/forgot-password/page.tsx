import type { Metadata } from "next";
import { AuthShell } from "@/components/AuthShell";
import { getI18n } from "@/lib/i18n/server";
import { ForgotForm } from "./ForgotForm";

export const metadata: Metadata = { title: "Forgot password" };

export default async function ForgotPasswordPage() {
  const { t } = await getI18n();
  return (
    <AuthShell title={t.auth.forgotTitle} subtitle={t.auth.forgotSubtitle}>
      <ForgotForm />
    </AuthShell>
  );
}
