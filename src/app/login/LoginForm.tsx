"use client";

import Link from "next/link";
import { useActionState } from "react";
import { login, type AuthFormState } from "@/app/actions/auth";
import { useI18n } from "@/components/I18nProvider";
import { Alert, Button, Field } from "@/components/ui";

export function LoginForm({ next, notice }: { next?: string; notice?: "loggedOut" | "confirm" }) {
  const { t } = useI18n();
  const [state, action, pending] = useActionState<AuthFormState, FormData>(login, {});

  return (
    <form action={action} className="space-y-4" noValidate>
      {notice === "loggedOut" && !state.error && <Alert tone="success">{t.auth.loggedOut}</Alert>}
      {notice === "confirm" && !state.error && <Alert>{t.errors.confirmFailed}</Alert>}
      {state.error && <Alert>{t.errors[state.error]}</Alert>}

      <input type="hidden" name="next" value={next ?? ""} />
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
        autoComplete="current-password"
        required
      />
      <Button type="submit" disabled={pending} className="w-full">
        {pending ? t.common.loading : t.auth.loginButton}
      </Button>

      <p className="text-center text-sm text-muted">
        {t.auth.noAccount}{" "}
        <Link href="/signup" className="font-semibold text-accent hover:underline">
          {t.common.signup}
        </Link>
      </p>
    </form>
  );
}
