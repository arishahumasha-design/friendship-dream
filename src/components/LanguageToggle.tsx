"use client";

import { useRouter } from "next/navigation";
import { useTransition } from "react";
import { LANG_COOKIE } from "@/lib/i18n/types";
import { useI18n } from "./I18nProvider";

/** Switches English ⇄ Bengali. Saved in a cookie for one year so the server renders the right language. */
export function LanguageToggle() {
  const { lang, t } = useI18n();
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const next = lang === "en" ? "bn" : "en";

  function onClick() {
    document.cookie = `${LANG_COOKIE}=${next}; path=/; max-age=31536000; samesite=lax`;
    startTransition(() => router.refresh());
  }

  return (
    <button
      type="button"
      onClick={onClick}
      disabled={pending}
      aria-label={t.common.language}
      lang={next}
      className="inline-flex h-10 items-center rounded-full border border-border bg-surface px-3 text-sm font-medium text-fg backdrop-blur transition hover:bg-accent-soft disabled:opacity-60"
    >
      {next === "bn" ? t.common.switchToBn : t.common.switchToEn}
    </button>
  );
}
