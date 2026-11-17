import type { Metadata } from "next";
import Link from "next/link";
import { Card } from "@/components/ui";
import { requireAdmin } from "@/lib/auth";
import { getI18n } from "@/lib/i18n/server";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Admin" };

/** Admin area: only active admin / super_admin (checked in the proxy AND here). */
export default async function AdminPage() {
  const [{ t }, profile] = await Promise.all([getI18n(), requireAdmin()]);
  const supabase = await createClient();
  const [{ count }, { count: depositCount }, { count: expenseCount }, { count: investmentCount }] = await Promise.all([
    supabase.from("profiles").select("id", { count: "exact", head: true }).eq("status", "pending"),
    supabase.from("deposits").select("id", { count: "exact", head: true }).eq("status", "pending"),
    supabase.from("money_requests").select("id", { count: "exact", head: true }).eq("status", "pending").in("kind", ["expense", "expense_reversal"]),
    supabase.from("money_requests").select("id", { count: "exact", head: true }).eq("status", "pending").in("kind", ["purchase", "investment_cost", "sale", "income"]),
  ]);

  return (
    <div className="mx-auto w-full max-w-6xl px-4 py-10">
      <h1 className="text-3xl font-bold tracking-tight">{t.admin.title}</h1>
      <p className="mt-2 text-sm text-muted">
        {t.admin.roleLabel}:{" "}
        <span className="font-semibold text-fg">
          {profile.role === "super_admin" ? t.admin.roleSuperAdmin : t.admin.roleAdmin}
        </span>
      </p>
      <div className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <Link href="/admin/members" className="group block">
          <Card className="h-full transition group-hover:border-accent">
            <p className="text-lg font-bold">{t.admin.membersCardTitle}</p>
            <p className="mt-1 text-sm text-muted">{t.admin.membersCardBody}</p>
            {!!count && (
              <p className="mt-4 inline-flex rounded-full bg-gold/20 px-3 py-1 text-sm font-semibold">
                {count} {t.admin.pendingCount}
              </p>
            )}
          </Card>
        </Link>
        <Link href="/admin/deposits" className="group block">
          <Card className="h-full transition group-hover:border-accent">
            <p className="text-lg font-bold">{t.admin.depositsCardTitle}</p>
            <p className="mt-1 text-sm text-muted">{t.admin.depositsCardBody}</p>
            {!!depositCount && (
              <p className="mt-4 inline-flex rounded-full bg-gold/20 px-3 py-1 text-sm font-semibold">
                {depositCount} {t.admin.pendingDepositsCount}
              </p>
            )}
          </Card>
        </Link>
        <Link href="/admin/expenses" className="group block">
          <Card className="h-full transition group-hover:border-accent">
            <p className="text-lg font-bold">{t.admin.expensesCardTitle}</p>
            <p className="mt-1 text-sm text-muted">{t.admin.expensesCardBody}</p>
            {!!expenseCount && (
              <p className="mt-4 inline-flex rounded-full bg-gold/20 px-3 py-1 text-sm font-semibold">
                {expenseCount} {t.admin.pendingMoneyCount}
              </p>
            )}
          </Card>
        </Link>
        <Link href="/admin/investments" className="group block">
          <Card className="h-full transition group-hover:border-accent">
            <p className="text-lg font-bold">{t.admin.investmentsCardTitle}</p>
            <p className="mt-1 text-sm text-muted">{t.admin.investmentsCardBody}</p>
            {!!investmentCount && (
              <p className="mt-4 inline-flex rounded-full bg-gold/20 px-3 py-1 text-sm font-semibold">
                {investmentCount} {t.admin.pendingMoneyCount}
              </p>
            )}
          </Card>
        </Link>
        <Link href="/admin/notices" className="group block">
          <Card className="h-full transition group-hover:border-accent">
            <p className="text-lg font-bold">{t.admin.noticesCardTitle}</p>
            <p className="mt-1 text-sm text-muted">{t.admin.noticesCardBody}</p>
          </Card>
        </Link>
        {profile.role === "super_admin" && (
          <>
            <Link href="/admin/policies" className="group block">
              <Card className="h-full transition group-hover:border-accent">
                <p className="text-lg font-bold">{t.admin.policiesCardTitle}</p>
                <p className="mt-1 text-sm text-muted">{t.admin.policiesCardBody}</p>
              </Card>
            </Link>
            <Link href="/admin/site" className="group block">
              <Card className="h-full transition group-hover:border-accent">
                <p className="text-lg font-bold">{t.admin.siteCardTitle}</p>
                <p className="mt-1 text-sm text-muted">{t.admin.siteCardBody}</p>
              </Card>
            </Link>
          </>
        )}
        {profile.role === "super_admin" && (
          <Link href="/admin/settings" className="group block">
            <Card className="h-full transition group-hover:border-accent">
              <p className="text-lg font-bold">{t.admin.settingsCardTitle}</p>
              <p className="mt-1 text-sm text-muted">{t.admin.settingsCardBody}</p>
            </Card>
          </Link>
        )}
      </div>
    </div>
  );
}
