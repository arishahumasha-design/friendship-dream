"use client";

import { useActionState } from "react";
import { resetPassword, type AuthFormState } from "@/app/actions/auth";
import { useI18n } from "@/components/I18nProvider";
import { Alert, Button, ButtonLink, Field } from "@/components/ui";

export function ResetForm() {
  const { t } = useI18n();
  const [state, action, pending] = useActionState<AuthFormState, FormData>(resetPassword, {});

  if (state.done) {
    return (
      <div className="space-y-4 text-center">
        <Alert tone="success">{t.auth.resetDone}</Alert>
        <ButtonLink href="/home" className="w-full">
          {t.auth.goToMyPage}
        </ButtonLink>
      </div>
    );
  }

  return (
    <form action={action} className="space-y-4" noValidate>
      {state.error && <Alert>{t.errors[state.error]}</Alert>}
      <Field
        id="password"
        name="password"
        type="password"
        label={t.auth.newPassword}
        hint={t.auth.passwordHint}
        autoComplete="new-password"
        minLength={10}
        required
      />
      <Field
        id="confirmPassword"
        name="confirmPassword"
        type="password"
        label={t.auth.confirmPassword}
        autoComplete="new-password"
        minLength={10}
        required
      />
      <Button type="submit" disabled={pending} className="w-full">
        {pending ? t.common.loading : t.auth.resetButton}
      </Button>
    </form>
  );
}
