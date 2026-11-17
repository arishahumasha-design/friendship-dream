import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { logout } from "@/app/actions/auth";
import { AuthShell } from "@/components/AuthShell";
import { Button, ButtonLink } from "@/components/ui";
import { getCurrentProfile } from "@/lib/auth";
import { getI18n } from "@/lib/i18n/server";

export const metadata: Metadata = { title: "Log out" };

/** Confirm page; logging out is a POST (server action), never a plain link. */
export default async function LogoutPage() {
  const [{ t }, profile] = await Promise.all([getI18n(), getCurrentProfile()]);
  if (!profile) redirect("/login");

  return (
    <AuthShell title={t.auth.logoutTitle} subtitle={t.auth.logoutBody}>
      <form action={logout} className="flex flex-col gap-3">
        <Button type="submit">{t.auth.logoutConfirm}</Button>
        <ButtonLink href="/home" variant="secondary">
          {t.auth.cancel}
        </ButtonLink>
      </form>
    </AuthShell>
  );
}
