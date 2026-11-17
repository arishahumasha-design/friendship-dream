import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { logout } from "@/app/actions/auth";
import { AuthShell } from "@/components/AuthShell";
import { Checklist } from "@/components/ProfileForm";
import { Button, ButtonLink } from "@/components/ui";
import { getCurrentProfile } from "@/lib/auth";
import { getI18n } from "@/lib/i18n/server";
import { loadMemberRecord } from "@/lib/members";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Account status" };

export default async function PendingPage() {
  const [{ t }, profile] = await Promise.all([getI18n(), getCurrentProfile()]);
  if (!profile) redirect("/login");
  if (profile.status === "active") redirect("/home");

  const isPending = profile.status === "pending";
  const record = isPending ? await loadMemberRecord(await createClient(), profile.id) : null;

  const { title, body } =
    profile.status === "suspended"
      ? { title: t.pending.suspendedTitle, body: t.pending.suspendedBody }
      : profile.status === "exited"
        ? { title: t.pending.exitedTitle, body: t.pending.exitedBody }
        : { title: t.pending.title, body: t.pending.body };

  return (
    <AuthShell title={title}>
      <div className="space-y-5 text-center">
        <div className="mx-auto grid size-14 place-items-center rounded-full bg-gold/15 text-2xl">
          <span aria-hidden>⏳</span>
        </div>
        <p className="text-muted">{body}</p>

        {record?.profile.reviewNote && (
          <div className="rounded-2xl border border-gold/50 bg-gold/10 p-4 text-left">
            <p className="text-sm font-semibold">{t.profile.adminNoteTitle}</p>
            <p className="mt-1 whitespace-pre-line text-sm">{record.profile.reviewNote}</p>
          </div>
        )}

        {record && (
          <div className="text-left">
            <Checklist missing={record.missing} />
          </div>
        )}

        {isPending && (
          <ButtonLink href="/complete-profile" className="w-full">
            {record && record.missing.length === 0 ? t.pending.editCta : t.pending.completeCta}
          </ButtonLink>
        )}

        {profile.email && (
          <p className="text-xs text-muted">
            {t.pending.signedInAs} <span className="font-medium text-fg">{profile.email}</span>
          </p>
        )}
        <form action={logout}>
          <Button type="submit" variant="secondary" className="w-full">
            {t.common.logout}
          </Button>
        </form>
      </div>
    </AuthShell>
  );
}
