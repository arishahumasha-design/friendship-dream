"use client";

import { usePathname, useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { approveRequest, rejectRequest } from "@/app/actions/money";
import { formatTaka } from "@/lib/format";
import { useI18n } from "./I18nProvider";
import { Alert, Button, TextArea } from "./ui";

/**
 * Approve / reject one waiting money request (purchase, cost item, sale, income, expense, reversal).
 * `blocked`: the viewer made this entry themself, so the approve button is replaced by a note
 * (the database refuses it anyway). `basis`: for a purchase, the total cost basis the approver confirms.
 */
export function RequestActions({
  requestId,
  kind,
  blocked,
  basis,
  approveDisabledNote,
}: {
  requestId: string;
  kind: "purchase" | "investment_cost" | "sale" | "income" | "expense" | "expense_reversal";
  blocked: boolean;
  basis?: number;
  approveDisabledNote?: string;
}) {
  const { t } = useI18n();
  const router = useRouter();
  const pathname = usePathname();
  const [busy, startTransition] = useTransition();
  const [rejecting, setRejecting] = useState(false);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);

  function done(flash: "approved" | "rejected") {
    router.replace(`${pathname}?flash=${flash}`);
    router.refresh();
  }
  function approve() {
    setError(null);
    startTransition(async () => {
      const res = await approveRequest(requestId, kind, kind === "purchase" ? String(basis) : undefined);
      if (!res.ok) return setError(res.message);
      done("approved");
    });
  }
  function reject() {
    setError(null);
    startTransition(async () => {
      const res = await rejectRequest(requestId, reason);
      if (!res.ok) return setError(res.message);
      done("rejected");
    });
  }

  return (
    <div className="space-y-3">
      {error && <Alert>{error}</Alert>}
      {kind === "purchase" && basis !== undefined && !rejecting && (
        <p className="rounded-2xl bg-fg/5 px-4 py-2 text-sm">
          {t.money.approveBasis}: <span className="font-bold">{formatTaka(basis)}</span>
        </p>
      )}
      {!rejecting ? (
        <div className="flex flex-wrap items-center gap-2">
          {blocked ? (
            <p className="text-sm font-medium text-muted">{t.money.anotherAdmin}</p>
          ) : approveDisabledNote ? (
            <p className="text-sm font-medium text-muted">{approveDisabledNote}</p>
          ) : (
            <Button type="button" disabled={busy} onClick={approve} className="h-10">
              {busy ? t.money.working : t.money.approve}
            </Button>
          )}
          <Button type="button" variant="secondary" disabled={busy} onClick={() => setRejecting(true)} className="h-10">
            {t.money.reject}
          </Button>
        </div>
      ) : (
        <div className="space-y-2">
          <TextArea
            id={`rej-${requestId}`}
            label={t.money.rejectReasonLabel}
            placeholder={t.money.rejectPlaceholder}
            value={reason}
            maxLength={500}
            onChange={(e) => setReason(e.target.value)}
          />
          <div className="flex gap-2">
            <Button type="button" variant="danger" disabled={busy || !reason.trim()} onClick={reject} className="h-10">
              {busy ? t.money.working : t.money.confirmReject}
            </Button>
            <Button type="button" variant="secondary" disabled={busy} onClick={() => setRejecting(false)} className="h-10">
              {t.money.cancel}
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}
