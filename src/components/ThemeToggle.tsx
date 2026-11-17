"use client";

import { useEffect, useState } from "react";
import { THEME_STORAGE_KEY, type ThemePref } from "@/lib/theme";
import { useI18n } from "./I18nProvider";

function readPref(): ThemePref {
  try {
    const p = localStorage.getItem(THEME_STORAGE_KEY);
    return p === "light" || p === "dark" ? p : "system";
  } catch {
    return "system";
  }
}

function applyTheme(pref: ThemePref) {
  const dark =
    pref === "dark" ||
    (pref === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.setAttribute("data-theme", dark ? "dark" : "light");
  document.documentElement.setAttribute("data-theme-pref", pref);
}

const ORDER: ThemePref[] = ["system", "light", "dark"];

/** Cycles System → Light → Dark. "System" follows the phone/computer setting live. */
export function ThemeToggle() {
  const { t } = useI18n();
  const [pref, setPref] = useState<ThemePref | null>(null);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- localStorage is only readable after mount
    setPref(readPref());
  }, []);

  useEffect(() => {
    if (pref !== "system") return;
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => applyTheme("system");
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, [pref]);

  const current = pref ?? "system";
  const next = ORDER[(ORDER.indexOf(current) + 1) % ORDER.length];
  const label = {
    system: t.common.themeSystem,
    light: t.common.themeLight,
    dark: t.common.themeDark,
  }[current];

  function onClick() {
    try {
      if (next === "system") localStorage.removeItem(THEME_STORAGE_KEY);
      else localStorage.setItem(THEME_STORAGE_KEY, next);
    } catch {
      // storage blocked: still switch for this visit
    }
    applyTheme(next);
    setPref(next);
  }

  return (
    <button
      type="button"
      onClick={onClick}
      title={`${t.common.theme}: ${label}`}
      aria-label={`${t.common.theme}: ${label}`}
      className="inline-flex h-10 items-center gap-1.5 rounded-full border border-border bg-surface px-3 text-sm font-medium text-fg backdrop-blur transition hover:bg-accent-soft"
    >
      <span aria-hidden className="inline-flex size-4 items-center justify-center">
        {current === "light" && <SunIcon />}
        {current === "dark" && <MoonIcon />}
        {current === "system" && <SystemIcon />}
      </span>
      <span className="hidden sm:inline" suppressHydrationWarning>
        {label}
      </span>
    </button>
  );
}

function SunIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" className="size-4">
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" />
    </svg>
  );
}

function MoonIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="size-4">
      <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z" />
    </svg>
  );
}

function SystemIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="size-4">
      <rect x="3" y="4" width="18" height="12" rx="2" />
      <path d="M8 20h8M12 16v4" />
    </svg>
  );
}
