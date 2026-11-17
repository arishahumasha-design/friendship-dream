import type { en } from "./en";

export type Lang = "en" | "bn";
export const LANGS: Lang[] = ["en", "bn"];
export const DEFAULT_LANG: Lang = "en";
export const LANG_COOKIE = "fd_lang";

/** Same shape as the English dictionary, every value a string. */
export type Dictionary = {
  [Section in keyof typeof en]: { [Key in keyof (typeof en)[Section]]: string };
};

export type ErrorKey = keyof Dictionary["errors"];

export function isLang(value: unknown): value is Lang {
  return value === "en" || value === "bn";
}
