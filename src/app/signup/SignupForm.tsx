"use client";

import Link from "next/link";
import { useActionState } from "react";
import { signup, type AuthFormState } from "@/app/actions/auth";
import { useI18n } from "@/components/I18nProvider";
import { Alert, Button, ButtonLink, Field } from "@/components/ui";

export function SignupForm() {
  const { t } = useI18n();
  const [state, action, pending] = useActionState<AuthFormState, FormData>(signup, {});

  if (state.checkEmail) {
    return (
      <div className="space-y-4 text-center">
        <Alert tone="success">
          <strong className="block">{t.auth.checkEmailTitle}</strong>
          {t.auth.checkEmailBody}
        </Alert>
        <ButtonLink href="/login" variant="secondary" className="w-full">
          {t.common.login}
        </ButtonLink>
      </div>
    );
  }

  return (
    <form action={action} className="space-y-4" noValidate>
      {state.error && <Alert>{t.errors[state.error]}</Alert>}

      <Field
        id="fullName"
        name="fullName"
        label={t.auth.fullName}
        placeholder={t.auth.fullNamePlaceholder}
        autoComplete="name"
        required
        defaultValue={state.values?.fullName}
      />
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
      <Field
        id="password"
        name="password"
        type="password"
        label={t.auth.password}
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
        {pending ? t.common.loading : t.auth.signupButton}
      </Button>

      <p className="text-center text-sm text-muted">
        {t.auth.haveAccount}{" "}
        <Link href="/login" className="font-semibold text-accent hover:underline">
          {t.common.login}
        </Link>
      </p>
    </form>
  );
}
