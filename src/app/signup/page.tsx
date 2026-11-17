import type { Metadata } from "next";
import { AuthShell } from "@/components/AuthShell";
import { getI18n } from "@/lib/i18n/server";
import { SignupForm } from "./SignupForm";

export const metadata: Metadata = { title: "Sign up" };

export default async function SignupPage() {
  const { t } = await getI18n();
  return (
    <AuthShell title={t.auth.signupTitle} subtitle={t.auth.signupSubtitle}>
      <SignupForm />
    </AuthShell>
  );
}
