"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { reviewDeposit, type ReviewResult } from "@/app/actions/deposits";
import { useI18n } from "./I18nProvider";
import { Alert, Button, TextArea } from "./ui";

/**
 * Approve / reject buttons for one pending deposit.
 * - "normal": approve with one click.
 * - "blocked": the deposit is the viewer's own (or, for a normal admin, one they entered):
 *   approve is replaced by a note, because ANOTHER admin must approve it. Reject stays available.
 * - "own": the super admin entered this deposit for another member: approving asks for confirmation.
 */
export function ReviewActions({
  depositId,
  mode,
}: {
  depositId: string;
  mode: "normal" | "blocked" | "own";
}) {
  const { t } = useI18n();
  const router = useRouter();
  const [busy, startTransition] = useTransition();
  const [rejecting, setRejecting] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);

  function run(action: "approve" | "reject") {
    setError(null);
    startTransition(async () => {
      const res: ReviewResult = await reviewDeposit(depositId, action, { reason });
      if (!res.ok) {
        setError(t.deposits[res.error]);
        return;
      }
      // Show the result on the refreshed list (this row leaves the "waiting" tab).
      const params = new URLSearchParams(window.location.search);
      params.set("flash", res.message);
      router.replace(`/admin/deposits?${params.toString()}`);
      router.refresh();
    });
  }

  return (
    <div className="space-y-3">
      {error && <Alert>{error}</Alert>}

      {confirming && !rejecting && (
        <div className="space-y-2 rounded-2xl border border-gold/60 bg-gold/10 p-3">
          <p className="text-sm font-semibold">{t.adminDeposits.enteredByYouConfirm}</p>
          <div className="flex gap-2">
            <Button type="button" disabled={busy} onClick={() => run("approve")} className="h-10">
              {busy ? t.adminDeposits.approving : t.adminDeposits.approve}
            </Button>
            <Button type="button" variant="secondary" disabled={busy} onClick={() => setConfirming(false)} className="h-10">
              {t.adminDeposits.cancel}
            </Button>
          </div>
        </div>
      )}

      {!rejecting && !confirming && (
        <div className="flex flex-wrap items-center gap-2">
          {mode === "blocked" ? (
            <p className="text-sm font-medium text-muted">{t.adminDeposits.anotherAdmin}</p>
          ) : (
            <Button
              type="button"
              disabled={busy}
              onClick={() => (mode === "own" ? setConfirming(true) : run("approve"))}
              className="h-10"
            >
              {busy ? t.adminDeposits.approving : t.adminDeposits.approve}
            </Button>
          )}
          <Button type="button" variant="secondary" disabled={busy} onClick={() => setRejecting(true)} className="h-10">
            {t.adminDeposits.reject}
          </Button>
        </div>
      )}

      {rejecting && (
        <div className="space-y-2">
          <TextArea
            id={`reason-${depositId}`}
            label={t.adminDeposits.rejectReason}
            placeholder={t.adminDeposits.rejectPlaceholder}
            value={reason}
            maxLength={500}
            onChange={(e) => setReason(e.target.value)}
          />
          <div className="flex gap-2">
            <Button
              type="button"
              variant="danger"
              disabled={busy || !reason.trim()}
              onClick={() => run("reject")}
              className="h-10"
            >
              {busy ? t.adminDeposits.approving : t.adminDeposits.confirmReject}
            </Button>
            <Button type="button" variant="secondary" disabled={busy} onClick={() => setRejecting(false)} className="h-10">
              {t.adminDeposits.cancel}
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}
