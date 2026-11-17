"use client";

import { createContext, useContext, type ReactNode } from "react";
import type { Dictionary, Lang } from "@/lib/i18n/types";

const I18nContext = createContext<{ lang: Lang; t: Dictionary } | null>(null);

export function I18nProvider({
  lang,
  dictionary,
  children,
}: {
  lang: Lang;
  dictionary: Dictionary;
  children: ReactNode;
}) {
  return <I18nContext value={{ lang, t: dictionary }}>{children}</I18nContext>;
}

export function useI18n() {
  const ctx = useContext(I18nContext);
  if (!ctx) throw new Error("useI18n must be used inside I18nProvider");
  return ctx;
}
