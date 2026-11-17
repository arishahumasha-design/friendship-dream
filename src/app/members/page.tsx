import type { Metadata } from "next";
import Link from "next/link";
import { Avatar } from "@/components/MemberBits";
import { Alert, Card, Chip } from "@/components/ui";
import { isAdminRole, requireActiveMember } from "@/lib/auth";
import { loadMemberTotals, signAvatars } from "@/lib/dashboard";
import { formatMonth, formatTaka, currentMonthDhaka } from "@/lib/format";
import { getI18n } from "@/lib/i18n/server";
import { loadSettings } from "@/lib/settings";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Members" };

/** Directory of active members. member_totals() already hides others when the setting is off. */
export default async function MembersPage() {
  const [{ t, lang }, me] = await Promise.all([getI18n(), requireActiveMember()]);
  const supabase = await createClient();
  const [totals, settings] = await Promise.all([loadMemberTotals(supabase), loadSettings(supabase)]);

  const members = (totals ?? []).filter((m) => m.status === "active");
  const avatars = await signAvatars(supabase, members);
  const onlyYou = !isAdminRole(me.role) && !settings.membersCanSeeOthers;

  return (
    <div className="mx-auto w-full max-w-6xl px-4 py-8 sm:py-10">
      <h1 className="text-3xl font-bold tracking-tight">{t.directory.title}</h1>
      <p className="mt-1.5 text-sm text-muted">{t.directory.subtitle}</p>

      <div className="mt-6 space-y-4">
        {totals === null && <Alert>{t.directory.loadError}</Alert>}
        {onlyYou && <p className="rounded-2xl bg-fg/5 px-4 py-3 text-sm text-muted">{t.directory.onlyYou}</p>}

        {totals !== null && members.length === 0 && (
          <Card className="text-center text-sm text-muted">{t.directory.empty}</Card>
        )}

        <ul className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {members.map((m) => (
            <li key={m.id}>
              <Link href={`/members/${m.id}`} className="group block h-full">
                <Card className="h-full space-y-4 p-5 transition group-hover:border-accent sm:p-5">
                  <div className="flex items-center gap-3">
                    <Avatar url={avatars.get(m.id)} name={m.name} size={56} />
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold">{m.name || "—"}</p>
                      <p className="text-xs text-muted">
                        {t.directory.memberNo} {m.memberNo}
                      </p>
                    </div>
                    <Chip tone={m.paidThisMonth ? "accent" : "gold"}>
                      {m.paidThisMonth ? t.directory.paid : t.directory.pending}
                    </Chip>
                  </div>
                  <dl className="grid grid-cols-2 gap-3 text-sm">
                    <div className="min-w-0">
                      <dt className="text-xs text-muted">{t.directory.capital}</dt>
                      <dd className="mt-0.5 truncate font-bold">{formatTaka(m.capital)}</dd>
                    </div>
                    <div>
                      <dt className="text-xs text-muted">{t.directory.shares}</dt>
                      <dd className="mt-0.5 font-bold">{m.shares}</dd>
                    </div>
                  </dl>
                  <p className="text-xs text-muted">
                    {t.directory.paidThisMonth}: {formatMonth(currentMonthDhaka(), lang)}
                  </p>
                </Card>
              </Link>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
