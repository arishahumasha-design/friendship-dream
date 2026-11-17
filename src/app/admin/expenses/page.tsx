import type { Metadata } from "next";
import Link from "next/link";
import { signExpenseReceipt } from "@/app/actions/files";
import { ExpenseForm, ReverseExpense } from "@/components/ExpenseForms";
import { Pager } from "@/components/Pager";
import { ReceiptButton } from "@/components/ReceiptButton";
import { RequestActions } from "@/components/RequestActions";
import { Alert, Card, Chip, cn } from "@/components/ui";
import { requireAdmin } from "@/lib/auth";
import { formatDay, formatTaka, todayInDhakaPlain } from "@/lib/format";
import { getI18n } from "@/lib/i18n/server";
import { loadCategories, loadExpenses, loadInvestments, loadPeople, loadRequests, type ExpenseRow, type MoneyRequest } from "@/lib/moneyData";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Expenses" };

const TABS = ["pending", "approved", "rejected"] as const;
type Tab = (typeof TABS)[number];
const PAGE_SIZE = 50;

export default async function AdminExpensesPage({ searchParams }: PageProps<"/admin/expenses">) {
  const [{ t, lang }, me] = await Promise.all([getI18n(), requireAdmin()]);
  const sp = await searchParams;
  const one = (v: string | string[] | undefined) => (typeof v === "string" ? v : "");
  const tab: Tab = (TABS as readonly string[]).includes(one(sp.tab)) ? (one(sp.tab) as Tab) : "pending";
  const flash = one(sp.flash);
  const page = Math.max(1, Math.floor(Number(one(sp.page) || 1)) || 1);
  const range: [number, number] = [(page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1];
  const supabase = await createClient();

  const [categories, investments, people, pendingReq, rejectedReq, approved, reversalLinks] = await Promise.all([
    loadCategories(supabase),
    loadInvestments(supabase),
    loadPeople(supabase),
    loadRequests(supabase, { kinds: ["expense", "expense_reversal"], status: "pending" }),
    loadRequests(supabase, { kinds: ["expense", "expense_reversal"], status: "rejected", range: tab === "rejected" ? range : [0, 0] }),
    loadExpenses(supabase, tab === "approved" ? range : [0, 0]),
    supabase.from("expenses").select("reverses_expense_id").not("reverses_expense_id", "is", null),
  ]);

  const catName = new Map(categories.map((c) => [c.id, c.name]));
  const invName = new Map(investments.rows.map((i) => [i.id, i.title]));
  const reversed = new Set(((reversalLinks.data ?? []) as { reverses_expense_id: string }[]).map((r) => r.reverses_expense_id));
  const reversalWaiting = new Set(pendingReq.rows.filter((r) => r.kind === "expense_reversal").map((r) => r.reversesExpenseId));
  const who = (id: string | null) => (id ? (people.get(id) ?? "—") : "—");

  // the originals that waiting reversals point at
  const origIds = [...new Set([...pendingReq.rows, ...rejectedReq.rows].map((r) => r.reversesExpenseId).filter((x): x is string => !!x))];
  const origs = new Map<string, { title: string; amount: number }>();
  if (origIds.length) {
    const { data } = await supabase.from("expenses").select("id, title, amount").in("id", origIds);
    for (const o of (data ?? []) as { id: string; title: string; amount: number }[]) origs.set(o.id, { title: o.title, amount: Number(o.amount) });
  }

  const counts = { pending: pendingReq.rows.length };
  const tabLabel: Record<Tab, string> = { pending: t.money.tabWaiting, approved: t.money.tabApproved, rejected: t.money.tabRejected };
  const today = todayInDhakaPlain();

  const requestCard = (r: MoneyRequest) => {
    const isReversal = r.kind === "expense_reversal";
    const orig = r.reversesExpenseId ? origs.get(r.reversesExpenseId) : undefined;
    return (
      <li key={r.id}>
        <Card className="space-y-3 p-4 sm:p-5">
          <div className="flex flex-wrap items-start justify-between gap-2">
            <div className="min-w-0">
              <p className="font-semibold">{isReversal ? `${t.money.reversalOf}: ${orig?.title ?? "—"}` : r.title}</p>
              <p className="text-xs text-muted">
                {formatDay(r.eventDate, lang)}
                {r.categoryId ? ` · ${catName.get(r.categoryId) ?? ""}` : ""}
                {" · "}
                {r.investmentId ? (invName.get(r.investmentId) ?? "—") : t.money.expenseGeneral}
              </p>
            </div>
            <div className="text-right">
              <p className="text-xl font-bold">{formatTaka(r.amount)}</p>
              <Chip tone={isReversal ? "gold" : "neutral"}>{t.money[`requestKind_${r.kind}`]}</Chip>
            </div>
          </div>
          <p className="text-xs text-muted">{r.investmentId ? t.money.splitInvestment : t.money.splitGeneral}</p>
          {r.description && <p className="whitespace-pre-line text-sm text-muted">{r.description}</p>}
          <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted">
            <span>{t.money.maker}: {who(r.proposedBy)}</span>
            {r.spentBy && <span>{t.money.spentBy}: {r.spentBy}</span>}
            {r.status === "rejected" && <span>{t.money.rejectedBy}: {who(r.decidedBy)}</span>}
          </div>
          {r.status === "rejected" && r.rejectReason && (
            <p className="rounded-2xl bg-danger-soft px-4 py-2 text-sm text-danger">
              <span className="font-semibold">{t.money.reasonLabel}:</span> {r.rejectReason}
            </p>
          )}
          {r.hasReceipt && (
            <ReceiptButton sign={signExpenseReceipt.bind(null, "request", r.id)} isPdf={r.receiptIsPdf} label={t.money.viewReceipt} />
          )}
          {r.status === "pending" && <RequestActions requestId={r.id} kind={r.kind} blocked={r.proposedBy === me.id} />}
        </Card>
      </li>
    );
  };

  const expenseCard = (e: ExpenseRow) => {
    const isReversal = e.reversesExpenseId !== null;
    const canReverse = !isReversal && !reversed.has(e.id) && !reversalWaiting.has(e.id);
    return (
      <li key={e.id}>
        <Card className="space-y-3 p-4 sm:p-5">
          <div className="flex flex-wrap items-start justify-between gap-2">
            <div className="min-w-0">
              <p className="font-semibold">{e.title}</p>
              <p className="text-xs text-muted">
                {formatDay(e.spentOn, lang)}
                {e.categoryId ? ` · ${catName.get(e.categoryId) ?? ""}` : ""}
                {" · "}
                {e.investmentId ? (invName.get(e.investmentId) ?? "—") : t.money.expenseGeneral}
              </p>
            </div>
            <div className="text-right">
              <p className={cn("text-xl font-bold", isReversal && "text-accent")}>{formatTaka(e.amount)}</p>
              <div className="flex justify-end gap-1.5">
                {isReversal && <Chip tone="gold">{t.money.reversalChip}</Chip>}
                {reversed.has(e.id) && <Chip>{t.money.reversedChip}</Chip>}
              </div>
            </div>
          </div>
          {e.description && <p className="whitespace-pre-line text-sm text-muted">{e.description}</p>}
          <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted">
            <span>{t.money.maker}: {who(e.createdBy)}</span>
            <span>{t.money.checker}: {who(e.approvedBy)}</span>
            {e.spentBy && <span>{t.money.spentBy}: {e.spentBy}</span>}
          </div>
          {e.hasReceipt && <ReceiptButton sign={signExpenseReceipt.bind(null, "expense", e.id)} isPdf={e.receiptIsPdf} label={t.money.viewReceipt} />}
          {canReverse && <ReverseExpense expenseId={e.id} />}
          {!isReversal && reversalWaiting.has(e.id) && <p className="text-xs font-medium text-muted">{t.money.reversalWaiting}</p>}
        </Card>
      </li>
    );
  };

  const total = tab === "approved" ? approved.count : tab === "rejected" ? rejectedReq.count : 0;
  const empty = tab === "pending" ? pendingReq.rows.length === 0 : tab === "approved" ? approved.rows.length === 0 : rejectedReq.rows.length === 0;

  return (
    <div className="mx-auto w-full max-w-4xl px-4 py-8 sm:py-10">
      <Link href="/admin" className="text-sm font-semibold text-accent hover:underline">
        ← {t.admin.title}
      </Link>
      <h1 className="mt-2 text-3xl font-bold tracking-tight">{t.money.expensesTitle}</h1>
      <p className="mt-1.5 text-sm text-muted">{t.money.expensesSubtitle}</p>

      <div className="mt-6 space-y-4">
        {flash === "approved" && <Alert tone="success">{t.money.approvedMsg}</Alert>}
        {flash === "rejected" && <Alert tone="success">{t.money.rejectedMsg}</Alert>}

        <ExpenseForm
          adminId={me.id}
          today={today}
          categories={categories}
          investments={investments.rows.map((i) => ({ id: i.id, name: `${i.title}${i.status === "sold" ? ` (${t.money.sold})` : ""}` }))}
        />

        <nav className="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1" aria-label={t.money.expensesTitle}>
          {TABS.map((k) => (
            <Link
              key={k}
              href={`/admin/expenses?tab=${k}`}
              aria-current={tab === k ? "page" : undefined}
              className={cn(
                "inline-flex h-10 shrink-0 items-center gap-2 rounded-full border px-4 text-sm font-semibold transition",
                tab === k ? "border-accent bg-accent text-accent-fg" : "border-border bg-surface hover:bg-accent-soft",
              )}
            >
              {tabLabel[k]}
              {k === "pending" && counts.pending > 0 && (
                <span className={cn("rounded-full px-1.5 text-xs", tab === k ? "bg-black/15" : "bg-gold/30")}>{counts.pending}</span>
              )}
            </Link>
          ))}
        </nav>

        {empty ? (
          <Card className="text-center text-sm text-muted">{t.money.noRows}</Card>
        ) : (
          <ul className="space-y-3">
            {tab === "pending" && pendingReq.rows.map(requestCard)}
            {tab === "rejected" && rejectedReq.rows.map(requestCard)}
            {tab === "approved" && approved.rows.map(expenseCard)}
          </ul>
        )}
        {tab !== "pending" && (
          <Pager page={page} totalPages={Math.max(1, Math.ceil(total / PAGE_SIZE))} hrefFor={(p) => `/admin/expenses?tab=${tab}&page=${p}`} />
        )}
      </div>
    </div>
  );
}
