import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { ChangePasswordForm } from "@/components/ChangePasswordForm";
import { ProfileForm } from "@/components/ProfileForm";
import { Chip } from "@/components/ui";
import { requireActiveMember } from "@/lib/auth";
import { getI18n } from "@/lib/i18n/server";
import { loadMemberRecord } from "@/lib/members";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "My profile" };

/** Active members view and update their own details and documents. */
export default async function ProfilePage() {
  const [{ t }, me] = await Promise.all([getI18n(), requireActiveMember()]);
  const record = await loadMemberRecord(await createClient(), me.id);
  if (!record) redirect("/home");
  const p = record.profile;

  return (
    <div className="mx-auto w-full max-w-4xl px-4 py-8 sm:py-10">
      <h1 className="text-3xl font-bold tracking-tight">{t.profile.editTitle}</h1>
      <p className="mt-1.5 text-sm text-muted">{t.profile.editSubtitle}</p>
      <div className="mt-4 flex flex-wrap items-center gap-2 text-sm">
        <Chip tone="accent">
          {t.profile.memberNo} {p.memberNo}
        </Chip>
        <Chip>{t.members[`role_${p.role}`]}</Chip>
        {p.joinedOn && (
          <Chip>
            {t.profile.joinedOn}: {p.joinedOn}
          </Chip>
        )}
      </div>
      <p className="mt-2 mb-6 text-xs text-muted">{t.profile.lockedHint}</p>
      <ProfileForm record={record} mode="edit" />
      <div className="mt-8">
        <ChangePasswordForm />
      </div>
    </div>
  );
}
