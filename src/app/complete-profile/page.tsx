import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ProfileForm } from "@/components/ProfileForm";
import { getCurrentProfile } from "@/lib/auth";
import { getI18n } from "@/lib/i18n/server";
import { loadMemberRecord } from "@/lib/members";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Complete your profile" };

/** Pending members fill in their details and upload documents here. */
export default async function CompleteProfilePage() {
  const [{ t }, me] = await Promise.all([getI18n(), getCurrentProfile()]);
  if (!me) redirect("/login?next=/complete-profile");
  if (me.status === "active") redirect("/profile");
  if (me.status !== "pending") redirect("/pending");

  const record = await loadMemberRecord(await createClient(), me.id);
  if (!record) redirect("/pending");

  return (
    <div className="mx-auto w-full max-w-4xl px-4 py-8 sm:py-10">
      <div className="mb-6 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">{t.profile.completeTitle}</h1>
          <p className="mt-1.5 text-sm text-muted">{t.profile.completeSubtitle}</p>
        </div>
        <Link href="/pending" className="text-sm font-semibold text-accent hover:underline">
          {t.profile.backToStatus}
        </Link>
      </div>
      <ProfileForm record={record} mode="complete" />
    </div>
  );
}
