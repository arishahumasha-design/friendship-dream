"use client";

import Link from "next/link";
import { useActionState } from "react";
import { requestPasswordReset, type AuthFormState } from "@/app/actions/auth";
import { useI18n } from "@/components/I18nProvider";
import { Alert, Button, ButtonLink, Field } from "@/components/ui";

export function ForgotForm() {
  const { t } = useI18n();
  const [state, action, pending] = useActionState<AuthFormState, FormData>(requestPasswordReset, {});

  // The same message every time, whether or not the email has an account.
  if (state.sent) {
    return (
      <div className="space-y-4 text-center">
        <Alert tone="success">
          <strong className="block">{t.auth.forgotSentTitle}</strong>
          {t.auth.forgotSentBody}
        </Alert>
        <ButtonLink href="/login" variant="secondary" className="w-full">
          {t.auth.backToLogin}
        </ButtonLink>
      </div>
    );
  }

  return (
    <form action={action} className="space-y-4" noValidate>
      {state.error && <Alert>{t.errors[state.error]}</Alert>}
      <Field
        id="email"
        name="email"
        type="email"
        label={t.auth.email}
        autoComplete="email"
        inputMode="email"
        required
        defaultValue={state.values?.email}
      />
      <Button type="submit" disabled={pending} className="w-full">
        {pending ? t.common.loading : t.auth.forgotButton}
      </Button>
      <p className="text-center text-sm">
        <Link href="/login" className="font-semibold text-accent hover:underline">
          {t.auth.backToLogin}
        </Link>
      </p>
    </form>
  );
}
