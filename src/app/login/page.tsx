import type { Metadata } from "next";
import { AuthShell } from "@/components/AuthShell";
import { getI18n } from "@/lib/i18n/server";
import { LoginForm } from "./LoginForm";

export const metadata: Metadata = { title: "Log in" };

export default async function LoginPage({ searchParams }: PageProps<"/login">) {
  const { t } = await getI18n();
  const sp = await searchParams;
  const next = typeof sp.next === "string" ? sp.next : undefined;
  const notice = sp.loggedOut ? "loggedOut" : sp.error === "confirm" ? "confirm" : undefined;

  return (
    <AuthShell title={t.auth.loginTitle} subtitle={t.auth.loginSubtitle}>
      <LoginForm next={next} notice={notice} />
    </AuthShell>
  );
}
