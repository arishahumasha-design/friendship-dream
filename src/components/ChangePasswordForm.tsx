"use client";

import { useActionState, useEffect, useRef } from "react";
import { changePassword, type AuthFormState } from "@/app/actions/auth";
import { useI18n } from "./I18nProvider";
import { Alert, Button, Card, Field } from "./ui";

/** "Change password" in My profile: asks for the current password first. */
export function ChangePasswordForm() {
  const { t } = useI18n();
  const [state, action, pending] = useActionState<AuthFormState, FormData>(changePassword, {});
  const form = useRef<HTMLFormElement>(null);

  // Never keep passwords in the form after a successful change.
  useEffect(() => {
    if (state.done) form.current?.reset();
  }, [state]);

  return (
    <Card className="space-y-4">
      <div>
        <h2 className="text-lg font-bold">{t.auth.changeTitle}</h2>
        <p className="mt-0.5 text-sm text-muted">{t.auth.changeSubtitle}</p>
      </div>
      <form ref={form} action={action} className="space-y-4" noValidate>
        {state.error && <Alert>{t.errors[state.error]}</Alert>}
        {state.done && <Alert tone="success">{t.auth.changeDone}</Alert>}
        <Field
          id="currentPassword"
          name="currentPassword"
          type="password"
          label={t.auth.currentPassword}
          autoComplete="current-password"
          required
        />
        <Field
          id="newPassword"
          name="password"
          type="password"
          label={t.auth.newPassword}
          hint={t.auth.passwordHint}
          autoComplete="new-password"
          minLength={10}
          required
        />
        <Field
          id="newPasswordConfirm"
          name="confirmPassword"
          type="password"
          label={t.auth.confirmPassword}
          autoComplete="new-password"
          minLength={10}
          required
        />
        <Button type="submit" disabled={pending} className="w-full sm:w-auto sm:min-w-48">
          {pending ? t.common.loading : t.auth.changeButton}
        </Button>
      </form>
    </Card>
  );
}
