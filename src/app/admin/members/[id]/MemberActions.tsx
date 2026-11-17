"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import {
  changeMemberRole,
  changeMemberStatus,
  type ActionResult,
  type MemberAction,
} from "@/app/actions/members";
import { useI18n } from "@/components/I18nProvider";
import { Alert, Button, Card, TextArea } from "@/components/ui";
import type { MemberStatus, UserRole } from "@/lib/auth";

type Pending = { kind: "status"; action: MemberAction } | { kind: "role"; role: "admin" | "member" };

export function MemberActions({
  memberId,
  status,
  role,
  reviewNote,
  incomplete,
  canChangeRole,
  canActivate,
  locked,
}: {
  memberId: string;
  status: MemberStatus;
  role: UserRole;
  reviewNote: string | null;
  incomplete: boolean;
  canChangeRole: boolean;
  /** only the super admin may make a member active (approve or re-activate) */
  canActivate: boolean;
  locked: "self" | "admin" | null;
}) {
  const { t } = useI18n();
  const router = useRouter();
  const [busy, startTransition] = useTransition();
  const [confirming, setConfirming] = useState<Pending | null>(null);
  const [result, setResult] = useState<ActionResult | null>(null);
  const [noteOpen, setNoteOpen] = useState(false);
  const [note, setNote] = useState(reviewNote ?? "");

  function run(p: Pending) {
    setResult(null);
    startTransition(async () => {
      const res =
        p.kind === "status"
          ? await changeMemberStatus(memberId, p.action, p.action === "incomplete" ? note : undefined)
          : await changeMemberRole(memberId, p.role);
      setResult(res);
      setConfirming(null);
      if (res.ok) {
        if (p.kind === "status" && p.action === "incomplete") setNoteOpen(false);
        router.refresh();
      }
    });
  }

  const errorText = (e: Extract<ActionResult, { ok: false }>["error"]) =>
    ({
      notAllowed: t.members.errNotAllowed,
      wrongState: t.members.errWrongState,
      noteRequired: t.members.errNoteRequired,
      notFound: t.members.errNotFound,
      activateSuperOnly: t.members.errActivateSuperOnly,
      failed: t.members.errFailed,
    })[e];

  const label = (p: Pending) =>
    p.kind === "role"
      ? p.role === "admin"
        ? t.members.makeAdmin
        : t.members.makeMember
      : {
          approve: t.members.approve,
          suspend: t.members.suspend,
          reactivate: t.members.reactivate,
          incomplete: t.members.saveNote,
        }[p.action];

  const same = (a: Pending | null, b: Pending) => JSON.stringify(a) === JSON.stringify(b);

  /** Two-step button: first click asks "Are you sure?". */
  function actionButton(p: Pending, variant: "primary" | "secondary" | "danger" = "primary") {
    if (same(confirming, p)) {
      return (
        <div className="space-y-2 rounded-2xl border border-border p-3">
          <p className="text-sm font-semibold">{t.members.confirm}</p>
          <div className="flex gap-2">
            <Button type="button" variant={variant === "danger" ? "danger" : "primary"} disabled={busy} onClick={() => run(p)} className="flex-1">
              {busy ? t.common.loading : t.members.yes}
            </Button>
            <Button type="button" variant="secondary" disabled={busy} onClick={() => setConfirming(null)} className="flex-1">
              {t.members.cancel}
            </Button>
          </div>
        </div>
      );
    }
    return (
      <Button type="button" variant={variant} disabled={busy} onClick={() => setConfirming(p)} className="w-full">
        {label(p)}
      </Button>
    );
  }

  return (
    <Card className="space-y-4 p-5 sm:p-6">
      <h2 className="text-lg font-bold">{t.members.actions}</h2>

      {result?.ok && <Alert tone="success">{t.members[result.message]}</Alert>}
      {result && !result.ok && <Alert>{errorText(result.error)}</Alert>}

      {locked ? (
        <p className="text-sm text-muted">{locked === "self" ? t.members.selfHint : t.members.adminProtected}</p>
      ) : (
        <div className="space-y-3">
          {status === "pending" && (
            <>
              {canActivate ? (
                <>
                  {incomplete && <p className="text-xs text-muted">{t.members.approveIncompleteWarn}</p>}
                  {actionButton({ kind: "status", action: "approve" })}
                </>
              ) : (
                <p className="rounded-2xl bg-gold/10 px-3 py-2 text-sm font-medium">{t.members.activateSuperOnly}</p>
              )}
              {reviewNote && !noteOpen && (
                <div className="rounded-2xl bg-gold/10 p-3 text-sm">
                  <p className="text-xs font-semibold text-muted">{t.members.currentNote}</p>
                  <p className="mt-1 whitespace-pre-line">{reviewNote}</p>
                </div>
              )}
              {noteOpen ? (
                <div className="space-y-2">
                  <TextArea
                    id="reviewNote"
                    label={t.members.markIncomplete}
                    placeholder={t.members.notePlaceholder}
                    value={note}
                    maxLength={1000}
                    onChange={(e) => setNote(e.target.value)}
                  />
                  <div className="flex gap-2">
                    <Button type="button" disabled={busy} onClick={() => run({ kind: "status", action: "incomplete" })} className="flex-1">
                      {busy ? t.common.loading : t.members.saveNote}
                    </Button>
                    <Button type="button" variant="secondary" disabled={busy} onClick={() => setNoteOpen(false)}>
                      {t.members.cancel}
                    </Button>
                  </div>
                </div>
              ) : (
                <Button type="button" variant="secondary" disabled={busy} onClick={() => setNoteOpen(true)} className="w-full">
                  {t.members.markIncomplete}
                </Button>
              )}
            </>
          )}
          {status === "active" && actionButton({ kind: "status", action: "suspend" }, "danger")}
          {status === "suspended" &&
            (canActivate ? (
              actionButton({ kind: "status", action: "reactivate" })
            ) : (
              <p className="rounded-2xl bg-gold/10 px-3 py-2 text-sm font-medium">{t.members.activateSuperOnly}</p>
            ))}
        </div>
      )}

      {canChangeRole && (
        <div className="space-y-2 border-t border-border pt-4">
          <p className="text-sm font-semibold">{t.members.roleTitle}</p>
          {role === "member" ? (
            actionButton({ kind: "role", role: "admin" }, "secondary")
          ) : (
            actionButton({ kind: "role", role: "member" }, "secondary")
          )}
        </div>
      )}
    </Card>
  );
}
